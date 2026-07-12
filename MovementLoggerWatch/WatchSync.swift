import Foundation
import WatchConnectivity

/// Sends finished ride CSVs from the watch to the paired iPhone over
/// WatchConnectivity. `transferFile` is queued and delivered in the
/// background — the phone (or its extension) is woken to receive it even if
/// the iOS app isn't open — so a ride synced the moment you end a session.
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// Rides queued before the session finished activating.
    private var pending: [URL] = []

    /// Race mode: stream live fixes to the phone while it has raised the
    /// `raceRelay` application-context flag (see the phone's
    /// `RaceUplink`). Off by default so ordinary rides don't spend
    /// battery on per-second messages nobody is listening to.
    private(set) var relayLive = false

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// One live fix (1 Hz, from `WatchGpsLogger.writeRow`). With the
    /// phone reachable it relays over WCSession (the phone is the
    /// uplink); without it — phone ashore or off — the watch sends the
    /// datagram itself over its own WiFi (`WatchRaceUplink`), so
    /// watch-only riders stay on the race map.
    func relayLiveFix(lat: Double, lon: Double, kmh: Double, deg: Double, acc: Double) {
        guard relayLive else { return }
        if WCSession.default.isReachable {
            var fix: [String: Double] = ["lat": lat, "lon": lon]
            if kmh.isFinite { fix["kmh"] = kmh }
            if deg.isFinite { fix["deg"] = deg }
            if acc.isFinite, acc > 0 { fix["acc"] = acc }
            WCSession.default.sendMessage(["raceFix": fix], replyHandler: nil, errorHandler: nil)
        } else {
            WatchRaceUplink.shared.sendFix(lat: lat, lon: lon, kmh: kmh, deg: deg, acc: acc)
        }
    }

    /// Pull the race settings out of an application context (pushed by
    /// the phone's `RaceUplink` whenever race mode is toggled).
    private func applyRaceContext(_ ctx: [String: Any]) {
        if let flag = ctx["raceRelay"] as? Bool {
            relayLive = flag
        }
        WatchRaceUplink.shared.updateConfig(
            rider: ctx["raceRider"] as? String,
            host: ctx["raceHost"] as? String,
            port: ctx["racePort"] as? Int)
    }

    /// Sync one ride CSV to the phone.
    func send(csv url: URL) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.activationState == .activated {
            transfer(url, on: s)
        } else {
            pending.append(url)
            s.activate()
        }
    }

    private func transfer(_ url: URL, on session: WCSession) {
        session.transferFile(url, metadata: ["name": url.lastPathComponent, "kind": "ride-csv"])
    }

    // MARK: - WCSessionDelegate (watchOS only needs activation)

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        // Pick up race settings pushed while this app wasn't running.
        applyRaceContext(session.receivedApplicationContext)
        let queued = pending; pending.removeAll()
        queued.forEach { transfer($0, on: session) }
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        applyRaceContext(applicationContext)
    }
}
