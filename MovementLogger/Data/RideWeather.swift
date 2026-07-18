import Foundation
import CoreLocation
import WeatherKit

/// The wind that was blowing during a ride, from Apple's WeatherKit.
///
/// **Historical, not current.** A ride is replayed long after it happened, so
/// this asks for the *hourly history* covering the ride's window rather than
/// `currentWeather` (which would report the wind at render time — a different
/// day, usually a different wind). WeatherKit serves hourly history back to
/// **2022-08-01**, which covers every ride this app can hold.
///
/// **This is model output, not an anemometer.** WeatherKit returns a value for
/// a grid cell, hourly. At Ermioni the bay is small with land close by, so the
/// wind on the water can differ noticeably from the cell average — treat it as
/// "the conditions that day", not "what the rider felt". That is also why only
/// one representative value is surfaced per ride instead of a wind track: the
/// underlying data has no more resolution than that.
///
/// **Attribution is mandatory.** Apple's terms require the " Weather"
/// trademark and a legal link wherever the data is displayed — see
/// `RideWeather.attributionText` / `legalURL`, rendered in the PNG footer and
/// pinned under the Rides list (`RidesScreen.weatherAttribution`).
enum RideWeather {

    struct Wind: Equatable {
        let speedKmh: Double
        let gustKmh: Double
        let directionDeg: Double
        /// Compass point the wind blows FROM ("NNE"), the convention every
        /// weather source uses.
        var compass: String {
            let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            let i = Int((directionDeg / 22.5).rounded()) % 16
            return dirs[(i + 16) % 16]
        }
        /// "20 km/h NNE" — what the footer and the ride row show.
        var short: String { String(format: "%.0f km/h %@", speedKmh, compass) }
    }

    // U+F8FF is the Apple-logo glyph — " Weather" is the exact trademark form
    // App Review asked for. It rasterises fine into the shared PNG (drawn with
    // the system font on-device), so non-Apple viewers still see the mark.
    static let attributionText = "Weather data from \u{F8FF} Weather"
    static let legalURL = "weatherkit.apple.com/legal-attribution.html"

    /// Cache keyed by ride identity so a re-render (or scrolling the list past
    /// the same row) doesn't spend another WeatherKit call. The free tier is
    /// 500k calls/month and one ride needs one call, so this is politeness
    /// rather than necessity — but a render loop without it would not be.
    private static let cache = Cache()

    private actor Cache {
        private var store: [String: Wind?] = [:]
        func get(_ k: String) -> Wind?? { store[k] }
        func set(_ k: String, _ v: Wind?) { store[k] = v }
    }

    /// Representative wind for a ride, or nil when it can't be had (no network,
    /// no start time, WeatherKit unavailable/unauthorized, or the ride predates
    /// WeatherKit's 2022-08-01 history horizon).
    ///
    /// With `peakAt` set, the value is the single hour nearest that instant —
    /// the wind at the time of the ride's TOP speed, which is the moment the
    /// rider actually cares about. Without it, the median over the ride's
    /// hours (the pre-18.7.2026 behaviour, kept as the fallback for rides
    /// whose top-speed moment can't be pinned down).
    ///
    /// Returning nil is a normal outcome, not an error: the caller simply omits
    /// wind from the stats line. A ride map must still render on a plane.
    static func wind(at coord: CLLocationCoordinate2D,
                     start: Date?, durationSec: Double,
                     peakAt: Date? = nil) async -> Wind? {
        guard let start else { return nil }
        let key = String(format: "%.3f,%.3f,%.0f,%.0f", coord.latitude, coord.longitude,
                         start.timeIntervalSince1970,
                         peakAt?.timeIntervalSince1970 ?? -1)
        if let hit = await cache.get(key) { return hit }
        let value = await fetch(coord: coord, start: start, durationSec: durationSec,
                                peakAt: peakAt)
        await cache.set(key, value)
        return value
    }

    private static func fetch(coord: CLLocationCoordinate2D,
                              start: Date, durationSec: Double,
                              peakAt: Date?) async -> Wind? {
        // Pad the window: WeatherKit is hourly, so a short ride can fall
        // entirely between two stamps and return an empty set.
        let from = start.addingTimeInterval(-1800)
        let to = start.addingTimeInterval(max(durationSec, 0) + 1800)
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let hourly = try await WeatherService.shared.weather(
                for: loc, including: .hourly(startDate: from, endDate: to))
            // Keep only the hours the ride actually overlaps, then take the
            // median — a ride spanning a gust hour shouldn't report the gust as
            // its wind. Same reasoning as the water temp's median.
            let inRide = hourly.filter {
                $0.date >= start.addingTimeInterval(-3600)
                    && $0.date <= start.addingTimeInterval(durationSec + 3600)
            }
            let hours = inRide.isEmpty ? Array(hourly) : inRide
            guard !hours.isEmpty else { return nil }
            // Wind at the top-speed moment: the hour whose middle is nearest
            // that instant (hourly stamps mark the hour's START, hence +30 min).
            if let peakAt {
                let h = hours.min(by: {
                    abs($0.date.addingTimeInterval(1800).timeIntervalSince(peakAt))
                        < abs($1.date.addingTimeInterval(1800).timeIntervalSince(peakAt))
                })!
                return Wind(speedKmh: h.wind.speed.converted(to: .kilometersPerHour).value,
                            gustKmh: h.wind.gust?.converted(to: .kilometersPerHour).value ?? 0,
                            directionDeg: h.wind.direction.converted(to: .degrees).value)
            }
            let speeds = hours.map { $0.wind.speed.converted(to: .kilometersPerHour).value }.sorted()
            let gusts = hours.compactMap { $0.wind.gust?.converted(to: .kilometersPerHour).value }.sorted()
            let dirs = hours.map { $0.wind.direction.converted(to: .degrees).value }
            return Wind(speedKmh: speeds[speeds.count / 2],
                        gustKmh: gusts.isEmpty ? 0 : gusts[gusts.count / 2],
                        directionDeg: meanAngleDeg(dirs))
        } catch {
            // Offline, unauthorized, outside the history horizon, quota — all
            // land here and all mean the same thing to the caller: no wind.
            return nil
        }
    }

    /// Circular mean — averaging 350° and 10° arithmetically gives 180°, the
    /// exact opposite of the true northerly.
    private static func meanAngleDeg(_ degs: [Double]) -> Double {
        guard !degs.isEmpty else { return 0 }
        var x = 0.0, y = 0.0
        for d in degs {
            let r = d * .pi / 180
            x += cos(r); y += sin(r)
        }
        let a = atan2(y / Double(degs.count), x / Double(degs.count)) * 180 / .pi
        return a < 0 ? a + 360 : a
    }
}
