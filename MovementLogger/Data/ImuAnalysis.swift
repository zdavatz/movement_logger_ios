import Foundation

/// On-device IMU propulsion analysis — the native port of the offline Python
/// classifier (`scratchpad/phone_modestrip.py` / `imu_modestrip2.py`). Reads a
/// recorded IMU CSV (phone-logger `SensPhone_*` or Apple-Watch `WatchImu_*`) +
/// its paired GPS file and classifies every second of the ride into
/// **glide (on foil) / paddle-pump / wait**, plus board pitch/roll and stroke
/// cadence.
///
/// Pipeline (matches the validated Python):
///  1. signed userAccel per axis (phone: raw − moving-average gravity; watch:
///     already split) — NOT `|userAccel|`, whose rectification doubles a clean
///     single-axis stroke's cadence.
///  2. STFT (radix-2 FFT, Hann, ~10 s window / 1 s hop) → sum of per-axis PSDs
///     → stroke-band energy (0.35–1.3 Hz), rhythmicity (band concentration),
///     dominant stroke frequency.
///  3. Otsu thresholds → classify: GLIDE if speed ≥ 12 km/h; else PADDLE if
///     energetic AND rhythmic; else WAIT. Median-filter + short-run absorb.
///  4. Board pitch/roll from the (pseudo-tared) gravity vector.
enum ImuMode: Int, Sendable, Codable { case glide = 0, paddle = 1, wait = 2 }

struct ImuAnalysisResult: Sendable, Codable {
    let minutes: [Double]        // per-second time grid, in minutes
    let speedKmh: [Double]
    let strokeEnergy: [Double]   // stroke-band RMS-like energy
    let rhythmicity: [Double]    // 0..1 stroke-band concentration
    let strokeRate: [Double]     // 1/min, NaN where not paddling
    let pitchDeg: [Double]
    let rollDeg: [Double]
    let mode: [ImuMode]
    let seThreshold: Double
    let concThreshold: Double
    // headline totals
    let glideSec: Int
    let paddleSec: Int
    let waitSec: Int
    let foilRuns: Int
    let medianStrokeRate: Double
    let fs: Double
    let durationMin: Double
    let sourceName: String
}

enum ImuAnalysisError: Error, LocalizedError {
    case tooShort
    case badFile(String)
    var errorDescription: String? {
        switch self {
        case .tooShort: return "Recording too short to analyze."
        case .badFile(let m): return m
        }
    }
}

enum ImuAnalysis {
    static let loHz = 0.35, hiHz = 1.30
    static let totLo = 0.10, totHi = 4.0
    static let promLo = 0.20, promHi = 2.0
    static let foilKmh = 12.0
    static let decTargetHz = 25.0     // decimate to ~this before the STFT

    // MARK: - Public adapters

    /// Phone-logger pair: `SensPhone_*` (raw mg accel, gravity included) +
    /// `GpsPhone_*`. Both share the `Time [10ms]` tick clock, so sensor↔GPS
    /// align directly by tick.
    static func fromPhoneLogger(sensURL: URL, gpsURL: URL) throws -> ImuAnalysisResult {
        let rows = try CsvParsers.parseSensorFile(sensURL)
        guard rows.count > 200 else { throw ImuAnalysisError.tooShort }
        let sec = rows.map { $0.ticks * 0.01 }
        let fs = sampleRate(sec)
        guard fs.isFinite, fs > 1 else { throw ImuAnalysisError.badFile("cannot infer sample rate") }
        // raw accel in g (gravity included)
        let rx = rows.map { $0.accX / 1000.0 }
        let ry = rows.map { $0.accY / 1000.0 }
        let rz = rows.map { $0.accZ / 1000.0 }
        // gravity = moving average (~2 s); userAccel = raw − gravity
        let gw = max(1, Int((2.0 * fs).rounded()))
        let gx = movAvg(rx, gw), gy = movAvg(ry, gw), gz = movAvg(rz, gw)
        var ux = [Double](repeating: 0, count: rows.count)
        var uy = ux, uz = ux
        for i in 0..<rows.count { ux[i] = rx[i] - gx[i]; uy[i] = ry[i] - gy[i]; uz[i] = rz[i] - gz[i] }

        let gps = (try? CsvParsers.parseGpsFile(gpsURL)) ?? []
        let gpsSec = gps.map { $0.ticks * 0.01 }
        let gpsSpd = gps.map { clampSpeed($0.speedKmhModule) }

        return try core(ux: ux, uy: uy, uz: uz, sampleSec: sec, fs: fs,
                        gx: gx, gy: gy, gz: gz,
                        gpsSec: gpsSec, gpsSpeed: gpsSpd,
                        sourceName: sensURL.lastPathComponent)
    }

