import Foundation
import CoreLocation
import WatchConnectivity
import Observation

/// The wind that was blowing when the session's TOP speed was set — the WIND
/// metric next to TOP / WATER on the watch during a ride.
///
/// The watch app has no WeatherKit entitlement (adding one is a developer-
/// portal-only click that re-rolls the pinned CI watch profile), so the value
/// comes from the paired iPhone: a `windReq` message answered from the phone's
/// `RideWeather` (WeatherKit hourly history, cached there). WeatherKit is
/// hourly model data, so the fetched hour is cached here too and a new TOP
/// inside the same hour is stamped without another round-trip. With the phone
/// out of reach (rider on the water, phone ashore) the metric shows "—" and
/// the 1 Hz fix stream retries about once a minute; the ride's authoritative
/// wind still lands on the phone's Rides row after sync either way.
@Observable
final class WindAtTop {
    static let shared = WindAtTop()

    struct Wind {
        let kmh: Double
        let dirDeg: Double
        /// Compass point the wind blows FROM — same table as the phone's
        /// `RideWeather.Wind.compass` (duplicated: the watch target doesn't
        /// compile the phone's Data/ sources).
        var compass: String {
            let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            let i = Int((dirDeg / 22.5).rounded()) % 16
            return dirs[(i + 16) % 16]
        }
    }

    /// Wind at the moment the current session TOP was set; nil until known.
    private(set) var atTop: Wind?

    /// Last wind fetched from the phone, keyed by the hour it answers for.
    @ObservationIgnored private var cached: (wind: Wind, hour: Date)?
    /// A TOP moment still waiting for its wind (phone unreachable / reply
    /// pending) — retried from the fix stream.
    @ObservationIgnored private var pending: (ts: Date, coord: CLLocationCoordinate2D)?
    @ObservationIgnored private var lastReqAt: Date?

    func sessionStarted() {
        atTop = nil
        pending = nil
        lastReqAt = nil
        // `cached` survives on purpose: the hour's wind is still the hour's wind.
        // Touch WatchSync so WCSession is activating before the first windReq —
        // an unactivated session reads `isReachable == false` and the first
        // prefetch would silently wait out a whole retry period.
        _ = WatchSync.shared
    }

    /// Called for every valid fix (1 Hz): retries a pending TOP, and prefetches
    /// the current hour so the session's first TOP can be stamped instantly.
    func noteFix(_ loc: CLLocation) {
        if let p = pending {
            request(at: p.ts, coord: p.coord)
        } else if atTop == nil,
                  cached == nil || cached!.hour != Self.hourBucket(Date()) {
            request(at: Date(), coord: loc.coordinate)
        }
    }

    /// A new session TOP was just set at `ts`.
    func noteTop(_ loc: CLLocation, at ts: Date) {
        if let c = cached, c.hour == Self.hourBucket(ts) {
            atTop = c.wind
            pending = nil
        } else {
            pending = (ts, loc.coordinate)
            request(at: ts, coord: loc.coordinate)
        }
    }

    private func request(at ts: Date, coord: CLLocationCoordinate2D) {
        // Once a minute is plenty — the answer only changes on the hour.
        if let last = lastReqAt, Date().timeIntervalSince(last) < 60 { return }
        guard WCSession.default.isReachable else { return }
        lastReqAt = Date()
        WCSession.default.sendMessage(
            ["windReq": ["lat": coord.latitude, "lon": coord.longitude,
                         "ts": ts.timeIntervalSince1970]],
            replyHandler: { [weak self] reply in
                guard let kmh = reply["kmh"] as? Double,
                      let dir = reply["dir"] as? Double else { return }
                DispatchQueue.main.async {
                    self?.receive(Wind(kmh: kmh, dirDeg: dir), for: ts)
                }
            },
            errorHandler: nil)   // timeout/unreachable — the fix stream retries
    }

    private func receive(_ w: Wind, for ts: Date) {
        cached = (w, Self.hourBucket(ts))
        if let p = pending, Self.hourBucket(p.ts) == Self.hourBucket(ts) {
            atTop = w
            pending = nil
        }
    }

    private static func hourBucket(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}
