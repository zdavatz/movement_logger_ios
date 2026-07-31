import Foundation
import WatchConnectivity
import Observation
import CoreLocation

/// Receives ride CSVs that the Apple Watch app sends over WatchConnectivity
/// and stores them under `Documents/WatchRides/`, so they show in the Rides
/// tab (and the Files app) and can be shared. Each watch session (Start→End)
/// is one CSV with the 1 Hz GPS track inside.
///
/// It also surfaces **iPhone-recorded** GPS tracks in the Rides tab, so a ride
/// logged with no Apple Watch connected still maps: the GPS-tab logger's
/// `iPhoneGps_*` and the phone-logger card's `GpsPhone_*` (see `refresh()`).
/// Those are the phone's own files in `Documents/`; only the watch rides feed
/// the WatchConnectivity delivery manifest.
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
        // the watch doesn't offer to re-send the whole back catalogue. Only
        // WATCH rides feed the manifest; iPhone-recorded rides (never sent by
        // the watch) must not pollute it.
        noteReceived(watchRideFiles().map { $0.lastPathComponent })
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

    /// Last manifest actually queued to the watch, so an unchanged one isn't
    /// re-queued. Session-scoped: a relaunch re-pushing once is harmless.
    private var lastPushedManifest: Set<String>?

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
        let have = Array(receivedNames)
        var ctx = WCSession.default.applicationContext
        ctx["haveRides"] = have
        try? WCSession.default.updateApplicationContext(ctx)
        // Also as queued user-info. An application context is only observed
        // when the watch app next runs, so on its own it makes recovery wait
        // for the user to open the watch app. `transferUserInfo` is delivered
        // in the background and launches the watch app if needed, so a ride
        // stranded by a dropped transfer comes back on the phone's next
        // launch instead of on a wrist-raise.
        //
        // Only on an actual change: this runs once per received file, and the
        // user-info queue is FIFO and persistent — re-sending an unchanged
        // manifest for each file of an 8-file batch would just be backlog.
        let set = receivedNames
        if set != lastPushedManifest {
            lastPushedManifest = set
            WCSession.default.transferUserInfo(["haveRides": have])
        }
    }

    /// `Documents/WatchRides/` — created on demand.
    var ridesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("WatchRides", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rescan both sources — watch rides in `WatchRides/` and iPhone-recorded
    /// tracks in `Documents/` — merged and ordered newest-first by the current
    /// `sortOrder`. All downstream code (row stats, map, delete) keys off the
    /// URL, so a mixed list needs no other change.
    func refresh() {
        let csvs = watchRideFiles() + phoneRideFiles()
        switch sortOrder {
        case .rideDate:
            rides = csvs.sorted { rideStart($0) > rideStart($1) }
        case .synced:
            rides = csvs.sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
        }
    }

    /// Watch rides mirrored under `Documents/WatchRides/`. `WatchImu_*` are the
    /// paired raw-motion streams, not rides — stored and manifest-tracked (so
    /// the watch stops re-sending them) but never listed.
    private func watchRideFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ridesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "csv"
            && !$0.lastPathComponent.hasPrefix("WatchImu_") }
    }

    /// iPhone-recorded GPS tracks in `Documents/`: the GPS-tab logger's
    /// `iPhoneGps_*` and the phone-logger card's `GpsPhone_*`. Both carry the
    /// same GPS schema (`Lat [deg]`/`Lon [deg]`/`SpeedKMh`, HDOP = honest
    /// accuracy proxy) the map already reads, so a ride recorded with no watch
    /// connected maps here — falling back to the speed gradient since there's
    /// no submersion column. Box downloads (`Gps001.csv`) and the IMU
    /// `SensPhone_*` sibling are deliberately excluded — they belong to
    /// Sync/Replay/Analyze, not the ride list.
    private func phoneRideFiles() -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            $0.pathExtension.lowercased() == "csv"
            && ($0.lastPathComponent.hasPrefix("iPhoneGps_")
                || $0.lastPathComponent.hasPrefix("GpsPhone_"))
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

    /// Delete one ride CSV (swipe-to-delete in the Rides list). The URL carries
    /// its own directory, so this removes a watch ride from `WatchRides/` or an
    /// iPhone-recorded track from `Documents/` alike, then refreshes the list.
    /// A watch ride still exists on the watch until the watch app rotates it, so
    /// for those this only clears the phone's copy; an iPhone recording has no
    /// other copy. Also removes any exported map PNG for that ride.
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
        if let f = message["raceFix"] as? [String: Double],
           let lat = f["lat"], let lon = f["lon"] {
            DispatchQueue.main.async {
                RaceUplink.shared.sendFix(lat: lat, lon: lon, kmh: f["kmh"], deg: f["deg"],
                                          acc: f["acc"], from: .watch)
            }
        }
        // Live board snapshot for the phone's watch-live card.
        if let live = message["live"] as? [String: Double] {
            DispatchQueue.main.async { WatchLive.shared.apply(live) }
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