    /// Apple-Watch pair: `WatchImu_*` (epoch_ms + pre-split userAccel/gravity) +
    /// `WatchGps_*`. Aligned by UTC-seconds-of-day (they don't share a tick).
    static func fromWatch(imuURL: URL, gpsURL: URL) throws -> ImuAnalysisResult {
        let w = try parseWatchImu(imuURL)
        guard w.epochMs.count > 200 else { throw ImuAnalysisError.tooShort }
        let sod0 = (w.epochMs[0] / 1000.0).truncatingRemainder(dividingBy: 86400.0)
        let sec = w.epochMs.map { ($0 / 1000.0).truncatingRemainder(dividingBy: 86400.0) - sod0 }
        let fs = sampleRate(sec)
        guard fs.isFinite, fs > 1 else { throw ImuAnalysisError.badFile("cannot infer sample rate") }

        let gps = (try? CsvParsers.parseGpsFile(gpsURL)) ?? []
        var gpsSec: [Double] = [], gpsSpd: [Double] = []
        gpsSec.reserveCapacity(gps.count); gpsSpd.reserveCapacity(gps.count)
        for r in gps {
            guard let sod = sodFromUtc(r.utc) else { continue }
            gpsSec.append(sod - sod0)
            gpsSpd.append(clampSpeed(r.speedKmhModule))
        }
        return try core(ux: w.ux, uy: w.uy, uz: w.uz, sampleSec: sec, fs: fs,
                        gx: w.gx, gy: w.gy, gz: w.gz,
                        gpsSec: gpsSec, gpsSpeed: gpsSpd,
                        sourceName: imuURL.lastPathComponent)
    }

    // MARK: - Core

