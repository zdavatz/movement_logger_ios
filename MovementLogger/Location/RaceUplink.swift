import Foundation
import Network
import Observation
import WatchConnectivity
import UIKit

/// Race mode — live position uplink to the desktop app's Race tab.
///
/// One small JSON datagram per fix, throttled to 2 Hz, fired at the
/// configured `host:port` (the desktop's Race tab shows its LAN ip:port
/// when it starts listening; over cellular a relay forwarding the same
/// datagrams works unchanged). Wire format shared with Android
/// `RaceUplink.kt` and parsed by desktop `race.rs`:
///
/// ```json
/// {"v":1,"rider":"Zeno","src":"phone","lat":37.3838,"lon":23.2472,
///  "kmh":4.2,"deg":181.0,"ts":1783948000123,"batt":85}
/// ```
///
/// Two GPS sources:
///  - **iPhone** — `GpsCore`'s CoreLocation fixes (~1 Hz), sent directly.
///  - **Apple Watch** — the watch streams its 1 Hz fixes over
///    WatchConnectivity while a watch recording runs (`WatchSync`
///    relays only when the phone raises the `raceRelay` application
///    context flag); `WatchRideReceiver` forwards them here. The phone
///    stays the uplink either way — it's the device with the network.
@Observable
final class RaceUplink: @unchecked Sendable {
    static let shared = RaceUplink()

    static let defaultPort = 47777
    /// ≤ ~2 Hz regardless of how fast fixes arrive.
    private static let minSendInterval: TimeInterval = 0.45

    enum Source: String, CaseIterable, Identifiable {
        case phone = "iPhone GPS"
        case watch = "Apple Watch"
        var id: String { rawValue }
        /// The wire `src` field.
        var wire: String { self == .phone ? "phone" : "watch" }
    }

    var enabled = false
    var rider: String {
        didSet { UserDefaults.standard.set(rider, forKey: "race.rider") }
    }
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "race.host") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "race.port") }
    }
    var source: Source {
        didSet {
            UserDefaults.standard.set(source == .watch, forKey: "race.watch")
            pushRelayFlag()
        }
    }
    private(set) var sent: UInt64 = 0
    private(set) var lastError: String? = nil

    private var connection: NWConnection? = nil
    private let queue = DispatchQueue(label: "race-uplink")
    private var lastSentAt: Date = .distantPast

    private init() {
        let d = UserDefaults.standard
        rider = d.string(forKey: "race.rider") ?? ""
        host = d.string(forKey: "race.host") ?? ""
        let p = d.integer(forKey: "race.port")
        port = p == 0 ? Self.defaultPort : p
        source = d.bool(forKey: "race.watch") ? .watch : .phone
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        sent = 0
        lastError = nil
        if on {
            openConnection()
            // The iPhone source needs CoreLocation running; starting it
            // here saves the "why is nothing sending" round trip.
            if source == .phone { GpsCore.shared.start() }
        } else {
            connection?.cancel()
            connection = nil
        }
        pushRelayFlag()
    }

    /// Tell the watch whether to stream live fixes (application context
    /// survives the watch app relaunching mid-race).
    private func pushRelayFlag() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(
            ["raceRelay": enabled && source == .watch])
    }

    private func openConnection() {
        connection?.cancel()
        guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            lastError = "invalid host/port"
            return
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        c.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                DispatchQueue.main.async { self?.lastError = e.localizedDescription }
            }
        }
        c.start(queue: queue)
        connection = c
    }

    /// Entry point for both sources; gated on the configured one so a
    /// running iPhone GPS can't inject fixes into a watch-sourced race.
    func sendFix(lat: Double, lon: Double, kmh: Double?, deg: Double?,
                 acc: Double? = nil, from src: Source) {
        guard enabled, src == source, !rider.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= Self.minSendInterval else { return }
        lastSentAt = now

        var o: [String: Any] = [
            "v": 1,
            "rider": rider,
            "src": src.wire,
            "lat": lat,
            "lon": lon,
            "ts": Int64(now.timeIntervalSince1970 * 1000),
        ]
        if let kmh, kmh.isFinite { o["kmh"] = kmh }
        if let deg, deg.isFinite { o["deg"] = deg }
        if let acc, acc.isFinite, acc > 0 { o["acc"] = acc }
        let batt = UIDevice.current.batteryLevel
        if batt >= 0 { o["batt"] = Int(batt * 100) }

        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        if connection == nil { openConnection() }
        connection?.send(content: data, completion: .contentProcessed { [weak self] err in
            DispatchQueue.main.async {
                if let err {
                    self?.lastError = err.localizedDescription
                } else {
                    self?.sent &+= 1
                    self?.lastError = nil
                }
            }
        })
    }
}
