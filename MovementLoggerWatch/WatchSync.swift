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

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
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
        let queued = pending; pending.removeAll()
        queued.forEach { transfer($0, on: session) }
    }
}
