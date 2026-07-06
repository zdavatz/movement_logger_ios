import Foundation

/// One decoded SensorStream snapshot. Mirrors the 46-byte packed layout from
/// the PumpLogger firmware (DESIGN.md §3 in fp-sns-stbox1), scaled into
/// convenient SI-ish units so the UI doesn't need to know the wire encoding.
///
/// Authoritative spec: `stbox-viz-gui/src/ble.rs` LiveSample (desktop) and the
/// Android port at `ble/LiveSample.kt`.
struct LiveSample: Equatable {
    /// Wire-layout size, in bytes.
    static let wireSize: Int = 46

    /// Box-local monotonic milliseconds since boot. Not wall-clock — the box has no RTC.
    let timestampMs: UInt32
    /// Linear acceleration, mg per axis (LSM6DSV16X).
    let accMg: (Int16, Int16, Int16)
    /// Angular rate. Firmware ≤ v0.0.26 packed centi-dps (÷100 for °/s, but
    /// clamped at ±327 dps); v0.0.27+ packs DECI-dps (÷10 for °/s, full
    /// ±500 dps FS). Name kept for wire-parse stability; consumers divide by
    /// 10. Only meaningful with matching firmware.
    let gyroCdps: (Int16, Int16, Int16)
    /// Magnetic field, milligauss per axis (LIS2MDL).
    let magMg: (Int16, Int16, Int16)
    /// Barometric pressure, raw Pa (LPS22DF). Divide by 100 for hPa.
    let pressurePa: Int32
    /// Air temperature, 0.01 °C steps. Divide by 100 for °C.
    let temperatureCc: Int16
    /// GPS latitude × 1e7. `Int32.max` = no fix yet.
    let gpsLatE7: Int32
    let gpsLonE7: Int32
    /// GPS altitude, signed metres.
    let gpsAltM: Int16
    /// GPS speed, cm/h × 10 (~ km/h × 100). Divide by 100 for km/h.
    let gpsSpeedCmh: Int16
    /// GPS course, centi-degrees (0..35999).
    let gpsCourseCdeg: Int16
    /// Fix quality: 0 = no fix, 1 = GPS, …
    let gpsFixQ: UInt8
    /// Satellites used in the current fix.
    let gpsNsat: UInt8
    /// Strongest satellite C/N0 in dB-Hz (from GSV); 0 = no data. Antenna-quality metric.
    let gpsCn0Max: UInt8
    let gpsValid: Bool
    let loggingActive: Bool
    let lowBattery: Bool

    /// Lat/lon in degrees if the fix is valid, else nil.
    func latLonDeg() -> (Double, Double)? {
        if !gpsValid || gpsLatE7 == Int32.max { return nil }
        return (Double(gpsLatE7) / 1.0e7, Double(gpsLonE7) / 1.0e7)
    }

    /// ‖acc‖ in g — used for the Live tab sparkline.
    func accMagnitudeG() -> Double {
        let x = Double(accMg.0) / 1000.0
        let y = Double(accMg.1) / 1000.0
        let z = Double(accMg.2) / 1000.0
        return (x * x + y * y + z * z).squareRoot()
    }

    /// Roll φ (around the X axis), in degrees, derived from the gravity
    /// component of accel. Meaningful only when net non-gravitational
    /// acceleration is small. Range (-180, 180].
    func rollDeg() -> Double {
        let ay = Double(accMg.1), az = Double(accMg.2)
        return atan2(ay, az) * 180.0 / .pi
    }

    /// Pitch θ (around the Y axis), in degrees. Range [-90, 90].
    func pitchDeg() -> Double {
        let ax = Double(accMg.0), ay = Double(accMg.1), az = Double(accMg.2)
        return atan2(-ax, (ay * ay + az * az).squareRoot()) * 180.0 / .pi
    }

