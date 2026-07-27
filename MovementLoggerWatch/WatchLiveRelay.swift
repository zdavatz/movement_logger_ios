import Foundation
import Network
import WatchKit

/// Streams the board snapshot (angles + speed + water + baro + battery) from the
/// watch to the public race relay (`ml.ywesee.com:47777`, the `race-relay`
/// service), so the phone's live view works **over cellular** — the watch out on
/// the water on LTE, the phone anywhere with internet. The relay forwards any
/// datagram carrying a `rider` field byte-for-byte to every viewer whose `race`
/// token matches, so this is just a rider datagram tagged `"typ":"board"`.
///
/// This is the far-range fallback: `WatchSync.sendLiveSnapshot` uses WCSession
/// (Bluetooth/WiFi, low latency) when the phone is directly reachable and only
/// falls back to this relay when it isn't. Rider name + race token are reused
/// from the existing race config (`race.rider`/`race.token`, pushed from the
/// phone) so no extra setup — a token only matters to isolate your stream from
/// other riders sharing the public relay.
final class WatchLiveRelay {
    static let shared = WatchLiveRelay()

    static let host = "ml.ywesee.com"
    static let port: UInt16 = 47777
    /// ~3 Hz cap — smooth enough for a readout, easy on cellular data/battery.
    private static let minInterval: TimeInterval = 0.33

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "watch-live-relay")
    private var lastAt = Date.distantPast

    private init() {}

    private var rider: String {
        let r = UserDefaults.standard.string(forKey: "race.rider") ?? ""
        return r.isEmpty ? "watch" : r
    }
    private var token: String { UserDefaults.standard.string(forKey: "race.token") ?? "" }

    func sendSnapshot(pitch: Double, roll: Double, yaw: Double, kmh: Double,
                      water: Double?, alt: Double, pressure: Double, batt: Int,
                      running: Bool, zeroed: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastAt) >= Self.minInterval else { return }
        lastAt = now
        var o: [String: Any] = [
            "v": 1, "rider": rider, "src": "watch", "typ": "board",
            "p": pitch, "r": roll, "y": yaw,
            "run": running ? 1 : 0, "z": zeroed ? 1 : 0,
            "ts": Int64(now.timeIntervalSince1970 * 1000),
        ]
        if kmh.isFinite { o["kmh"] = kmh }
        if let water, water.isFinite { o["wt"] = water }
        if alt.isFinite { o["alt"] = alt }
        if pressure.isFinite { o["hpa"] = pressure }
        if batt >= 0 { o["batt"] = batt }
        if !token.isEmpty { o["race"] = token }
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }

        if connection == nil, let p = NWEndpoint.Port(rawValue: Self.port) {
            let c = NWConnection(host: NWEndpoint.Host(Self.host), port: p, using: .udp)
            c.start(queue: queue)
            connection = c
        }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