    private static func core(ux: [Double], uy: [Double], uz: [Double],
                             sampleSec: [Double], fs: Double,
                             gx: [Double], gy: [Double], gz: [Double],
                             gpsSec: [Double], gpsSpeed: [Double],
                             sourceName: String) throws -> ImuAnalysisResult {
        let n = ux.count
        let dur = sampleSec[n - 1] - sampleSec[0]
        guard dur > 20 else { throw ImuAnalysisError.tooShort }
        let T = Int(dur.rounded(.down))
        let secs = (0...T).map { Double($0) }
        let base = sampleSec[0]

        // ---- per-second GPS speed (both time bases shifted to start = 0) ----
        let speed = interp(secs, gpsSec.map { $0 - base }, gpsSpeed, leftFill: 0, rightFill: 0)

        // ---- decimate userAccel to ~decTargetHz for the STFT ----
        let dec = max(1, Int((fs / decTargetHz).rounded()))
        let fsA = fs / Double(dec)
        let dx = blockMean(ux, dec), dy = blockMean(uy, dec), dz = blockMean(uz, dec)
        let mA = dx.count

        // ---- STFT features ----
        let nfft = nextPow2(Int((10.0 * fsA).rounded()))
        let win = min(nfft, mA)
        let hop = max(1, Int(fsA.rounded()))
        let hann = hannWindow(win)
        let kLo = Int((loHz * Double(nfft) / fsA).rounded(.down))
        let kHi = Int((hiHz * Double(nfft) / fsA).rounded(.up))
        let ktLo = Int((totLo * Double(nfft) / fsA).rounded(.down))
        let ktHi = Int((totHi * Double(nfft) / fsA).rounded(.up))
        let kpLo = Int((promLo * Double(nfft) / fsA).rounded(.down))
        let kpHi = Int((promHi * Double(nfft) / fsA).rounded(.up))
        let nyq = nfft / 2

        var winCenterSec: [Double] = []
        var promV: [Double] = [], concV: [Double] = [], peakF: [Double] = []
        var start = 0
        var re = [Double](repeating: 0, count: nfft)
        var im = [Double](repeating: 0, count: nfft)
        var psd = [Double](repeating: 0, count: nyq + 1)
        while start + win <= mA {
            for k in 0...nyq { psd[k] = 0 }
            for axis in 0..<3 {
                let src = axis == 0 ? dx : (axis == 1 ? dy : dz)
                var mean = 0.0
                for i in 0..<win { mean += src[start + i] }
                mean /= Double(win)
                for i in 0..<nfft {
                    if i < win { re[i] = (src[start + i] - mean) * hann[i] } else { re[i] = 0 }
                    im[i] = 0
                }
                fft(&re, &im)
                for k in 0...nyq { psd[k] += re[k] * re[k] + im[k] * im[k] }
            }
            var bp = 0.0, tp = 0.0, pk = 0.0, pkK = kLo
            for k in max(1, ktLo)...min(nyq, ktHi) { tp += psd[k] }
            for k in max(1, kLo)...min(nyq, kHi) where psd[k] > pk { pk = psd[k]; pkK = k }
            for k in max(1, kLo)...min(nyq, kHi) { bp += psd[k] }
            // prominence: peak / median over the prom band
            var pband: [Double] = []
            for k in max(1, kpLo)...min(nyq, kpHi) { pband.append(psd[k]) }
            let med = median(pband)
            promV.append(med > 0 ? pk / med : 0)
            concV.append(tp > 0 ? bp / tp : 0)
            peakF.append(Double(pkK) * fsA / Double(nfft))
            winCenterSec.append((Double(start) + Double(win) / 2) / fsA)
            start += hop
        }

        let conc = interp(secs, winCenterSec, concV, leftFill: 0, rightFill: 0)
        let prom = interp(secs, winCenterSec, promV, leftFill: 0, rightFill: 0)
        let strokeF = interp(secs, winCenterSec, peakF, leftFill: .nan, rightFill: .nan)

        // Stroke energy from a cheap time-domain bandpass RMS (not STFT band
        // power on decimated data): it goes cleanly to ~0 on a still/dead tail,
        // so the energy gate can't be fooled by concentration on low-level
        // noise — mirrors the Python Butterworth + 4 s RMS envelope.
        let energy = bandpassEnergyPerSec(ux: ux, uy: uy, uz: uz,
                                          sampleSec: sampleSec, secs: secs, fs: fs)

        // ---- board pitch/roll from pseudo-tared gravity (per second) ----
        let (pitch, roll) = boardAngles(gx: gx, gy: gy, gz: gz, sampleSec: sampleSec, secs: secs)

        // ---- thresholds ----
        var slowLogE: [Double] = []
        for i in secs.indices where speed[i] < foilKmh { slowLogE.append(log10(energy[i] + 1e-6)) }
        let seThr = pow(10, otsu(slowLogE))
        var concEnergetic: [Double] = [], promEnergetic: [Double] = []
        for i in secs.indices where speed[i] < foilKmh && energy[i] >= seThr {
            concEnergetic.append(conc[i]); promEnergetic.append(prom[i])
        }
        let concThr = max(0.30, concEnergetic.count > 8 ? otsu(concEnergetic) : 0.30)
        let promThr = max(4.0, promEnergetic.count > 8 ? otsu(promEnergetic) : 4.0)

        // ---- classify: glide (speed) → paddle (energetic AND rhythmic) → wait ----
        var mode = [Int](repeating: ImuMode.wait.rawValue, count: secs.count)
        for i in secs.indices {
            if speed[i] >= foilKmh { mode[i] = ImuMode.glide.rawValue }
            else if energy[i] >= seThr && (conc[i] >= concThr || prom[i] >= promThr) { mode[i] = ImuMode.paddle.rawValue }
            else { mode[i] = ImuMode.wait.rawValue }
        }
        mode = medianFilterInt(mode, 11)
        mode = absorbShortRuns(mode, minLen: 15)

        var glide = 0, paddle = 0, wait = 0
        for m in mode {
            if m == 0 { glide += 1 } else if m == 1 { paddle += 1 } else { wait += 1 }
        }
        // foil-run count (rising edges of glide)
        var foilRuns = 0
        for i in mode.indices {
            if mode[i] == 0 && (i == 0 || mode[i - 1] != 0) { foilRuns += 1 }
        }
        var srSamples: [Double] = []
        for i in mode.indices where mode[i] == 1 && strokeF[i].isFinite { srSamples.append(strokeF[i] * 60) }
        let medSr = median(srSamples)

        let strokeRate = mode.indices.map { mode[$0] == 1 && strokeF[$0].isFinite ? strokeF[$0] * 60 : Double.nan }

        return ImuAnalysisResult(
            minutes: secs.map { $0 / 60.0 },
            speedKmh: speed, strokeEnergy: energy, rhythmicity: conc,
            strokeRate: strokeRate, pitchDeg: pitch, rollDeg: roll,
            mode: mode.map { ImuMode(rawValue: $0) ?? .wait },
            seThreshold: seThr, concThreshold: concThr,
            glideSec: glide, paddleSec: paddle, waitSec: wait,
            foilRuns: foilRuns, medianStrokeRate: medSr,
            fs: fs, durationMin: dur / 60.0, sourceName: sourceName)
    }

