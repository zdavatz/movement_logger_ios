import Foundation

/// SD-card recording parsers — Swift port of `CsvParsers.kt` / `io.rs`.
///
/// Three file kinds the firmware writes per logging session:
///
/// - `Sens*.csv`  ~100 Hz IMU + baro samples (12 columns)
/// - `Gps*.csv`   ~1 Hz GPS fixes (10 columns)
/// - `Bat*.csv`   battery voltage / SOC / current (4 columns)
///
/// All three start with a `Time [10ms]` column — ThreadX ticks where one
/// tick is 10 ms. Pre-22.4.2026 firmware called it `Time [mS]`; both
/// spellings are accepted.

/// Single sensor sample. Units match the CSV verbatim (mg / mdps / mgauss / hPa / °C).
struct SensorRow {
    let ticks: Double
    let accX: Double
    let accY: Double
    let accZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double
    let magX: Double
    let magY: Double
    let magZ: Double
    let pressureMb: Double
    let temperatureC: Double
}

/// Single GPS fix row. UTC kept as the raw `hhmmss.ss` string for display + alignment.
struct GpsRow {
    let ticks: Double
    let utc: String
    let lat: Double
    let lon: Double
    let altM: Double
    let speedKmhModule: Double
    let courseDeg: Double
    let fix: Int
    let numSat: Int
    let hdop: Double
    /// Water temperature (°C) from the Apple Watch Ultra's submersion
    /// sensor — `WaterTemp [C]` column, written by `WatchGpsLogger` while
    /// the wrist is in the water. NaN when the column is absent (box /
    /// u-blox files, older watch rides) or the sensor had no reading.
    var waterTempC: Double = .nan
}

/// Battery row. Units match the CSV — voltage in mV, SOC in 0.1 %, current in 100 µA.
struct BatteryRow {
    let ticks: Double
    let voltageMv: Int
    let socTenthPct: Int
    let currentHundredUa: Int
}

/// A host-clock time-sync anchor the firmware stamps into Sens/Gps CSVs on
/// each BLE connect (`SET_TIME` 0x08): a `# SYNC epoch_ms=… tick_ms=…`
/// comment line pairing the phone's absolute wall-clock millis with the
/// box's free-running ms counter. Because the box has no RTC, these anchors
/// are the *only* drift-free, GPS-independent way to map a logged row's tick
/// to absolute time — and they share the phone's clock domain with the
/// replay video's `creation_time`, eliminating cross-clock skew.
struct SyncAnchor: Equatable {
    /// Box tick in the SAME unit as `SensorRow.ticks` / `GpsRow.ticks`
    /// (10 ms units), so it slots straight into the abs-time interpolation.
    let ticks: Double
    /// Phone wall-clock epoch milliseconds the host pushed at this tick.
    let epochMs: Int64
}

struct CsvParseError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CsvParsers {

    static func parseSensorFile(_ url: URL) throws -> [SensorRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseSensorText(text)
    }

    static func parseGpsFile(_ url: URL) throws -> [GpsRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseGpsText(text)
    }

    static func parseBatteryFile(_ url: URL) throws -> [BatteryRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseBatteryText(text)
    }

