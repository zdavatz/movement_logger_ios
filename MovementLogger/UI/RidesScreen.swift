import SwiftUI

/// Rides synced from the Apple Watch — each is a Start→End session's 1 Hz GPS
/// CSV. Tap Share to send the CSV anywhere (AirDrop, Files, Mail, …).
/// Identifiable wrapper so a tapped ride URL can drive `.fullScreenCover(item:)`.
private struct RideSelection: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct RidesScreen: View {
    @State private var receiver = WatchRideReceiver.shared
    @State private var selected: RideSelection?

    var body: some View {
        NavigationStack {
            Group {
                if receiver.rides.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "applewatch",
                        description: Text("End a session on the MovementLogger watch app to sync its GPS ride here."))
                } else {
                    List(receiver.rides, id: \.self) { url in
                        // A plain Button (not a NavigationLink): the map is shown
                        // as a full-screen cover, so it is never pushed into the
                        // "More" tab's navigation controller — that nesting is
                        // what added a second, redundant back button.
                        Button {
                            selected = RideSelection(url: url)
                        } label: {
                            RideRowLabel(url: url, receiver: receiver)
                        }
                        .buttonStyle(.plain)
                        // Swipe right-to-left to delete this ride. `allowsFullSwipe`
                        // is off so a stray full swipe can't wipe a ride — the red
                        // Delete button must be tapped (ride data is only on the
                        // phone once the watch rotates its copy).
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                if selected?.url == url { selected = nil }
                                receiver.delete(url)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rides")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { receiver.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .fullScreenCover(item: $selected) { sel in
            RideMapView(url: sel.url)
        }
        .onAppear { receiver.refresh() }
    }

}

/// Per-ride stats for the list row, parsed once per (path, size) and cached.
struct RideStats {
    let start: Date?          // from the filename's UTC stamp
    let end: Date?            // start + tick span
    let durationSec: Double
    let topSpeedKmh: Double   // outlier-hardened (RideMapRenderer.robustTopSpeed)
    let waterTempC: Double?   // median of the watch's submersion-sensor samples
}

actor RideStatsLoader {
    static let shared = RideStatsLoader()
    private var cache: [String: RideStats] = [:]

    func stats(for url: URL) -> RideStats? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let key = url.path + ":\(size)"
        if let hit = cache[key] { return hit }
        guard let rows = try? CsvParsers.parseGpsFile(url), !rows.isEmpty else { return nil }
        let start = Self.stampDate(url.deletingPathExtension().lastPathComponent)
        let durationSec = max(0, (rows.last!.ticks - rows.first!.ticks) * 0.01)
        let temps = rows.map(\.waterTempC).filter { $0.isFinite }.sorted()
        let stats = RideStats(
            start: start,
            end: start.map { $0.addingTimeInterval(durationSec) },
            durationSec: durationSec,
            topSpeedKmh: RideMapRenderer.robustTopSpeed(rows: rows),
            waterTempC: temps.isEmpty ? nil : temps[temps.count / 2])
        cache[key] = stats
        return stats
    }

    /// `WatchGps_yyyyMMdd_HHmmss` — the stamp is UTC (see WatchGpsLogger).
    private static func stampDate(_ name: String) -> Date? {
        guard let m = name.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: String(name[m]))
    }
}

/// Row label: filename, start–end + duration, top speed + water temperature.
/// Stats parse asynchronously; the mtime + size subtitle shows until ready.
private struct RideRowLabel: View {
    let url: URL
    let receiver: WatchRideReceiver
    @State private var stats: RideStats?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text(line1)
                    .font(.caption).foregroundStyle(.secondary)
                if let line2 {
                    Text(line2)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Share the raw CSV straight from the row; the map PNG is
            // shared from inside RideMapView.
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").imageScale(.large)
            }
            .buttonStyle(.borderless)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .task(id: url) { stats = await RideStatsLoader.shared.stats(for: url) }
    }

    private var line1: String {
        guard let s = stats else {
            let df = DateFormatter()
            df.dateStyle = .medium; df.timeStyle = .short
            let when = receiver.modDate(url).map { df.string(from: $0) } ?? "—"
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return String(format: "%@ · %.0f KB", when, Double(size) / 1024)
        }
        let day = DateFormatter()
        day.dateStyle = .medium; day.timeStyle = .none
        let tf = DateFormatter()
        tf.dateStyle = .none; tf.timeStyle = .short
        let startStr = s.start.map { "\(day.string(from: $0)) \(tf.string(from: $0))" } ?? "—"
        let endStr = s.end.map { tf.string(from: $0) } ?? "—"
        let mins = Int((s.durationSec / 60).rounded())
        return "\(startStr) – \(endStr) · \(mins) min"
    }

    private var line2: String? {
        guard let s = stats else { return nil }
        var parts = [String(format: "Top %.1f km/h", s.topSpeedKmh)]
        if let t = s.waterTempC {
            parts.append(String(format: "Water %.1f °C", t))
        }
        return parts.joined(separator: " · ")
    }
}