    /// Tilt-compensated compass heading ψ (yaw), in degrees, normalized to
    /// [0, 360). Uses accel-derived roll/pitch to project the mag vector
    /// onto the horizontal plane before taking atan2 of its components.
    /// Standard formula — see e.g. ST AN4248.
    func headingDeg(magOffMg: [Double]? = nil) -> Double {
        let ax = Double(accMg.0), ay = Double(accMg.1), az = Double(accMg.2)
        // Hard-iron correction (Live tab "Calibrate compass"): a box-fixed
        // magnetic bias bigger than the ~200 mG horizontal earth field
        // otherwise pins the heading regardless of rotation.
        let off = magOffMg ?? [0, 0, 0]
        let mx = Double(magMg.0) - off[0]
        let my = Double(magMg.1) - off[1]
        let mz = Double(magMg.2) - off[2]
        let roll = atan2(ay, az)
        let pitch = atan2(-ax, (ay * ay + az * az).squareRoot())
        let sR = sin(roll), cR = cos(roll)
        let sP = sin(pitch), cP = cos(pitch)
        let mxH = mx * cP + my * sR * sP + mz * cR * sP
        let myH = my * cR - mz * sR
        var deg = atan2(-myH, mxH) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return deg
    }

    /// Per-axis tilt: angle between each board axis and the measured gravity
    /// vector, in degrees [0, 180]. `acos(component / ‖a‖)`. Meaningful only
    /// while net non-gravitational acceleration is small (same caveat as
    /// `rollDeg`/`pitchDeg`).
    func accAxisAnglesDeg() -> (Double, Double, Double) {
        let x = Double(accMg.0), y = Double(accMg.1), z = Double(accMg.2)
        let m = (x * x + y * y + z * z).squareRoot()
        guard m > 1e-6 else { return (0, 0, 0) }
        func ang(_ c: Double) -> Double { acos(min(max(c / m, -1), 1)) * 180.0 / .pi }
        return (ang(x), ang(y), ang(z))
    }

    /// Per-axis angle between each board axis and the measured magnetic
    /// field vector, in degrees [0, 180].
    func magAxisAnglesDeg() -> (Double, Double, Double) {
        let x = Double(magMg.0), y = Double(magMg.1), z = Double(magMg.2)
        let m = (x * x + y * y + z * z).squareRoot()
        guard m > 1e-6 else { return (0, 0, 0) }
        func ang(_ c: Double) -> Double { acos(min(max(c / m, -1), 1)) * 180.0 / .pi }
        return (ang(x), ang(y), ang(z))
    }

    /// Raw (NOT tilt-compensated) magnetic heading from the board-plane
    /// components, `atan2(my, mx)`, normalized to [0, 360). Contrast with
    /// `headingDeg()`, which projects out roll/pitch first.
    func magHeadingRawDeg() -> Double {
        var deg = atan2(Double(magMg.1), Double(magMg.0)) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return deg
    }

    /// Magnetic inclination (dip): angle of the field vector relative to the
    /// board's XY plane, `atan2(mz, ‖mxy‖)`, in degrees [-90, 90].
    func magDipDeg() -> Double {
        let x = Double(magMg.0), y = Double(magMg.1), z = Double(magMg.2)
        return atan2(z, (x * x + y * y).squareRoot()) * 180.0 / .pi
    }

