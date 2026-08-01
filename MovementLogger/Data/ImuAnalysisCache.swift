import Foundation

/// Disk cache for `ImuAnalysisResult` so re-opening an analyzed recording is
/// instant instead of re-running the ~30 s pipeline. One binary plist per
/// recording under `Application Support/analysis-cache/`, keyed by the source
/// files' (size, mtime) so a regrown or re-recorded file re-analyzes. Survives
/// app restarts; any decode problem (schema bump, truncation) is a plain cache
/// miss. Android `ImuAnalysisCache.kt` is the peer.
enum ImuAnalysisCache {
    private static let version = 2
    private static let maxFiles = 32

    private struct Entry: Codable {
        let version: Int
        let imuSize: Int64
        let imuMtimeMs: Int64
        let gpsSize: Int64
        let result: ImuAnalysisResult
    }

    private static func dir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent("analysis-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func cacheURL(for imuURL: URL) -> URL {
        dir().appendingPathComponent(imuURL.lastPathComponent + ".plist")
    }

    private static func stat(_ url: URL?) -> (size: Int64, mtimeMs: Int64) {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return (0, 0) }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return (size, mtime)
    }

    static func load(imuURL: URL, gpsURL: URL?) -> ImuAnalysisResult? {
        guard let data = try? Data(contentsOf: cacheURL(for: imuURL)),
              let e = try? PropertyListDecoder().decode(Entry.self, from: data) else { return nil }
        let imu = stat(imuURL), gps = stat(gpsURL)
        guard e.version == version, e.imuSize == imu.size, e.imuMtimeMs == imu.mtimeMs,
              e.gpsSize == gps.size else { return nil }
        return e.result
    }

    static func store(_ r: ImuAnalysisResult, imuURL: URL, gpsURL: URL?) {
        let imu = stat(imuURL), gps = stat(gpsURL)
        let entry = Entry(version: version, imuSize: imu.size, imuMtimeMs: imu.mtimeMs,
                          gpsSize: gps.size, result: r)
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(entry) else { return }
        try? data.write(to: cacheURL(for: imuURL), options: .atomic)
        prune()
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir(), includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "plist" }), files.count > maxFiles else { return }
        let dated = files.map { f -> (URL, Date) in
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (f, d)
        }
        for (f, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? fm.removeItem(at: f)
        }
    }
}
