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
}

/// Battery row. Units match the CSV — voltage in mV, SOC in 0.1 %, current in 100 µA.
struct BatteryRow {
    let ticks: Double
    let voltageMv: Int
    let socTenthPct: Int
    let currentHundredUa: Int
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

    static func parseSensorText(_ text: String) throws -> [SensorRow] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .makeIterator()
        guard let header = lines.next(), !header.isEmpty else {
            throw CsvParseError(message: "sensor csv: empty file")
        }
        let cols = try HeaderMap(headerLine: header)
        let iT  = try cols.idxAny("Time [10ms]", "Time [mS]")
        let iAx = try cols.idxAny("AccX [mg]")
        let iAy = try cols.idxAny("AccY [mg]")
        let iAz = try cols.idxAny("AccZ [mg]")
        let iGx = try cols.idxAny("GyroX [mdps]")
        let iGy = try cols.idxAny("GyroY [mdps]")
        let iGz = try cols.idxAny("GyroZ [mdps]")
        let iMx = try cols.idxAny("MagX [mgauss]")
        let iMy = try cols.idxAny("MagY [mgauss]")
        let iMz = try cols.idxAny("MagZ [mgauss]")
        let iP  = try cols.idxAny("P [mB]")
        let iTc = try cols.idxAny("T ['C]")

        var out: [SensorRow] = []
        out.reserveCapacity(8192)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            do {
                out.append(SensorRow(
                    ticks: try parseDouble(r, iT),
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
                throw CsvParseError(message: "sensor csv row \(lineNo): \(error.localizedDescription)")
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
        let iT   = try cols.idxAny("Time [10ms]", "Time [mS]")
        let iUtc = try cols.idxAny("UTC")
        let iLat = try cols.idxAny("Lat")
        let iLon = try cols.idxAny("Lon")
        let iAlt = try cols.idxAny("Alt [m]")
        let iSpd = try cols.idxAny("Speed [km/h]")
        let iCrs = try cols.idxAny("Course [deg]")
        let iFix = try cols.idxAny("Fix")
        let iSat = try cols.idxAny("NumSat")
        let iHdp = try cols.idxAny("HDOP")

        var out: [GpsRow] = []
        out.reserveCapacity(2048)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            do {
                out.append(GpsRow(
                    ticks: try parseDouble(r, iT),
                    utc: try fieldAt(r, iUtc),
                    lat: try parseDouble(r, iLat),
                    lon: try parseDouble(r, iLon),
                    altM: try parseDouble(r, iAlt),
                    speedKmhModule: try parseDouble(r, iSpd),
                    courseDeg: try parseDouble(r, iCrs),
                    fix: try parseInt(r, iFix),
                    numSat: try parseInt(r, iSat),
                    hdop: try parseDouble(r, iHdp),
                ))
            } catch {
                throw CsvParseError(message: "gps csv row \(lineNo): \(error.localizedDescription)")
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
        let iT   = try cols.idxAny("Time [10ms]", "Time [mS]")
        let iV   = try cols.idxAny("Voltage [mV]")
        let iSoc = try cols.idxAny("SOC [0.1%]")
        let iCur = try cols.idxAny("Current [100uA]")

        var out: [BatteryRow] = []
        out.reserveCapacity(2048)
        var lineNo = 1
        while let line = lines.next() {
            lineNo += 1
            if line.isEmpty || line.allSatisfy({ $0.isWhitespace }) { continue }
            let r = splitTrim(line)
            do {
                out.append(BatteryRow(
                    ticks: try parseDouble(r, iT),
                    voltageMv: try parseInt(r, iV),
                    socTenthPct: try parseInt(r, iSoc),
                    currentHundredUa: try parseInt(r, iCur),
                ))
            } catch {
                throw CsvParseError(message: "battery csv row \(lineNo): \(error.localizedDescription)")
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