    /// Decode the 46-byte little-endian wire layout. Returns nil on bad length.
    static func parse(_ data: Data) -> LiveSample? {
        guard data.count == wireSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> LiveSample in
            func u32(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func i32(_ offset: Int) -> Int32 { raw.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
            func i16(_ offset: Int) -> Int16 { raw.loadUnaligned(fromByteOffset: offset, as: Int16.self) }
            let flags = raw[44]
            return LiveSample(
                timestampMs: UInt32(littleEndian: u32(0)),
                accMg: (Int16(littleEndian: i16(4)),
                        Int16(littleEndian: i16(6)),
                        Int16(littleEndian: i16(8))),
                gyroCdps: (Int16(littleEndian: i16(10)),
                           Int16(littleEndian: i16(12)),
                           Int16(littleEndian: i16(14))),
                magMg: (Int16(littleEndian: i16(16)),
                        Int16(littleEndian: i16(18)),
                        Int16(littleEndian: i16(20))),
                pressurePa: Int32(littleEndian: i32(22)),
                temperatureCc: Int16(littleEndian: i16(26)),
                gpsLatE7: Int32(littleEndian: i32(28)),
                gpsLonE7: Int32(littleEndian: i32(32)),
                gpsAltM: Int16(littleEndian: i16(36)),
                gpsSpeedCmh: Int16(littleEndian: i16(38)),
                gpsCourseCdeg: Int16(littleEndian: i16(40)),
                gpsFixQ: raw[42],
                gpsNsat: raw[43],
                gpsCn0Max: raw[45],
                gpsValid: flags & 0x01 != 0,
                loggingActive: flags & 0x04 != 0,
                lowBattery: flags & 0x02 != 0
            )
        }
    }

    static func == (lhs: LiveSample, rhs: LiveSample) -> Bool {
        lhs.timestampMs == rhs.timestampMs &&
        lhs.accMg == rhs.accMg && lhs.gyroCdps == rhs.gyroCdps &&
        lhs.magMg == rhs.magMg && lhs.pressurePa == rhs.pressurePa &&
        lhs.temperatureCc == rhs.temperatureCc &&
        lhs.gpsLatE7 == rhs.gpsLatE7 && lhs.gpsLonE7 == rhs.gpsLonE7 &&
        lhs.gpsAltM == rhs.gpsAltM && lhs.gpsSpeedCmh == rhs.gpsSpeedCmh &&
        lhs.gpsCourseCdeg == rhs.gpsCourseCdeg &&
        lhs.gpsFixQ == rhs.gpsFixQ && lhs.gpsNsat == rhs.gpsNsat &&
        lhs.gpsCn0Max == rhs.gpsCn0Max &&
        lhs.gpsValid == rhs.gpsValid && lhs.loggingActive == rhs.loggingActive &&
        lhs.lowBattery == rhs.lowBattery
    }
}

/// One decoded BatteryStatus snapshot. 8-byte packed little-endian layout
/// (firmware `Src/battery.c`; desktop `stbox-viz-gui/src/ble.rs` BatterySample).
/// NOTE its flags byte differs from `LiveSample`'s: here bit0 = low_batt,
/// bit1 = logging. 8 B is well under any MTU — single-notify only, no
/// chunk reassembly (unlike SensorStream).
struct BatterySample: Equatable {
    static let wireSize: Int = 8

    let voltageMv: UInt16      // @0  pack voltage, mV
    let socX10: UInt16         // @2  SoC% × 10
    let currentX100uA: Int16   // @4  signed: + charging / − draining
    let lowBatt: Bool          // flags @6 bit0 (raised at SoC < 10 %)
    let logging: Bool          // flags @6 bit1
    // byte 7 reserved

    /// SoC as a 0…1 fraction for a ProgressView.
    var socFrac: Double { min(max(Double(socX10) / 1000.0, 0), 1) }
    /// SoC as whole percent (rounded, matches desktop `soc_pct`).
    var socPct: Int { (Int(socX10) + 5) / 10 }
    /// Pack voltage in volts.
    var volts: Double { Double(voltageMv) / 1000.0 }
    /// Current in amps (+ charging / − draining).
    var amps: Double { Double(currentX100uA) / 10_000.0 }