    static func parseSyncAnchorsFile(_ url: URL) -> [SyncAnchor] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseSyncAnchors(text)
    }

    /// Pull every `# SYNC epoch_ms=<u64> tick_ms=<u32>` marker out of a Sens
    /// or Gps CSV (written by the firmware's SET_TIME handler). `tick_ms` is
    /// the box's raw `HAL_GetTick()` ms — the same clock as the `ms`/`Time`
    /// column — so we divide by the file's tick divisor to land in the
    /// row-tick (10 ms) unit. The data-row parsers already skip these comment
    /// lines (they fail the float parse and `continue`), so this is a cheap
    /// separate pass that never disturbs row parsing. Returns [] for files
    /// from firmware that predates the marker (legacy / never-connected).
    static func parseSyncAnchors(_ text: String) -> [SyncAnchor] {
        var tickDiv = 10.0          // compact `ms` schema → raw ms; ÷10 → 10ms ticks
        var sawHeader = false
        var out: [SyncAnchor] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r \t"))
            if line.isEmpty { continue }
            if !sawHeader {
                sawHeader = true
                // Legacy spaced header ("Time [10ms]", …) is already in 10ms
                // units; the compact header ("ms,…") stores raw ms.
                if line.lowercased().contains("time [") { tickDiv = 1.0 }
                continue
            }
            guard line.hasPrefix("#"), line.contains("SYNC") else { continue }
            var epochMs: Int64?
            var tickMs: Double?
            for tok in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                if tok.hasPrefix("epoch_ms=") {
                    epochMs = Int64(tok.dropFirst("epoch_ms=".count))
                } else if tok.hasPrefix("tick_ms=") {
                    tickMs = Double(tok.dropFirst("tick_ms=".count))
                }
            }
            if let e = epochMs, let t = tickMs, e > 0 {
                out.append(SyncAnchor(ticks: t / tickDiv, epochMs: e))
            }
        }
        // Sort + dedupe by tick so the abs-time interpolation gets a clean,
        // monotone anchor curve even if connects produced out-of-order or
        // duplicate markers.
        out.sort { $0.ticks < $1.ticks }
        var deduped: [SyncAnchor] = []
        for a in out where deduped.last?.ticks != a.ticks { deduped.append(a) }
        return deduped
    }

    static func parseSensorText(_ text: String) throws -> [SensorRow] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .makeIterator()
        guard let header = lines.next(), !header.isEmpty else {
            throw CsvParseError(message: "sensor csv: empty file")
        }
        let cols = try HeaderMap(headerLine: header)
        // Post-22.4.2026 firmware switched to compact column names
        // (`ms`, `ax_mg`, …); pre-22.4 used the spaced `Time [10ms]` /
        // `AccX [mg]` form. We accept BOTH. The `ms` column is in raw
        // milliseconds so divide by 10 to keep `ticks` in 10ms units
        // (the unit the interpolator and fusion code expect).
        let iT: Int
        let tickDiv: Double
        if let i = cols.idxOrNil("ms") {
            iT = i; tickDiv = 10.0
        } else {
            iT = try cols.idxAny("Time [10ms]", "Time [mS]"); tickDiv = 1.0
        }
        let iAx = try cols.idxAny("AccX [mg]", "ax_mg")
        let iAy = try cols.idxAny("AccY [mg]", "ay_mg")
        let iAz = try cols.idxAny("AccZ [mg]", "az_mg")
        let iGx = try cols.idxAny("GyroX [mdps]", "gx_mdps")
        let iGy = try cols.idxAny("GyroY [mdps]", "gy_mdps")
        let iGz = try cols.idxAny("GyroZ [mdps]", "gz_mdps")
        // New firmware emits magnetometer in milligauss under `mx_mg`
        // (still same physical units as `MagX [mgauss]` — 1 mg ≡ 1 mgauss).
        let iMx = try cols.idxAny("MagX [mgauss]", "mx_mg")
        let iMy = try cols.idxAny("MagY [mgauss]", "my_mg")
        let iMz = try cols.idxAny("MagZ [mgauss]", "mz_mg")
        // Pressure: old `P [mB]` (millibar) and new `p_hPa` (hectopascal)
        // are numerically identical (1 mbar = 1 hPa).
        let iP  = try cols.idxAny("P [mB]", "p_hPa")
        let iTc = try cols.idxAny("T ['C]", "t_C")

        var out: [SensorRow] = []
        out.reserveCapacity(8192)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            // Tolerate occasional corrupted rows — real SD-card recordings
            // sometimes contain empty fields or jammed values like "-30-123"
            // when the firmware is interrupted mid-write. Bailing on the
            // first bad row would discard the entire (otherwise good)
            // session. Skip the row and keep going.
            do {
                out.append(SensorRow(
                    ticks: try parseDouble(r, iT) / tickDiv,
                    accX:  try parseDouble(r, iAx),
                    accY:  try parseDouble(r, iAy),
                    accZ:  try parseDouble(r, iAz),
                    gyroX: try parseDouble(r, iGx),
                    gyroY: try parseDouble(r, iGy),
                    gyroZ: try parseDouble(r, iGz),
                    magX:  try parseDouble(r, iMx),
                    magY:  try parseDouble(r, iMy),
                    magZ:  try parseDouble(r, iMz),
                    pressureMb:   try parseDouble(r, iP),
                    temperatureC: try parseDouble(r, iTc),
                ))
            } catch {
                continue
            }
        }
        return out
    }

    static func parseGpsText(_ text: String) throws -> [GpsRow] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .makeIterator()
        guard let header = lines.next(), !header.isEmpty else {
            throw CsvParseError(message: "gps csv: empty file")
        }
        let cols = try HeaderMap(headerLine: header)
        // Post-22.4.2026 firmware switched to compact column names. `ms` is
        // raw milliseconds, so divide by 10 to stay in 10ms ticks.
        let iT: Int
        let tickDiv: Double
        if let i = cols.idxOrNil("ms") {
            iT = i; tickDiv = 10.0
        } else {
            iT = try cols.idxAny("Time [10ms]", "Time [mS]"); tickDiv = 1.0
        }
        let iUtc = try cols.idxAny("UTC", "utc")
        // The Apple Watch GPS logger (`WatchGpsLogger.swift`) writes bracketed
        // column names — `Lat [deg]` / `Lon [deg]` / `SpeedKMh` — so accept
        // those alongside the box firmware's `Lat`/`lat` and `speed_kmh`.
        let iLat = try cols.idxAny("Lat", "lat", "Lat [deg]")
        let iLon = try cols.idxAny("Lon", "lon", "Lon [deg]")
        let iAlt = try cols.idxAny("Alt [m]", "alt_m")
        let iSpd = try cols.idxAny("Speed [km/h]", "speed_kmh", "SpeedKMh")
        let iCrs = try cols.idxAny("Course [deg]", "course_deg")
        let iFix = try cols.idxAny("Fix", "fix_q")
        let iSat = try cols.idxAny("NumSat", "nsat")
        let iHdp = try cols.idxAny("HDOP", "hdop")
        let iTmp = cols.idxOrNil("WaterTemp [C]")

        var out: [GpsRow] = []
        out.reserveCapacity(2048)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            // Skip corrupted rows — see parseSensorText comment.
            do {
                out.append(GpsRow(
                    ticks: try parseDouble(r, iT) / tickDiv,
                    utc: try fieldAt(r, iUtc),
                    lat: try parseDouble(r, iLat),
                    lon: try parseDouble(r, iLon),
                    altM: try parseDouble(r, iAlt),
                    speedKmhModule: try parseDouble(r, iSpd),
                    courseDeg: try parseDouble(r, iCrs),
                    fix: try parseInt(r, iFix),
                    numSat: try parseInt(r, iSat),
                    hdop: try parseDouble(r, iHdp),
                    waterTempC: iTmp.flatMap { i in
                        (try? fieldAt(r, i)).flatMap(Double.init)
                    } ?? .nan,
                ))
            } catch {
                continue
            }
        }
        return out
    }

    static func parseBatteryText(_ text: String) throws -> [BatteryRow] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .makeIterator()
        guard let header = lines.next(), !header.isEmpty else {
            throw CsvParseError(message: "battery csv: empty file")
        }
        let cols = try HeaderMap(headerLine: header)
        let iT: Int
        let tickDiv: Double
        if let i = cols.idxOrNil("ms") {
            iT = i; tickDiv = 10.0
        } else {
            iT = try cols.idxAny("Time [10ms]", "Time [mS]"); tickDiv = 1.0
        }
        let iV   = try cols.idxAny("Voltage [mV]", "v_mV")
        let iSoc = try cols.idxAny("SOC [0.1%]", "soc_x10")
        let iCur = try cols.idxAny("Current [100uA]", "i_x100uA")

        var out: [BatteryRow] = []
        out.reserveCapacity(2048)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            do {
                out.append(BatteryRow(
                    ticks: try parseDouble(r, iT) / tickDiv,
                    voltageMv: try parseInt(r, iV),
                    socTenthPct: try parseInt(r, iSoc),
                    currentHundredUa: try parseInt(r, iCur),
                ))
            } catch {
                continue
            }
        }
        return out
    }
}

