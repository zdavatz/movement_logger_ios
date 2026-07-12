import Foundation
import Network
import WatchKit

/// Direct race uplink from the watch — the phone-free path. When the
/// paired iPhone is not reachable (left ashore, powered off), the watch
/// sends the same JSON UDP datagrams as the phone's `RaceUplink`
/// straight to the desktop over its own network. On venue WiFi that
/// means watch-only riders appear on the race map.
///
/// Configuration (rider / host / port) arrives from the phone via the
/// `raceRider`/`raceHost`/`racePort` application-context keys the
/// moment race mode is toggled on with the Apple Watch source — so the
/// rider needs the phone nearby exactly once, then it can stay ashore.
/// Persisted in UserDefaults so it survives watch app relaunches.
///
/// Note: a cellular watch cannot reach a private LAN address over LTE;
/// the direct path needs the watch on the venue WiFi. (The future
/// cloud relay lifts that restriction.)
final class WatchRaceUplink {
    static let shared = WatchRaceUplink()

    private(set) var rider: String
    private(set) var host: String
    private(set) var port: Int
    private(set) var sent: UInt64 = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "watch-race-uplink")

    private init() {
        let d = UserDefaults.standard
        rider = d.string(forKey: "race.rider") ?? ""
        host = d.string(forKey: "race.host") ?? ""
        let p = d.integer(forKey: "race.port")
        port = p == 0 ? 47777 : p
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }

    /// Fold in whatever the phone's application context carried.
    func updateConfig(rider: String?, host: String?, port: Int?) {
        let d = UserDefaults.standard
        if let rider, !rider.isEmpty {
            self.rider = rider
            d.set(rider, forKey: "race.rider")
        }
        if let host, !host.isEmpty, host != self.host {
            self.host = host
            d.set(host, forKey: "race.host")
            connection?.cancel()
            connection = nil
        }
        if let port, port != 0, port != self.port {
            self.port = port
            d.set(port, forKey: "race.port")
            connection?.cancel()
            connection = nil
        }
    }

    /// One fix (1 Hz from `WatchGpsLogger.writeRow`, via `WatchSync`).
    /// Fire-and-forget UDP, same wire format as the phone senders.
    func sendFix(lat: Double, lon: Double, kmh: Double, deg: Double, acc: Double) {
        guard !rider.isEmpty, !host.isEmpty else { return }
        var o: [String: Any] = [
            "v": 1,
            "rider": rider,
            "src": "watch",
            "lat": lat,
            "lon": lon,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if kmh.isFinite { o["kmh"] = kmh }
        if deg.isFinite { o["deg"] = deg }
        if acc.isFinite, acc > 0 { o["acc"] = acc }
        let batt = WKInterfaceDevice.current().batteryLevel
        if batt >= 0 { o["batt"] = Int(batt * 100) }
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }

        if connection == nil, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) {
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
            c.start(queue: queue)
            connection = c
        }
        connection?.send(content: data, completion: .contentProcessed { [weak self] err in
            if err == nil { self?.sent &+= 1 }
        })
    }
}
