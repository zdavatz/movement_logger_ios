import Foundation

/// One recorded box session — `SENSnnn.CSV` + `GPSnnn.CSV` — prepared for the
/// video-less Session view (`UI/SessionScreen.swift`). Port of the desktop's
/// `stbox-viz-gui/src/session_view.rs` (`SessionData` / `load`).
///
/// Both files are stamped with the box's own `HAL_GetTick()` ms, so they share
/// one clock and need no alignment: t = 0 is the first sample of either file
/// and every series below is in seconds from there. Wall-clock labels come
/// from the host `# SYNC` anchors when present, else from the GPS UTC.
///
/// The sensor file is ~100 Hz (a 3 h session is ~1 M rows), so charts never
/// draw raw samples — `decimate` reduces a series to min/max pairs over the
/// visible range.
struct SessionData {
    let sensName: String
    let gpsName: String?
    /// Box ms of t = 0 (first sample of either file).
    let t0Ms: Double
    let durationS: Double
    let clock: SessionClock

    let sensT: [Double]
    let accG: [Float]
    let gyroDps: [Float]
    let pitchDeg: [Float]
    let rollDeg: [Float]
    let heightM: [Float]

    let gpsT: [Double]
    let lat: [Double]
    let lon: [Double]
    /// NaN where the row has no fix.
    let speedKmh: [Float]
    let nsat: [Float]
    /// Indices into the gps arrays that are drawable track points (fix,
    /// non-zero position, no multipath jump).
    let track: [Int]
    /// Top of the speed colour scale: 95th-percentile speed, ≥ 5 km/h.
    let speedScale: Double
    let distanceM: Double
    let maxSpeedKmh: Double

    /// GPS hops faster than this between consecutive fixes are multipath
    /// jumps, not movement (same clip as the desktop Race / Session tabs).
    static let maxJumpKmh = 60.0
    /// Pitch/roll come from the accelerometer alone, smoothed over this many
    /// seconds so pumping accelerations don't dominate the angle.
    static let angleSmoothS = 0.5

    // MARK: - Loading