private struct HeaderMap {
    let map: [String: Int]

    init(headerLine: String) throws {
        let fields = splitTrim(headerLine)
        var m: [String: Int] = [:]
        for (i, name) in fields.enumerated() {
            m[name] = i
        }
        self.map = m
    }

    func idxAny(_ names: String...) throws -> Int {
        for n in names {
            if let v = map[n] { return v }
        }
        throw CsvParseError(
            message: "missing column, expected one of \(names); got \(Array(map.keys))"
        )
    }

    /// Non-throwing peek for optional columns. Used by `parseSensorText`
    /// etc. to detect the post-22.4.2026 firmware's `ms` time column and
    /// switch unit conversion accordingly.
    func idxOrNil(_ names: String...) -> Int? {
        for n in names {
            if let v = map[n] { return v }
        }
        return nil
    }
}

private func splitTrim(_ line: String) -> [String] {
    line.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func fieldAt(_ row: [String], _ idx: Int) throws -> String {
    guard idx < row.count else {
        throw CsvParseError(message: "missing column at index \(idx)")
    }
    return row[idx]
}

private func parseDouble(_ row: [String], _ idx: Int) throws -> Double {
    let s = try fieldAt(row, idx)
    guard let v = Double(s) else {
        throw CsvParseError(message: "not a float: \"\(s)\"")
    }
    return v
}

private func parseInt(_ row: [String], _ idx: Int) throws -> Int {
    let s = try fieldAt(row, idx)
    guard let v = Int(s) else {
        throw CsvParseError(message: "not an int: \"\(s)\"")
    }
    return v
}