    /// Per-second stroke-band energy: a difference-of-moving-averages bandpass
    /// (~loHz..hiHz) of the signed userAccel axes, combined and RMS-smoothed
    /// over ~4 s. Cheap (only boxcar averages) and — crucially — near-zero on a
    /// still/dead tail, which the STFT band-power is not after decimation.
    private static func bandpassEnergyPerSec(ux: [Double], uy: [Double], uz: [Double],
                                             sampleSec: [Double], secs: [Double], fs: Double) -> [Double] {
        let wHi = max(2, Int((0.443 * fs / hiHz).rounded()))   // lowpass at the hi cutoff
        let wLo = max(3, Int((0.443 * fs / loHz).rounded()))   // lowpass at the lo cutoff
        func bp(_ u: [Double]) -> [Double] {
            let lpHi = movAvg(u, wHi), lpLo = movAvg(u, wLo)
            var o = [Double](repeating: 0, count: u.count)
            for i in u.indices { o[i] = lpHi[i] - lpLo[i] }
            return o
        }
        let bx = bp(ux), by = bp(uy), bz = bp(uz)
        var pw = [Double](repeating: 0, count: ux.count)
        for i in ux.indices { pw[i] = bx[i] * bx[i] + by[i] * by[i] + bz[i] * bz[i] }
        let sm = movAvg(pw, max(1, Int((4.0 * fs).rounded())))
        let base = sampleSec[0]
        var sum = [Double](repeating: 0, count: secs.count)
        var cnt = [Int](repeating: 0, count: secs.count)
        for i in ux.indices {
            let idx = Int((sampleSec[i] - base).rounded(.down))
            if idx >= 0 && idx < secs.count { sum[idx] += sm[i]; cnt[idx] += 1 }
        }
        var out = [Double](repeating: 0, count: secs.count)
        for i in secs.indices { out[i] = cnt[i] > 0 ? (sum[i] / Double(cnt[i])).squareRoot() : (i > 0 ? out[i - 1] : 0) }
        return out
    }

    // MARK: - Board angles

