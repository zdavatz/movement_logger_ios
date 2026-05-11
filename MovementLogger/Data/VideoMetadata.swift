import Foundation
import AVFoundation

/// Metadata pulled from a video for time-alignment with sensor data.
///
/// `creationTimeMillis`: UTC milliseconds when recording started, parsed
/// from the container's `creation_time` (common QuickTime/MP4 metadata).
/// Nil when the video has no such tag (rare — most phone cameras and
/// GoPro embed it).
///
/// `durationMillis`: total length, 0 if unknown.
struct VideoMetadata: Equatable {
    let creationTimeMillis: Int64?
    let durationMillis: Int64
}

enum VideoMetadataReader {

    static func read(_ url: URL) async -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        do {
            async let durationLoad = asset.load(.duration)
            async let metaLoad = asset.load(.commonMetadata)
            let (duration, common) = try await (durationLoad, metaLoad)
            let durationMs = duration.isValid && !duration.isIndefinite
                ? Int64(duration.seconds * 1000.0)
                : 0
            var creationMs = await firstCreationDateMillis(in: common)
            if creationMs == nil {
                creationMs = await firstCreationDateMillisFromQuickTime(asset: asset)
            }
            return VideoMetadata(creationTimeMillis: creationMs, durationMillis: durationMs)
        } catch {
            return VideoMetadata(creationTimeMillis: nil, durationMillis: 0)
        }
    }

    private static func firstCreationDateMillis(in items: [AVMetadataItem]) async -> Int64? {
        for item in items where item.commonKey == .commonKeyCreationDate {
            // Try the convenience date first.
            if let date: Date = try? await item.load(.dateValue) {
                return Int64(date.timeIntervalSince1970 * 1000.0)
            }
            // Fall back to string parsing across the common date spellings.
            if let s: String = try? await item.load(.stringValue),
               let ms = parseIso8601Date(s) {
                return ms
            }
        }
        return nil
    }

    /// Some containers (notably MP4/MOV from action cameras) put the date
    /// in QuickTime metadata under `com.apple.quicktime.creationdate` even
    /// when commonMetadata is empty.
    private static func firstCreationDateMillisFromQuickTime(asset: AVAsset) async -> Int64? {
        let fmts: [AVMetadataFormat] = [.quickTimeMetadata, .iTunesMetadata, .quickTimeUserData, .isoUserData]
        for fmt in fmts {
            guard let items = try? await asset.loadMetadata(for: fmt) else { continue }
            for item in items {
                let key = (item.key as? String) ?? ""
                let id  = item.identifier?.rawValue ?? ""
                let wantedKeys = ["creationdate", "creation_time", "©day", "com.apple.quicktime.creationdate"]
                guard wantedKeys.contains(where: { id.contains($0) || key.contains($0) }) else { continue }
                if let date: Date = try? await item.load(.dateValue) {
                    return Int64(date.timeIntervalSince1970 * 1000.0)
                }
                if let s: String = try? await item.load(.stringValue),
                   let ms = parseIso8601Date(s) {
                    return ms
                }
            }
        }
        return nil
    }

    /// AVMetadataItem can return creation_time as ISO-8601 ("20251104T143012.000Z")
    /// or RFC-3339 ("2025-11-04T14:30:12.000Z") depending on container. Try a few.
    private static func parseIso8601Date(_ raw: String) -> Int64? {
        let patterns = [
            "yyyyMMdd'T'HHmmss.SSS'Z'",
            "yyyyMMdd'T'HHmmss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for pattern in patterns {
            formatter.dateFormat = pattern
            if let d = formatter.date(from: raw) {
                return Int64(d.timeIntervalSince1970 * 1000.0)
            }
        }
        // ISO8601DateFormatter as a last resort for less common spellings.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) {
            return Int64(d.timeIntervalSince1970 * 1000.0)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) {
            return Int64(d.timeIntervalSince1970 * 1000.0)
        }
        return nil
    }
}

/// Format a UTC millis timestamp for human display in the local timezone.
func formatLocalTime(_ utcMillis: Int64) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(utcMillis) / 1000.0))
}
