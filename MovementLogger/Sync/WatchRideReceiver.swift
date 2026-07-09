import Foundation
import WatchConnectivity
import Observation

/// Receives ride CSVs that the Apple Watch app sends over WatchConnectivity
/// and stores them under `Documents/WatchRides/`, so they show in the Rides
/// tab (and the Files app) and can be shared. Each watch session (Start→End)
/// is one CSV with the 1 Hz GPS track inside.
@Observable
final class WatchRideReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchRideReceiver()

    private(set) var rides: [URL] = []

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refresh()
    }

    /// `Documents/WatchRides/` — created on demand.
    var ridesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("WatchRides", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rescan the folder, newest first.
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ridesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        rides = files
            .filter { $0.pathExtension.lowercased() == "csv" }
            .sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
    }

    func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        DispatchQueue.main.async { self.refresh() }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