    static func parse(_ data: Data) -> BatterySample? {
        guard data.count == wireSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> BatterySample in
            func u16(_ o: Int) -> UInt16 { raw.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
            func i16(_ o: Int) -> Int16  { raw.loadUnaligned(fromByteOffset: o, as: Int16.self) }
            let flags = raw[6]
            return BatterySample(
                voltageMv:     UInt16(littleEndian: u16(0)),
                socX10:        UInt16(littleEndian: u16(2)),
                currentX100uA: Int16(littleEndian: i16(4)),
                lowBatt:       flags & 0x01 != 0,
                logging:       flags & 0x02 != 0
            )
        }
    }
}


// MARK: - TRIAD full-attitude estimation

/// Full 3D attitude straight from the two measured reference vectors —
/// gravity (accel) and the earth's magnetic field (mag) — via the classic
/// TRIAD construction: down = -acc, east = down x mag, north = east x down.
/// One rotation matrix instead of chained Euler angles: all poses are
/// consistent (including upside-down and compound rotations), no gimbal
/// freeze, no per-axis sign patches.
///
/// Remaining calibration parameters (set by the Live tab's taps):
/// - `off`:    hard-iron offset subtracted from the raw mag (auto-learned)
/// - `mirror`: +/-1 scene reflection — see `world`
/// - `biasDeg`: rotation about the vertical (the "USB-C points SOUTH" tap)
/// - nose end (+y / -y): which body end the arrow marks
enum Triad {
    /// Body-frame unit rows (north, east, down) of the attitude, or nil
    /// when degenerate (zero vectors / field parallel to gravity).
    ///
    /// The LIS2MDL's Y axis is mirrored relative to the IMU frame on this
    /// board (ST "esu" vs "enu" mounting; verified empirically from logged
    /// sessions — only the mag-Y flip keeps the earth field's dip angle
    /// constant across ALL poses, which is what makes the attitude
    /// consistent instead of correct-in-one-pose-wrong-in-others). This is
    /// a fixed hardware fact, NOT user-configurable — it is always applied.
    static func rows(acc: (Int16, Int16, Int16), mag: (Int16, Int16, Int16),
                     off: [Double]?) -> (n: [Double], e: [Double], d: [Double])? {
        let a = [Double(acc.0), Double(acc.1), Double(acc.2)]
        let an = norm(a)
        guard an > 100 else { return nil }          // < 0.1 g: free-fall/garbage
        let d = a.map { -$0 / an }                  // accel reads +1g on the UP axis
        let o = off ?? [0, 0, 0]
        let m = [Double(mag.0) - o[0],
                 -(Double(mag.1) - o[1]),           // fixed mag-Y chirality flip
                 Double(mag.2) - o[2]]
        let mn = norm(m)
        guard mn > 20 else { return nil }           // essentially no field signal
        let mu = m.map { $0 / mn }
        var e = cross(d, mu)
        let en = norm(e)
        guard en > 0.05 else { return nil }         // field ~parallel to gravity
        e = e.map { $0 / en }
        let n = cross(e, d)                          // unit by construction
        return (n, e, d)
    }

    /// World (north, east, down) coordinates of a body-frame point, with
    /// the scene reflection and the vertical-axis bias rotation applied.
    ///
    /// No scene-reflection knob: the mag-Y flip in `rows` already yields the
    /// physically-correct attitude (confirmed against the box — "360°
    /// clockwise is correct"). A user-facing left/right mirror was a mistake:
    /// a reflection REVERSES the yaw sense, so it can't be undone by the
    /// direction bias (a rotation) — it broke the 360° heading and threw away
    /// the "USB-C south" reference every time it was toggled. The handedness
    /// is a fixed hardware fact, not a calibration choice.
    static func world(_ p: [Double],
                      rows: (n: [Double], e: [Double], d: [Double]),
                      biasDeg: Double) -> (n: Double, e: Double, d: Double) {
        let n0 = dot(rows.n, p)
        let e0 = dot(rows.e, p)
        let d0 = dot(rows.d, p)
        let b = biasDeg * .pi / 180
        // Rotate the world frame by -bias: azimuths shrink by bias.
        let n1 = n0 * cos(b) + e0 * sin(b)
        let e1 = -n0 * sin(b) + e0 * cos(b)
        return (n1, e1, d0)
    }

