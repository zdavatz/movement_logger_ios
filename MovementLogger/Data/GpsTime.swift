import Foundation

/// GPS UTC strings are `hhmmss.ss` — wall-clock time-of-day with no date.
/// To turn them into absolute UTC millis we have to combine the time
/// with a date. The desktop project defaults to the file's mtime and
/// lets the user override with `--date YYYY-MM-DD`. On iOS we don't
/// have a clean mtime for an SD-card recording downloaded via BLE, so
/// we fall back to "today" by default and surface the date as a tunable.
enum GpsTime {

    /// Convert `hhmmss.ss` + a calendar date into absolute UTC millis.
    /// Returns nil when `utcStr` doesn't parse — the caller is responsible
    /// for surfacing the failure (most likely the GPS had no fix yet and
    /// emitted "0").
    static func toUtcMillis(_ utcStr: String, year: Int, month1to12: Int, day: Int) -> Int64? {
        guard let secs = parseHhmmssSs(utcStr) else { return nil }
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = year
        comps.month = month1to12
        comps.day = day
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps) else { return nil }
        return Int64(base.timeIntervalSince1970 * 1000.0) + Int64(secs * 1000.0)
    }

    /// "hhmmss.ss" → seconds-of-day; nil when the string doesn't fit.
    static func parseHhmmssSs(_ utcStr: String) -> Double? {
        let s = utcStr.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6 else { return nil }
        let hhStr = s.prefix(2)
        let mmStr = s.dropFirst(2).prefix(2)
        let ssStr = s.dropFirst(4)
        guard let hh = Int(hhStr), let mm = Int(mmStr), let ss = Double(ssStr) else {
            return nil
        }
        guard (0...23).contains(hh), (0...59).contains(mm), ss >= 0.0, ss < 60.0 else {
            return nil
        }
        return Double(hh) * 3600.0 + Double(mm) * 60.0 + ss
    }

    /// Today in UTC as (year, month1-12, day).
    static func todayUtc() -> (year: Int, month: Int, day: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        return (comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }
}
