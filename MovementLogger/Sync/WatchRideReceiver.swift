import Foundation
import WatchConnectivity
import Observation
import CoreLocation

/// Receives ride CSVs that the Apple Watch app sends over WatchConnectivity
/// and stores them under `Documents/WatchRides/`, so they show in the Rides
/// tab (and the Files app) and can be shared. Each watch session (Start→End)
/// is one CSV with the 1 Hz GPS track inside.
@Observable
final class WatchRideReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchRideReceiver()

    private(set) var rides: [URL] = []

    /// How the Rides list is ordered.
    ///
    /// `rideDate` is the default and the honest one: it reads the ride's own
    /// UTC start out of the `WatchGps_yyyyMMdd_HHmmss` filename, so it doesn't
    /// care when the file reached the phone. `synced` is the file's
    /// modification date — useful for spotting what a late re-sync just pulled
    /// in, but it puts a month-old ride at the top of the list the moment it
    /// finally transfers.
    enum RideSort: String, CaseIterable {
        case rideDate, synced
        var title: String {
            switch self {
            case .rideDate: "Ride date"
            case .synced:   "Last synced"
            }
        }
    }

    private static let sortKey = "ridesSortOrder"

    /// Property observers don't fire for assignments made inside `init`, so
    /// seeding this from UserDefaults there can't trigger a premature refresh.
    var sortOrder: RideSort = .rideDate {
        didSet {
            guard sortOrder != oldValue else { return }
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortKey)
            refresh()
        }
    }

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        sortOrder = UserDefaults.standard.string(forKey: Self.sortKey)
            .flatMap(RideSort.init(rawValue:)) ?? .rideDate
        refresh()
        // Rides already here predate the delivery bookkeeping — seed them so
        // the watch doesn't offer to re-send the whole back catalogue.
        noteReceived(rides.map { $0.lastPathComponent })
        pushRideManifest()
    }

    // MARK: - Delivery manifest

    private static let receivedKey = "watchRidesReceived"

    /// Every ride filename this phone has ever held. Deliberately NOT the
    /// current folder contents: deleting a ride from the Rides list must not
    /// make the watch push it straight back.
    private var receivedNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.receivedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.receivedKey) }
    }

    private func noteReceived(_ names: [String]) {
        var s = receivedNames
        let before = s.count
        s.formUnion(names)
        if s.count != before { receivedNames = s }
    }

    /// Tell the watch what this phone holds, so it can re-send anything that
    /// never arrived (`WatchSync.resendPending`).
    ///
    /// Merged into the current context on purpose: `updateApplicationContext`
    /// REPLACES the dictionary wholesale and `RaceUplink.pushRelayFlag` writes
    /// the same one, so a bare write here would silently wipe the race config.
    func pushRideManifest() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var ctx = WCSession.default.applicationContext
        ctx["haveRides"] = Array(receivedNames)
        try? WCSession.default.updateApplicationContext(ctx)
    }

    /// `Documents/WatchRides/` — created on demand.
    var ridesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("WatchRides", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rescan the folder, newest first by the current `sortOrder`.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ridesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let csvs = files.filter { $0.pathExtension.lowercased() == "csv" }
        switch sortOrder {
        case .rideDate:
            rides = csvs.sorted { rideStart($0) > rideStart($1) }
        case .synced:
            rides = csvs.sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
        }
    }

    /// The ride's own start, from the filename's UTC stamp. Falls back to the
    /// file date for anything not named `WatchGps_yyyyMMdd_HHmmss`.
    func rideStart(_ url: URL) -> Date {
        RideStatsLoader.stampDate(url.deletingPathExtension().lastPathComponent)
            ?? modDate(url) ?? .distantPast
    }

    func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Delete one ride CSV from `Documents/WatchRides/` (swipe-to-delete in the
    /// Rides list). Removes the file and refreshes the list. The ride still
    /// exists on the watch until the watch app rotates it, so this only clears
    /// the phone's copy. Also removes any exported map PNG for that ride.
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        // Best-effort cleanup of the matching exported map, if one was shared.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let png = docs.appendingPathComponent("RideMaps", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_map.png")
        try? FileManager.default.removeItem(at: png)
        refresh()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The provided fileURL is temporary — copy it out before returning.
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        let dest = ridesDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
        } catch {
            // Fall back to a read+write if a cross-volume copy is refused.
            if let data = try? Data(contentsOf: file.fileURL) { try? data.write(to: dest) }
        }
        DispatchQueue.main.async {
            self.noteReceived([name])
            self.refresh()
            // Confirm it to the watch so it stops offering this ride.
            self.pushRideManifest()
        }
    }

    /// Live race relay: the watch streams one fix per second while the
    /// phone has raised the `raceRelay` application-context flag (see
    /// `RaceUplink`). Forwarded to the UDP uplink, sourced "watch".
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let f = message["raceFix"] as? [String: Double],
              let lat = f["lat"], let lon = f["lon"] else { return }
        DispatchQueue.main.async {
            RaceUplink.shared.sendFix(lat: lat, lon: lon, kmh: f["kmh"], deg: f["deg"],
                                      acc: f["acc"], from: .watch)
        }
    }

    /// Watch → phone request/reply. One request so far: `windReq` — the wind
    /// at (lat, lon) at the instant `ts`, for the watch's live WIND metric
    /// (the watch app has no WeatherKit entitlement, so the phone answers from
    /// its `RideWeather` cache). An empty reply means "no wind available"
    /// (offline, quota, …) — the watch keeps showing "—" and retries later.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let req = message["windReq"] as? [String: Double],
              let lat = req["lat"], let lon = req["lon"], let ts = req["ts"] else {
            replyHandler([:])
            return
        }
        Task {
            let at = Date(timeIntervalSince1970: ts)
            let w = await RideWeather.wind(
                at: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                start: at, durationSec: 0, peakAt: at)
            replyHandler(w.map { ["kmh": $0.speedKmh, "gust": $0.gustKmh,
                                  "dir": $0.directionDeg] } ?? [:])
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        pushRideManifest()
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