    /// Compass azimuth (deg, [0,360)) that the nose end currently points
    /// to, bias applied. nil when degenerate.
    static func noseAzimuth(acc: (Int16, Int16, Int16), mag: (Int16, Int16, Int16),
                            off: [Double]?, nosePlusY: Bool,
                            biasDeg: Double) -> Double? {
        guard let r = rows(acc: acc, mag: mag, off: off) else { return nil }
        let nose = [0.0, nosePlusY ? 1.0 : -1.0, 0.0]
        let w = world(nose, rows: r, biasDeg: biasDeg)
        var az = atan2(w.e, w.n) * 180 / .pi
        if az < 0 { az += 360 }
        return az
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }
    private static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1],
         a[2] * b[0] - a[0] * b[2],
         a[0] * b[1] - a[1] * b[0]]
    }
    private static func norm(_ a: [Double]) -> Double {
        (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot()
    }
}

/// Body-frame world axes (n, e, d) — the render rows, produced by the
/// gyro+accel filter below instead of the magnetometer.
struct OriRows { let n: [Double]; let e: [Double]; let d: [Double] }

/// Accel + gyro complementary filter with drone-style gyro-bias
/// auto-calibration — the live 3D preview's attitude source.
///
/// Why not the magnetometer: the mag needs a clean 3D hard-iron
/// calibration that the tilted / on-end poses kept exposing as wrong. The
/// gyro doesn't — it measures the box's actual rotation directly:
///   • DOWN (tilt) comes from the accelerometer — exact, drift-free, every
///     frame, so which face is up is always right in every pose.
///   • the horizontal frame is carried by the gyroscope — the box tracks
///     its real rotation (blue face, on-end, backflip all consistent).
///   • gyro bias (the slow-yaw-drift culprit) is auto-measured whenever the
///     box rests still — exactly like a drone's pre-flight gyro cal — and
///     subtracted, so the heading barely drifts.
///   • absolute heading (where north is) is the one thing gyro+accel can't
///     know; the "USB-C south" / "match iPhone compass" tap supplies it via
///     the render bias.
final class OrientationFilter {
    private var n = [1.0, 0.0, 0.0]     // body-frame world-North
    private var e = [0.0, 1.0, 0.0]     // body-frame world-East
    private var d = [0.0, 0.0, -1.0]    // body-frame world-Down (flat lid-up)
    private var gbias = [0.0, 0.0, 0.0] // gyro bias, centi-dps
    private var lastTick: UInt32? = nil
    private var inited = false

    var rows: OriRows? { inited ? OriRows(n: n, e: e, d: d) : nil }
    var gyroBiasCdps: [Double] { gbias }
    var isReady: Bool { inited }

    /// Re-seed the attitude on the next sample; keep the learned gyro bias.
    func reset() { inited = false; lastTick = nil }

    func update(_ s: LiveSample, magOffset: [Double]?) {
        let acc = [Double(s.accMg.0), Double(s.accMg.1), Double(s.accMg.2)]
        let aMag = (acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]).squareRoot()
        guard aMag > 100 else { return }

        // gyroCdps carries DECI-dps from firmware v0.0.27+ (÷10 for dps) —
        // the wider scale that no longer clamps a fast rotation at 327°/s.
        let gRaw = [Double(s.gyroCdps.0), Double(s.gyroCdps.1), Double(s.gyroCdps.2)]
        var gCorr = [gRaw[0] - gbias[0], gRaw[1] - gbias[1], gRaw[2] - gbias[2]]

        // Drone-style gyro-bias cal: while the box rests (tiny corrected
        // rate AND ~1 g), the raw gyro reading IS the bias — ease toward it.
        // 25 deci-dps = 2.5 dps threshold for "still".
        let gMag = (gCorr[0] * gCorr[0] + gCorr[1] * gCorr[1] + gCorr[2] * gCorr[2]).squareRoot()
        if gMag < 25, aMag > 900, aMag < 1100 {
            let k = 0.02
            for i in 0..<3 { gbias[i] = gbias[i] * (1 - k) + gRaw[i] * k }
            gCorr = [gRaw[0] - gbias[0], gRaw[1] - gbias[1], gRaw[2] - gbias[2]]
        }

