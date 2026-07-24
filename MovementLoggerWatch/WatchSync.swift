import Foundation
import Observation
import WatchConnectivity

/// Sends finished ride CSVs from the watch to the paired iPhone over
/// WatchConnectivity. `transferFile` is queued and delivered in the
/// background — the phone (or its extension) is woken to receive it even if
/// the iOS app isn't open — so a ride synced the moment you end a session.
///
/// **Rides are also re-sent until the phone confirms them.** A ride used to be
/// handed to `transferFile` exactly once, from `SessionController.stop()`, with
/// nothing watching whether it arrived. Two ways that loses a ride outright:
/// a session that never reached `stop()` (app killed, battery died, watch
/// rebooted mid-ride) never queued its CSV at all, and a queue entry lost
/// before completion was never retried. Since the watch never deletes a ride
/// CSV, both are recoverable: `delivered` tracks what the phone confirmed
/// (`didFinish` + the phone's `haveRides` manifest), and everything else on
/// disk is offered again by `resendPending()`.
@Observable
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// Rides queued before the session finished activating.
    @ObservationIgnored private var pending: [URL] = []

    /// The CSV currently being written by a running session. Excluded from
    /// re-sends — it's incomplete, and `stop()` sends it when the ride ends.
    /// Set by `WatchGpsLogger.openCsv` / cleared by `closeCsv`.
    @ObservationIgnored var activeRide: URL?

    /// Ride CSVs on this watch the phone has not confirmed holding. Drives the
    /// "Send N rides to iPhone" row on the watch face.
    private(set) var pendingCount = 0

    /// Race mode: stream live fixes to the phone while it has raised the
    /// `raceRelay` application-context flag (see the phone's
    /// `RaceUplink`). Off by default so ordinary rides don't spend
    /// battery on per-second messages nobody is listening to.
    @ObservationIgnored private(set) var relayLive = false

    private static let deliveredKey = "deliveredRides"
    private static let manifestKey = "deliveredRidesManifestSeen"

    /// Immediate re-queue attempts per ride, so one unsendable file can't spin
    /// forever. Reset on success; in-memory on purpose — a relaunch retries.
    private static let maxRetries = 3
    @ObservationIgnored private var retries: [String: Int] = [:]

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refreshPendingCount()
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

    /// Pull the settings the phone pushes: the race config (from `RaceUplink`)
    /// and the ride manifest (from `WatchRideReceiver`).
    private func applyPhoneContext(_ ctx: [String: Any]) {
        if let flag = ctx["raceRelay"] as? Bool {
            relayLive = flag
        }
        WatchRaceUplink.shared.updateConfig(
            rider: ctx["raceRider"] as? String,
            host: ctx["raceHost"] as? String,
            port: ctx["racePort"] as? Int,
            token: ctx["raceToken"] as? String)
        if let have = ctx["haveRides"] as? [String] {
            applyRideManifest(have)
        }
    }

    /// The phone's list of rides it already holds. Reconciles rides that were
    /// delivered before this bookkeeping existed, so an app update doesn't
    /// re-send the whole back catalogue.
    private func applyRideManifest(_ names: [String]) {
        var d = delivered
        d.formUnion(names)
        delivered = d
        UserDefaults.standard.set(true, forKey: Self.manifestKey)
        refreshPendingCount()
    }

    // MARK: - Delivery bookkeeping

    private var delivered: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.deliveredKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.deliveredKey) }
    }

    /// True once the phone has told us what it holds. Until then we don't know
    /// which rides are genuinely missing, so only an explicit tap re-sends —
    /// an automatic pass would blast the entire back catalogue after an update.
    private var hasManifest: Bool { UserDefaults.standard.bool(forKey: Self.manifestKey) }

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Ride CSVs on disk the phone hasn't confirmed, excluding the running
    /// session's file and anything already sitting in the transfer queue.
    func pendingRides() -> [URL] {
        let done = delivered
        let queued = Set(WCSession.default.outstandingFileTransfers.map {
            ($0.file.metadata?["name"] as? String) ?? $0.file.fileURL.lastPathComponent
        })
        let active = activeRide?.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("WatchGps_")
                      && $0.pathExtension.lowercased() == "csv" }
            .filter { $0.lastPathComponent != active }
            .filter { !done.contains($0.lastPathComponent) }
            .filter { !queued.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `pendingCount` drives SwiftUI and every WCSession delegate callback
    /// lands on a background queue, so the write has to hop to main.
    private func refreshPendingCount() {
        let n = pendingRides().count
        DispatchQueue.main.async {
            if n != self.pendingCount { self.pendingCount = n }
        }
    }

    /// Re-queue every ride the phone hasn't confirmed. Safe to call often:
    /// delivered and already-queued rides are skipped, and the phone stores by
    /// filename, so a duplicate send overwrites rather than duplicating.
    @discardableResult
    func resendPending() -> Int {
        guard WCSession.isSupported() else { return 0 }
        let s = WCSession.default
        guard s.activationState == .activated else { s.activate(); return 0 }
        let due = pendingRides()
        due.forEach { transfer($0, on: s) }
        refreshPendingCount()
        return due.count
    }

    // MARK: - Send

    /// Sync one ride CSV to the phone.
    func send(csv url: URL) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.activationState == .activated {
            transfer(url, on: s)
            refreshPendingCount()
        } else {
            pending.append(url)
            s.activate()
        }
    }

    private func transfer(_ url: URL, on session: WCSession) {
        session.transferFile(url, metadata: ["name": url.lastPathComponent, "kind": "ride-csv"])
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        // Pick up race settings + the ride manifest pushed while this app
        // wasn't running.
        applyPhoneContext(session.receivedApplicationContext)
        let queued = pending; pending.removeAll()
        queued.forEach { transfer($0, on: session) }
        if hasManifest { resendPending() } else { refreshPendingCount() }
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        applyPhoneContext(applicationContext)
        if hasManifest { resendPending() }
    }

    /// The phone's manifest, delivered as queued user-info rather than an
    /// application context. This is the path that does NOT need the user to
    /// open the watch app: `transferUserInfo` is queued FIFO and delivered in
    /// the background, launching this app if it isn't running — so a ride
    /// stranded by a dropped transfer is re-sent on the phone's next launch
    /// instead of waiting for someone to raise their wrist and tap.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        applyPhoneContext(userInfo)
        if hasManifest { resendPending() }
    }

    /// The phone came back in range — a good moment to drain anything the
    /// last attempt couldn't deliver.
    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable, hasManifest else { return }
        resendPending()
    }

    /// Confirmation that a ride actually landed on the phone. Only a
    /// successful transfer marks it delivered; a failed one stays pending and
    /// is retried by the next `resendPending()`.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                 error: Error?) {
        let name = (fileTransfer.file.metadata?["name"] as? String)
            ?? fileTransfer.file.fileURL.lastPathComponent
        if error == nil {
            var d = delivered; d.insert(name); delivered = d
            retries[name] = nil
        } else {
            // A failed transfer would otherwise sit untouched until the next
            // activation — i.e. until someone opens the watch app. Re-queue it
            // straight away, bounded so a permanently broken file can't spin.
            let n = (retries[name] ?? 0) + 1
            retries[name] = n
            if n <= Self.maxRetries, WCSession.default.activationState == .activated {
                transfer(fileTransfer.file.fileURL, on: WCSession.default)
            }
        }
        refreshPendingCount()
    }
}
