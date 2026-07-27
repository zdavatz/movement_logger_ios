import Foundation
import Observation
import WatchConnectivity

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
}