        let dt: Double
        if let last = lastTick {
            dt = min(max(Double(s.timestampMs &- last) / 1000.0, 0.005), 0.5)
        } else { dt = 0.1 }
        lastTick = s.timestampMs

        // Seed the frame from accel + a mag-derived heading (once), so the
        // preview doesn't start at a random yaw; the gyro owns it after.
        if !inited {
            if let r = Triad.rows(acc: s.accMg, mag: s.magMg, off: magOffset) {
                n = r.n; e = r.e; d = r.d; inited = true
            }
            return
        }

        // Gyro propagation. A world-fixed vector expressed in the body frame
        // rotates by the body's inverse rotation over dt. Use the EXACT
        // rotation (Rodrigues) by angle -|ω|·dt about ω̂ — not the first-order
        // n - ω×n·dt, which loses accuracy badly for the large per-sample
        // angles a fast "flying" motion produces at 10 Hz (the box running
        // away). Exact rotation is correct at any angle.
        let w = [gCorr[0] * (.pi / 1800.0),    // deci-dps → rad/s (÷10 ·π/180)
                 gCorr[1] * (.pi / 1800.0),
                 gCorr[2] * (.pi / 1800.0)]
        let wMag = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        if wMag > 1e-9 {
            let ang = -wMag * dt
            let axis = [w[0] / wMag, w[1] / wMag, w[2] / wMag]
            n = rotate(n, about: axis, by: ang)
            d = rotate(d, about: axis, by: ang)
        }

        // Tilt correction: nudge DOWN toward measured gravity when the accel
        // is trustworthy (near 1 g). Rate-independent gain (∝ dt, τ ≈ 0.6 s)
        // so bumping the stream rate doesn't make it 2× more aggressive.
        if aMag > 800, aMag < 1200 {
            let inv = -1.0 / aMag
            let dMeas = [acc[0] * inv, acc[1] * inv, acc[2] * inv]
            let k = min(dt / 0.6, 0.15)
            for i in 0..<3 { d[i] = d[i] * (1 - k) + dMeas[i] * k }
        }

        // Re-orthonormalise: D, then N ⟂ D, then E = D × N (NED: D×N = E).
        d = normalized(d)
        let nd = n[0] * d[0] + n[1] * d[1] + n[2] * d[2]
        n = normalized([n[0] - nd * d[0], n[1] - nd * d[1], n[2] - nd * d[2]])
        e = cross(d, n)

        // NO magnetometer heading re-anchor. This box's hard-iron is so
        // severe that the computed flat heading reads ≈ south regardless of
        // orientation, so ANY mag correction just yanked the arrow back to
        // south and broke flat rotations. Heading is therefore pure gyro
        // (seeded once from the mag at init, then carried by the gyro with
        // its bias auto-removed at rest). The user sets the absolute
        // direction with "USB-C south"; it holds and drifts only slowly —
        // re-tap if it wanders. Correct rotation beats a wrong absolute lock.
        _ = magOffset
    }

    /// Rodrigues rotation of `v` about unit axis `k` by angle `a` (rad).
    private func rotate(_ v: [Double], about k: [Double], by a: Double) -> [Double] {
        let ca = cos(a), sa = sin(a)
        let kv = cross(k, v)
        let kd = k[0] * v[0] + k[1] * v[1] + k[2] * v[2]
        let f = kd * (1 - ca)
        return normalized([
            v[0] * ca + kv[0] * sa + k[0] * f,
            v[1] * ca + kv[1] * sa + k[1] * f,
            v[2] * ca + kv[2] * sa + k[2] * f,
        ])
    }

    /// Nose-end compass azimuth (deg, [0,360)) from the filter, bias applied.
    func noseAzimuth(nosePlusY: Bool, biasDeg: Double) -> Double? {
        guard inited else { return nil }
        let nose = [0.0, nosePlusY ? 1.0 : -1.0, 0.0]
        let w = Triad.world(nose, rows: (n: n, e: e, d: d), biasDeg: biasDeg)
        var az = atan2(w.e, w.n) * 180 / .pi
        if az < 0 { az += 360 }
        return az
    }

    private func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }
    private func normalized(_ v: [Double]) -> [Double] {
        let m = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        return m > 1e-9 ? [v[0] / m, v[1] / m, v[2] / m] : v
    }
}

