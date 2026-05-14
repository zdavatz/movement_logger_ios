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
    /// Angular rate, centi-dps per axis (raw_LSB × 1.75, ±327.67 dps). Divide by 100 for °/s.
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
        lhs.gpsValid == rhs.gpsValid && lhs.loggingActive == rhs.loggingActive &&
        lhs.lowBattery == rhs.lowBattery
    }
}