    /// Parse + derive everything. Runs off the main thread; `progress` gets
    /// (file name, fraction 0…1). GPS first: it's small, so a wrong GPS file
    /// fails fast before the big sensor parse.
    static func load(sens: URL, gps: URL?,
                     progress: @escaping (String, Double) -> Void = { _, _ in }) throws -> SessionData {
        var gpsRows: [GpsRow] = []
        var gpsAnchors: [SyncAnchor] = []
        if let g = gps {
            progress(g.lastPathComponent, 0)
            let text = try String(contentsOf: g, encoding: .utf8)
            gpsRows = try CsvParsers.parseGpsText(text)
            gpsAnchors = CsvParsers.parseSyncAnchors(text)
        }
        let name = sens.lastPathComponent
        progress(name, 0)
        let c = try CsvParsers.sensorColumns(fromSensorFile: sens) { progress(name, $0) }
        guard c.count > 0 else {
            throw CsvParseError(message: "\(name): no sensor rows")
        }

        // Ticks are 10 ms units in both parsers.
        let gpsMs = gpsRows.map { $0.ticks * 10 }
        let t0Ms = min(c.ticks[0] * 10, gpsMs.first ?? .greatestFiniteMagnitude)
        let sensT = c.ticks.map { ($0 * 10 - t0Ms) / 1000 }
        let gpsT = gpsMs.map { ($0 - t0Ms) / 1000 }
        let durationS = max(sensT.last ?? 0, gpsT.last ?? 0)

        let (ax, ay, az) = (c.values[0], c.values[1], c.values[2])
        let (gx, gy, gz) = (c.values[3], c.values[4], c.values[5])
        let n = c.count
        var accG = [Float](repeating: 0, count: n)
        var gyroDps = [Float](repeating: 0, count: n)
        for i in 0..<n {
            accG[i] = (ax[i] * ax[i] + ay[i] * ay[i] + az[i] * az[i]).squareRoot() / 1000
            gyroDps[i] = (gx[i] * gx[i] + gy[i] * gy[i] + gz[i] * gz[i]).squareRoot() / 1000
        }

        let hz = (n > 1 && sensT[n - 1] > 0) ? min(max(Double(n) / sensT[n - 1], 1), 1000) : 100
        let win = Int((angleSmoothS * hz).rounded())
        let (pitchDeg, rollDeg) = pitchRoll(ax: smooth(ax, win), ay: smooth(ay, win), az: smooth(az, win))

        // Baro height relative to the start (international barometric
        // formula, reference = median of the first ~second).
        let p = c.values[6]
        let p0 = Double(p.prefix(100).sorted()[min(n, 100) / 2])
        let heightM = smooth(p.map { Float(baroHeightM(Double($0), p0: p0)) }, win)

        let lat = gpsRows.map(\.lat)
        let lon = gpsRows.map(\.lon)
        let speedKmh = gpsRows.map { $0.fix > 0 ? Float($0.speedKmhModule) : .nan }
        let nsat = gpsRows.map { Float($0.numSat) }

        var track: [Int] = []
        var distanceM = 0.0
        for (i, r) in gpsRows.enumerated() {
            if r.fix <= 0 || (r.lat == 0 && r.lon == 0) { continue }
            if let j = track.last {
                let d = haversineM(lat[j], lon[j], lat[i], lon[i])
                let dt = max(gpsT[i] - gpsT[j], 0.05)
                if d / dt * 3.6 > maxJumpKmh { continue }
                distanceM += d
            }
            track.append(i)
        }
        let speeds = track.map { Double(speedKmh[$0]) }.filter(\.isFinite).sorted()
        let maxSpeed = speeds.last ?? 0
        // Colour scale tops out at the 95th percentile so one spike doesn't
        // wash the whole track blue.
        let scale = speeds.isEmpty ? 5 : max(speeds[(speeds.count - 1) * 95 / 100], 5)

        let clock: SessionClock
        if !c.anchors.isEmpty {
            clock = .anchors(c.anchors)
        } else if !gpsAnchors.isEmpty {
            clock = .anchors(gpsAnchors)
        } else {
            // Median of (UTC seconds-of-day − box seconds) over fixed rows.
            let offs = zip(gpsRows, gpsMs)
                .filter { $0.0.fix > 0 }
                .compactMap { r, ms in GpsTime.parseHhmmssSs(r.utc).map { $0 - ms / 1000 } }
                .prefix(200)
                .sorted()
            clock = offs.isEmpty ? .none : .gpsUtc(offsetS: offs[offs.count / 2])
        }

        return SessionData(
            sensName: name, gpsName: gps?.lastPathComponent,
            t0Ms: t0Ms, durationS: durationS, clock: clock,
            sensT: sensT, accG: accG, gyroDps: gyroDps,
            pitchDeg: pitchDeg, rollDeg: rollDeg, heightM: heightM,
            gpsT: gpsT, lat: lat, lon: lon, speedKmh: speedKmh, nsat: nsat,
            track: track, speedScale: scale, distanceM: distanceM, maxSpeedKmh: maxSpeed)
    }

    /// The GPS file of a session: `SENS000.CSV` → `GPS000.CSV`,
    /// `SensPhone_x.csv` → `GpsPhone_x.csv` (case-insensitive).
    static func matchingGpsFile(for sens: URL, in candidates: [URL]) -> URL? {
        let n = sens.lastPathComponent.lowercased()
        guard n.hasPrefix("sens") else { return nil }
        let want = "gps" + n.dropFirst(4)
        return candidates.first { $0.lastPathComponent.lowercased() == want }
    }

    // MARK: - Math (pure, unit-checked)

    /// Box frame: nose = +Y, up = +Z. pitch = atan2(ay, √(ax²+az²)) (nose up
    /// = +), roll = atan2(ax, az). The phone-style long-axis-X formulas swap
    /// pitch and roll on this box (see CLAUDE.md "Live tab — board angles").
    static func pitchRoll(ax: [Float], ay: [Float], az: [Float]) -> ([Float], [Float]) {
        let n = ax.count
        var pitch = [Float](repeating: 0, count: n)
        var roll = [Float](repeating: 0, count: n)
        let deg = Float(180 / Double.pi)
        for i in 0..<n {
            pitch[i] = atan2(ay[i], (ax[i] * ax[i] + az[i] * az[i]).squareRoot()) * deg
            roll[i] = atan2(ax[i], az[i]) * deg
        }
        return (pitch, roll)
    }

    /// International barometric formula, metres above the reference `p0`.
    static func baroHeightM(_ p: Double, p0: Double) -> Double {
        44_330 * (1 - pow(p / p0, 1 / 5.255))
    }

