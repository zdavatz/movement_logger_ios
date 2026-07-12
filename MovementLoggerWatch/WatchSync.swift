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

    /// One live fix (1 Hz, from `WatchGpsLogger.writeRow`). `sendMessage`
    /// is fire-and-forget; it needs the phone reachable, which during a
    /// race it is — the phone in the rider's pouch is the uplink.
    func relayLiveFix(lat: Double, lon: Double, kmh: Double, deg: Double, acc: Double) {
        guard relayLive, WCSession.default.isReachable else { return }
        var fix: [String: Double] = ["lat": lat, "lon": lon]
        if kmh.isFinite { fix["kmh"] = kmh }
        if deg.isFinite { fix["deg"] = deg }
        if acc.isFinite, acc > 0 { fix["acc"] = acc }
        WCSession.default.sendMessage(["raceFix": fix], replyHandler: nil, errorHandler: nil)
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
        // Pick up a relay flag raised while this app wasn't running.
        if let flag = session.receivedApplicationContext["raceRelay"] as? Bool {
            relayLive = flag
        }
        let queued = pending; pending.removeAll()
        queued.forEach { transfer($0, on: session) }
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        if let flag = applicationContext["raceRelay"] as? Bool {
            relayLive = flag
        }
    }
}
