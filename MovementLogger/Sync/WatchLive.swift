import Foundation
import Observation
import WatchConnectivity
import Network

/// Live board data streamed from the watch (strapped to the board) to the phone
/// over WatchConnectivity — the phone-side peer of `WatchSync.sendLiveSnapshot`.
///
/// Transport is `WCSession.sendMessage`: Bluetooth when the watch is near the
/// phone, WiFi when they're farther apart on the same network (never cellular —
/// that needs an internet relay). So this is live up-close for setup, or at
/// range on venue WiFi; otherwise the readout simply goes stale (`isFresh`).
///
/// The phone drives it: `requestStream(true)` while the live card is on screen
/// tells the watch to start streaming; `zero()`/`clearZero()` tare the
/// board-mounted watch's reference remotely.
@Observable
final class WatchLive {
    static let shared = WatchLive()

    var pitchDeg: Double = .nan
    var rollDeg: Double = .nan
    var yawDeg: Double = .nan
    var kmh: Double = .nan
    var waterTempC: Double? = nil
    var baroAltM: Double = .nan
    var pressureHPa: Double = .nan
    var battPct: Int? = nil
    /// Whether a recording session is running on the watch (speed/water/baro are
    /// only live during one).
    var running = false
    /// Whether the board-mounted watch's angle reference is tared.
    var zeroed = false
    /// When the last snapshot landed — the readout is "fresh" for ~2 s after.
    var lastUpdate: Date? = nil

    var isFresh: Bool { lastUpdate.map { Date().timeIntervalSince($0) < 2.5 } ?? false }

    /// Whether the watch is reachable right now (both apps active, in BT/WiFi
    /// range) — a request can only be delivered when true.
    var reachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
            && WCSession.default.isReachable
    }

    private init() {}

    /// Called from `WatchRideReceiver`'s message delegate (on main).
    func apply(_ d: [String: Double]) {
        pitchDeg = d["p"] ?? .nan
        rollDeg = d["r"] ?? .nan
        yawDeg = d["y"] ?? .nan
        kmh = d["kmh"] ?? .nan
        waterTempC = d["wt"]
        baroAltM = d["alt"] ?? .nan
        pressureHPa = d["hpa"] ?? .nan
        battPct = d["batt"].map { Int($0) }
        running = (d["run"] ?? 0) > 0.5
        zeroed = (d["z"] ?? 0) > 0.5
        lastUpdate = Date()
    }

    // MARK: - Phone → watch

    /// Ask the watch to start/stop streaming. Safe to call repeatedly (the card
    /// re-sends every couple of seconds so it catches the watch coming into
    /// range). Silently no-ops when the watch isn't reachable.
    func requestStream(_ on: Bool) { send(["wantLive": on]) }
    func zero() { send(["zeroAngles": true]) }
    func clearZero() { send(["clearZero": true]) }

    private func send(_ message: [String: Any]) {
        guard reachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Relay viewer (cellular / far-range path)

    /// The public race relay — the watch streams its board snapshot here when the
    /// phone isn't directly reachable (see `WatchLiveRelay`), and this phone
    /// subscribes as a viewer to receive it. Works over any internet, cellular
    /// included; WCSession stays the low-latency path up close.
    static let relayHost = "ml.ywesee.com"
    static let relayPort: UInt16 = 47777

    @ObservationIgnored private var viewer: NWConnection?
    @ObservationIgnored private let viewerQueue = DispatchQueue(label: "watch-live-viewer")
    @ObservationIgnored private var keepalive: Timer?

    /// Open the relay viewer while the live card is on screen: subscribe (re-sent
    /// every 8 s to stay registered and hold the NAT pinhole open) and feed every
    /// board snapshot into `apply`.
    func startViewer() {
        stopViewer()
        guard let port = NWEndpoint.Port(rawValue: Self.relayPort) else { return }
        let c = NWConnection(host: NWEndpoint.Host(Self.relayHost), port: port, using: .udp)
        c.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.subscribe() }
        }
        c.start(queue: viewerQueue)
        viewer = c
        receiveLoop()
        keepalive?.invalidate()
        keepalive = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.subscribe()
        }
    }

    func stopViewer() {
        keepalive?.invalidate(); keepalive = nil
        viewer?.cancel(); viewer = nil
    }

    private func subscribe() {
        let sub: [String: Any] = ["v": 1, "sub": true, "race": RaceUplink.shared.token]
        guard let d = try? JSONSerialization.data(withJSONObject: sub) else { return }
        viewer?.send(content: d, completion: .idempotent)
    }

    private func receiveLoop() {
        viewer?.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["typ"] as? String) == "board" {
                var nums: [String: Double] = [:]
                for k in ["p", "r", "y", "kmh", "wt", "alt", "hpa", "batt", "run", "z"] {
                    if let n = obj[k] as? NSNumber { nums[k] = n.doubleValue }
                }
                DispatchQueue.main.async { self.apply(nums) }
            }
            if err == nil { self.receiveLoop() }   // keep receiving
        }
    }
}
