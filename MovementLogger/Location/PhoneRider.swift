import Foundation
import Observation
import Network
import UIKit

/// Turns the phone itself into a rider on the race map — carry the phone instead
/// of a watch. When `tracking` is on, each `GpsCore` fix is streamed to the same
/// (user-configurable) relay the race map reads from (`WatchLive.relayHost/
/// relayPort` + `RaceUplink.token`), so this phone shows up as a marker on its
/// own map and every other viewer's.
///
/// Position only — a carried phone can't sense board attitude. (A phone strapped
/// to the board could add its own CoreMotion angles later; the wire format
/// already supports it via `typ:"board"`.)
@Observable
final class PhoneRider {
    static let shared = PhoneRider()

    /// Rider name shown on the map — defaults to the device's own name. (On
    /// iOS 16+ `UIDevice.name` may come back as a generic "iPhone" without the
    /// user-assigned-device-name entitlement; the field is editable so it can be
    /// set to anything.)
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "phoneRider.name") }
    }
    var tracking = false {
        didSet {
            guard tracking != oldValue else { return }
            UserDefaults.standard.set(tracking, forKey: "phoneRider.on")
            apply()
        }
    }

    @ObservationIgnored private var conn: NWConnection?
    @ObservationIgnored private let q = DispatchQueue(label: "phone-rider")
    @ObservationIgnored private var lastAt = Date.distantPast
    private static let minInterval: TimeInterval = 0.18   // ~5 Hz

    private init() {
        name = UserDefaults.standard.string(forKey: "phoneRider.name") ?? UIDevice.current.name
        UIDevice.current.isBatteryMonitoringEnabled = true
        tracking = UserDefaults.standard.bool(forKey: "phoneRider.on")
        if tracking { apply() }
    }

    private func apply() {
        if tracking {
            GpsCore.shared.start()   // ensure phone GPS is running
        } else {
            q.async { self.conn?.cancel(); self.conn = nil }
        }
    }

    /// Called from `GpsCore.didUpdateLocations`. No-op unless tracking.
    func sendFix(lat: Double, lon: Double, kmh: Double?, deg: Double?, acc: Double?) {
        guard tracking, !name.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAt) >= Self.minInterval else { return }
        lastAt = now

        var o: [String: Any] = [
            "v": 1, "rider": name, "src": "phone",
            "lat": lat, "lon": lon,
            "ts": Int64(now.timeIntervalSince1970 * 1000),
        ]
        if let kmh, kmh.isFinite { o["kmh"] = kmh }
        if let deg, deg.isFinite { o["deg"] = deg }
        if let acc, acc.isFinite, acc > 0 { o["acc"] = acc }
        let token = RaceUplink.shared.token
        if !token.isEmpty { o["race"] = token }
        let batt = UIDevice.current.batteryLevel
        if batt >= 0 { o["batt"] = Int((batt * 100).rounded()) }
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }

        let host = WatchLive.shared.relayHost
        let portN = WatchLive.shared.relayPort
        guard !host.isEmpty, portN > 0, let port = NWEndpoint.Port(rawValue: UInt16(clamping: portN)) else { return }
        if conn == nil {
            let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
            c.start(queue: q)
            conn = c
        }
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }
}