    /// Centred moving average over `win` samples (prefix sums, O(n)).
    static func smooth(_ y: [Float], _ win: Int) -> [Float] {
        guard win > 1, !y.isEmpty else { return y }
        var pre = [Double](repeating: 0, count: y.count + 1)
        for i in 0..<y.count { pre[i + 1] = pre[i] + Double(y[i]) }
        let half = win / 2
        var out = [Float](repeating: 0, count: y.count)
        for i in 0..<y.count {
            let a = max(i - half, 0), b = min(i + half + 1, y.count)
            out[i] = Float((pre[b] - pre[a]) / Double(b - a))
        }
        return out
    }

    static func haversineM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * r * asin(a.squareRoot())
    }

    /// First index with `t[i] > x` (`t` sorted) — Rust's `partition_point(<= x)`.
    static func upperBound(_ t: [Double], _ x: Double) -> Int {
        var lo = 0, hi = t.count
        while lo < hi {
            let m = (lo + hi) / 2
            if t[m] <= x { lo = m + 1 } else { hi = m }
        }
        return lo
    }

    /// First index with `t[i] >= x`.
    static func lowerBound(_ t: [Double], _ x: Double) -> Int {
        var lo = 0, hi = t.count
        while lo < hi {
            let m = (lo + hi) / 2
            if t[m] < x { lo = m + 1 } else { hi = m }
        }
        return lo
    }

    /// Min/max pairs of `y` over `buckets` buckets of the visible range
    /// `[lo, hi]` (`t` sorted), one sample past each edge so the line runs to
    /// the border. NaN samples are skipped; a bucket with none is a gap.
    /// Ranges with ≤ 2·buckets samples come back raw.
    static func decimate(t: [Double], y: [Float], lo: Double, hi: Double,
                         buckets: Int) -> [(t: Double, y: Float)] {
        let a = max(lowerBound(t, lo) - 1, 0)
        let b = min(upperBound(t, hi) + 1, t.count)
        guard b > a else { return [] }
        let n = b - a
        if n <= buckets * 2 {
            return (a..<b).compactMap { y[$0].isFinite ? (t[$0], y[$0]) : nil }
        }
        var out: [(t: Double, y: Float)] = []
        out.reserveCapacity(buckets * 2)
        for k in 0..<buckets {
            let s = a + n * k / buckets, e = a + n * (k + 1) / buckets
            var imin = -1, imax = -1
            for i in s..<e where y[i].isFinite {
                if imin < 0 || y[i] < y[imin] { imin = i }
                if imax < 0 || y[i] > y[imax] { imax = i }
            }
            if imin < 0 { continue }
            let (p, q) = imin <= imax ? (imin, imax) : (imax, imin)
            out.append((t[p], y[p]))
            if q != p { out.append((t[q], y[q])) }
        }
        return out
    }

    /// Value of `y` at time `x` (nearest sample at or before); nil when NaN.
    static func value<T: BinaryFloatingPoint>(_ t: [Double], _ y: [T], at x: Double) -> T? {
        guard !t.isEmpty else { return nil }
        let i = max(upperBound(t, x) - 1, 0)
        return i < y.count && y[i].isFinite ? y[i] : nil
    }

    /// Colour bands for the speed-coloured map track.
    static let speedBands = 16

    /// The track as runs of one speed band each, for the map's polylines.
    /// Points closer than `minSpacingM` to the last kept one are thinned out
    /// and the speed is averaged over ~1 s first, so a 10 Hz track turns into
    /// a few hundred polylines instead of thousands of 1-point colour flips.
    /// Consecutive runs share their boundary point so the line stays
    /// continuous. `band` is 0…`speedBands`−1 of `speedScale`.
    func speedRuns(minSpacingM: Double = 3) -> [(band: Int, points: [Int])] {
        guard track.count > 1 else { return [] }
        let win = max(Int((gpsRateHz).rounded()), 1)
        let v = Self.smooth(track.map { speedKmh[$0].isFinite ? speedKmh[$0] : 0 }, win)
        var runs: [(band: Int, points: [Int])] = []
        var last = -1
        for (k, i) in track.enumerated() {
            let isEnd = k == track.count - 1
            if last >= 0 && !isEnd && Self.haversineM(lat[last], lon[last], lat[i], lon[i]) < minSpacingM {
                continue
            }
            let f = min(max(Double(v[k]) / speedScale, 0), 1)
            let band = Int((f * Double(Self.speedBands - 1)).rounded())
            if let r = runs.last, r.band == band {
                runs[runs.count - 1].points.append(i)
            } else {
                runs.append((band, last >= 0 ? [last, i] : [i]))
            }
            last = i
        }
        return runs.filter { $0.points.count >= 2 }
    }

    // MARK: - Derived

    /// Median fix interval of the drawable track, as Hz (0 = unknown).
    var gpsRateHz: Double {
        guard track.count > 1 else { return 0 }
        let dts = zip(track, track.dropFirst()).map { gpsT[$1] - gpsT[$0] }.filter { $0 > 0 }.sorted()
        return dts.isEmpty ? 0 : 1 / dts[dts.count / 2]
    }

    /// Last drawable track point at or before session time `x`.
    func trackIndex(at x: Double) -> Int? {
        var lo = 0, hi = track.count
        while lo < hi {
            let m = (lo + hi) / 2
            if gpsT[track[m]] <= x { lo = m + 1 } else { hi = m }
        }
        return lo > 0 ? track[lo - 1] : nil
    }

    /// Wall-clock label for session time `x` s, elapsed seconds as fallback.
    func timeLabel(_ x: Double, tenths: Bool) -> String {
        clock.label(boxMs: t0Ms + x * 1000, tenths: tenths) ?? String(format: "%.1f s", x)
    }

    /// The cursor readout line: time, speed, position, sats, |acc|, angles, height.
    func readout(at x: Double) -> String {
        var s = timeLabel(x, tenths: true)
        if let v = Self.value(gpsT, speedKmh, at: x) { s += String(format: "   %.1f km/h", v) }
        if let la = Self.value(gpsT, lat, at: x), let lo = Self.value(gpsT, lon, at: x), la != 0 || lo != 0 {
            s += String(format: "   %.6f, %.6f", la, lo)
        }
        if let n = Self.value(gpsT, nsat, at: x) { s += String(format: "   %.0f sats", n) }
        if let a = Self.value(sensT, accG, at: x) { s += String(format: "   |acc| %.2f g", a) }
        if let p = Self.value(sensT, pitchDeg, at: x), let r = Self.value(sensT, rollDeg, at: x) {
            s += String(format: "   pitch %+.0f°  roll %+.0f°", p, r)
        }
        if let h = Self.value(sensT, heightM, at: x) { s += String(format: "   height %+.1f m", h) }
        return s
    }
}