    private static func boardAngles(gx: [Double], gy: [Double], gz: [Double],
                                    sampleSec: [Double], secs: [Double]) -> ([Double], [Double]) {
        // median gravity over the ride -> tare rotation to (0,0,-1)
        let gmx = median(gx), gmy = median(gy), gmz = median(gz)
        let gnorm = (gmx * gmx + gmy * gmy + gmz * gmz).squareRoot()
        let m = gnorm > 0 ? [gmx / gnorm, gmy / gnorm, gmz / gnorm] : [0, 0, -1]
        let down = [0.0, 0.0, -1.0]
        // Rodrigues rotation mapping m -> down
        let axis = cross(m, down)
        let s = (axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]).squareRoot()
        let c = dot(m, down)
        var R = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
        if s > 1e-9 {
            let a = [axis[0] / s, axis[1] / s, axis[2] / s]
            let K = [[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]]
            var K2 = [[0.0, 0, 0], [0, 0, 0], [0, 0, 0]]
            for i in 0..<3 { for j in 0..<3 { var v = 0.0; for k in 0..<3 { v += K[i][k] * K[k][j] }; K2[i][j] = v } }
            for i in 0..<3 { for j in 0..<3 { R[i][j] = (i == j ? 1 : 0) + s * K[i][j] + (1 - c) * K2[i][j] } }
        }
        // per-second averaged gravity, rotated, -> pitch/roll
        var pitch = [Double](repeating: 0, count: secs.count)
        var roll = [Double](repeating: 0, count: secs.count)
        let base = sampleSec[0]
        var sx = [Double](repeating: 0, count: secs.count)
        var sy = [Double](repeating: 0, count: secs.count)
        var sz = [Double](repeating: 0, count: secs.count)
        var sn = [Int](repeating: 0, count: secs.count)
        for i in gx.indices {
            let idx = Int((sampleSec[i] - base).rounded(.down))
            if idx >= 0 && idx < secs.count {
                sx[idx] += gx[i]; sy[idx] += gy[i]; sz[idx] += gz[i]; sn[idx] += 1
            }
        }
        for i in secs.indices {
            if sn[i] == 0 {
                pitch[i] = i > 0 ? pitch[i - 1] : 0
                roll[i] = i > 0 ? roll[i - 1] : 0
                continue
            }
            let cnt = Double(sn[i])
            let vx = sx[i] / cnt, vy = sy[i] / cnt, vz = sz[i] / cnt
            let rx: Double = R[0][0] * vx + R[0][1] * vy + R[0][2] * vz
            let ry: Double = R[1][0] * vx + R[1][1] * vy + R[1][2] * vz
            let rz: Double = R[2][0] * vx + R[2][1] * vy + R[2][2] * vz
            pitch[i] = atan2(ry, -rz) * 180.0 / Double.pi
            roll[i] = atan2(rx, -rz) * 180.0 / Double.pi
        }
        return (pitch, roll)
    }

    // MARK: - WatchImu parser

    private struct WatchImu {
        var epochMs: [Double] = []
        var ux: [Double] = [], uy: [Double] = [], uz: [Double] = []
        var gx: [Double] = [], gy: [Double] = [], gz: [Double] = []
    }

    private static func parseWatchImu(_ url: URL) throws -> WatchImu {
        let text = try String(contentsOf: url, encoding: .utf8)
        var w = WatchImu()
        var isFirst = true
        text.split(separator: "\n", omittingEmptySubsequences: true).forEach { lineSub in
            let line = lineSub.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return }
            if isFirst { isFirst = false; if line.hasPrefix("epoch") { return } }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 7 else { return }
            guard let e = Double(f[0]), let a0 = Double(f[1]), let a1 = Double(f[2]), let a2 = Double(f[3]),
                  let g0 = Double(f[4]), let g1 = Double(f[5]), let g2 = Double(f[6]) else { return }
            w.epochMs.append(e); w.ux.append(a0); w.uy.append(a1); w.uz.append(a2)
            w.gx.append(g0); w.gy.append(g1); w.gz.append(g2)
        }
        return w
    }

    // MARK: - DSP / math helpers

    /// In-place iterative radix-2 Cooley-Tukey FFT. `re.count` must be a power of 2.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        if n <= 1 { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2.0 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = cr * re[b] - ci * im[b]
                    let ti = cr * im[b] + ci * re[b]
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr; cr = ncr
                }
                i += len
            }
            len <<= 1
        }
    }

    private static func nextPow2(_ x: Int) -> Int {
        var p = 1; while p < x { p <<= 1 }; return max(2, p)
    }
    private static func hannWindow(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(max(1, n - 1))) }
    }
    private static func movAvg(_ x: [Double], _ w: Int) -> [Double] {
        let n = x.count
        if w <= 1 || n == 0 { return x }
        var pre = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + x[i] }
        let half = w / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            out[i] = (pre[hi + 1] - pre[lo]) / Double(hi - lo + 1)
        }
        return out
    }
    private static func blockMean(_ x: [Double], _ dec: Int) -> [Double] {
        if dec <= 1 { return x }
        let m = x.count / dec
        var out = [Double](repeating: 0, count: m)
        for i in 0..<m {
            var s = 0.0; for k in 0..<dec { s += x[i * dec + k] }
            out[i] = s / Double(dec)
        }
        return out
    }
    private static func sampleRate(_ sec: [Double]) -> Double {
        guard sec.count > 10 else { return .nan }
        var d: [Double] = []; d.reserveCapacity(min(sec.count, 2000))
        for i in 1..<min(sec.count, 2000) { let dt = sec[i] - sec[i - 1]; if dt > 0 { d.append(dt) } }
        let m = median(d)
        return m > 0 ? 1.0 / m : .nan
    }
    private static func clampSpeed(_ v: Double) -> Double {
        (v.isFinite && v >= 0 && v <= 60) ? v : .nan
    }
    private static func sodFromUtc(_ utc: String) -> Double? {
        guard let v = Double(utc) else { return nil }
        let h = (v / 10000).rounded(.down)
        let m = ((v.truncatingRemainder(dividingBy: 10000)) / 100).rounded(.down)
        let s = v.truncatingRemainder(dividingBy: 100)
        return h * 3600 + m * 60 + s
    }

    /// Linear interpolation of (xp, fp) onto xs. Gaps at ends use fill values.
    /// NaNs in fp are skipped when building anchors.
    private static func interp(_ xs: [Double], _ xp: [Double], _ fp: [Double],
                               leftFill: Double, rightFill: Double) -> [Double] {
        // build clean, sorted anchor list
        var ax: [Double] = [], af: [Double] = []
        for i in xp.indices where xp[i].isFinite && fp[i].isFinite {
            ax.append(xp[i]); af.append(fp[i])
        }
        guard !ax.isEmpty else { return [Double](repeating: leftFill, count: xs.count) }
        var out = [Double](repeating: 0, count: xs.count)
        var j = 0
        for i in xs.indices {
            let x = xs[i]
            if x < ax.first! { out[i] = leftFill; continue }
            if x > ax.last! { out[i] = rightFill; continue }
            while j + 1 < ax.count && ax[j + 1] < x { j += 1 }
            let x0 = ax[j], x1 = ax[j + 1], y0 = af[j], y1 = af[j + 1]
            out[i] = x1 > x0 ? y0 + (y1 - y0) * (x - x0) / (x1 - x0) : y0
        }
        return out
    }

    private static func median(_ a: [Double]) -> Double {
        let v = a.filter { $0.isFinite }.sorted()
        if v.isEmpty { return .nan }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }
    /// Otsu threshold over a 64-bin histogram of finite values.
    private static func otsu(_ vals: [Double]) -> Double {
        let v = vals.filter { $0.isFinite }
        if v.count < 8 { return v.isEmpty ? 0 : median(v) }
        let lo = v.min()!, hi = v.max()!
        if hi <= lo { return lo }
        let bins = 64
        var hist = [Double](repeating: 0, count: bins)
        for x in v {
            var b = Int((x - lo) / (hi - lo) * Double(bins)); if b >= bins { b = bins - 1 }; if b < 0 { b = 0 }
            hist[b] += 1
        }
        let total = Double(v.count)
        for i in 0..<bins { hist[i] /= total }
        var w = 0.0, mu = 0.0, muT = 0.0
        let centers = (0..<bins).map { lo + (Double($0) + 0.5) * (hi - lo) / Double(bins) }
        for i in 0..<bins { muT += hist[i] * centers[i] }
        var best = -1.0, bestK = 0
        for i in 0..<bins {
            w += hist[i]; mu += hist[i] * centers[i]
            let wb = w, wf = 1 - w
            if wb <= 0 || wf <= 0 { continue }
            let sb = (muT * wb - mu) * (muT * wb - mu) / (wb * wf)
            if sb > best { best = sb; bestK = i }
        }
        return centers[bestK]
    }
    private static func medianFilterInt(_ x: [Int], _ w: Int) -> [Int] {
        let n = x.count, half = w / 2
        var out = x
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            var counts = [0, 0, 0]
            for k in lo...hi where x[k] >= 0 && x[k] < 3 { counts[x[k]] += 1 }
            out[i] = counts[0] >= counts[1] && counts[0] >= counts[2] ? 0 : (counts[1] >= counts[2] ? 1 : 2)
        }
        return out
    }
    private static func absorbShortRuns(_ x: [Int], minLen: Int) -> [Int] {
        var m = x; var i = 0
        while i < m.count {
            var j = i
            while j + 1 < m.count && m[j + 1] == m[i] { j += 1 }
            if j - i + 1 < minLen && i > 0 { for k in i...j { m[k] = m[i - 1] } }
            i = j + 1
        }
        return m
    }
    private static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
}