// MARK: - Board angles (pitch / roll / yaw in degrees, for the Live readout)

/// Intuitive board attitude in degrees, derived from the gyro+accel filter's
/// `OriRows` (drift-free tilt from the accelerometer, heading carried by the
/// gyroscope) and expressed about the box's PHYSICAL axes as the 3D preview
/// defines them — nose = long axis (y), up = out of the lid (z):
///
///   • `pitch` — nose up (+) / down (−): elevation of the nose above horizontal.
///   • `roll`  — bank right/starboard (+) / left (−) about the nose axis.
///   • `yaw`   — compass azimuth [0,360) the nose points to (render bias applied).
///
/// Each is a single decoupled physical quantity — NOT a coupled Euler triple —
/// so the signs are individually predictable and the numbers stay intuitive at
/// the modest angles a foil sees (this side-steps the gimbal / axis-order
/// pitfalls that a matrix→Euler decomposition would reintroduce). The absolute
/// readout passes the real heading bias so yaw is a compass heading; the
/// calibrated (tared) readout passes `biasDeg: 0` so "how far I've turned since
/// I zeroed" is independent of the direction calibration. Pitch and roll are
/// invariant to the vertical bias, so both readouts agree on them.
struct BoardAngles {
    let pitchDeg: Double
    let rollDeg: Double
    let yawDeg: Double

    static func from(rows: OriRows, nosePlusY: Bool, biasDeg: Double) -> BoardAngles {
        let s = nosePlusY ? 1.0 : -1.0
        func world(_ p: [Double]) -> [Double] {
            let w = Triad.world(p, rows: (n: rows.n, e: rows.e, d: rows.d), biasDeg: biasDeg)
            return [w.n, w.e, w.d]
        }
        let nose = world([0, s, 0])          // nose axis in world (north, east, down)
        let up = world([0, 0, 1])            // lid-up axis in world

        // Pitch: elevation of the nose above the horizon (−Down is up).
        let pitch = asin(min(max(-nose[2], -1), 1)) * 180 / .pi

        // Yaw: compass azimuth of the nose, [0, 360).
        var yaw = atan2(nose[1], nose[0]) * 180 / .pi
        if yaw < 0 { yaw += 360 }

        // Roll (bank about the nose): angle of the box-up axis away from the
        // vertical plane through the nose. Reference frame in the plane ⟂ nose:
        // levelUp = world-up projected ⟂ nose; right = nose × levelUp (starboard).
        let worldUp = [0.0, 0.0, -1.0]                       // up = −Down
        let nHat = normalize3(nose)
        let dun = dot3(worldUp, nHat)
        let levelUp = normalize3([worldUp[0] - dun * nHat[0],
                                  worldUp[1] - dun * nHat[1],
                                  worldUp[2] - dun * nHat[2]])
        let right = cross3(nHat, levelUp)
        let roll = atan2(dot3(up, right), dot3(up, levelUp)) * 180 / .pi

        return BoardAngles(pitchDeg: pitch, rollDeg: roll, yawDeg: yaw)
    }

    private static func dot3(_ a: [Double], _ b: [Double]) -> Double {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }
    private static func cross3(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }
    private static func normalize3(_ v: [Double]) -> [Double] {
        let m = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        return m > 1e-9 ? [v[0] / m, v[1] / m, v[2] / m] : [0, 0, 1]
    }
}

/// Wrap a signed degree delta into (−180, 180] — used for the tared yaw.
func normDeltaDeg(_ d: Double) -> Double {
    var v = d.truncatingRemainder(dividingBy: 360)
    if v > 180 { v -= 360 }
    if v <= -180 { v += 360 }
    return v
}