/// How box ms map to wall-clock time.
enum SessionClock {
    /// Host `# SYNC` anchors: tick (10 ms units) → epoch ms.
    case anchors([SyncAnchor])
    /// GPS UTC: seconds-of-day = box seconds + offset (UTC, no date).
    case gpsUtc(offsetS: Double)
    case none

    /// Local seconds since midnight at box ms `ms`, if known.
    func localSecondsOfDay(boxMs ms: Double) -> Double? {
        switch self {
        case .anchors(let a):
            guard let epoch = CsvParsers.absTimesFromSyncAnchors(ticks: [ms / 10], anchors: a).first
            else { return nil }
            let date = Date(timeIntervalSince1970: Double(epoch) / 1000)
            let tz = Double(TimeZone.current.secondsFromGMT(for: date))
            return (Double(epoch) / 1000 + tz).truncatingRemainder(dividingBy: 86_400)
        case .gpsUtc(let off):
            let tz = Double(TimeZone.current.secondsFromGMT())
            let sod = (ms / 1000 + off + tz).truncatingRemainder(dividingBy: 86_400)
            return sod < 0 ? sod + 86_400 : sod
        case .none:
            return nil
        }
    }

    /// "HH:MM:SS" (or "HH:MM:SS.s") local time at box ms `ms`.
    func label(boxMs ms: Double, tenths: Bool) -> String? {
        guard let sod = localSecondsOfDay(boxMs: ms) else { return nil }
        return Self.format(sod, tenths: tenths)
    }

    static func format(_ sod: Double, tenths: Bool) -> String {
        let s = (sod * 10).rounded(.down) / 10
        let whole = Int(s)
        let (h, m) = (whole / 3600 % 24, whole / 60 % 60)
        return tenths
            ? String(format: "%02d:%02d:%04.1f", h, m, s - Double(whole / 60 * 60))
            : String(format: "%02d:%02d:%02d", h, m, whole % 60)
    }
}
