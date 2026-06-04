import SwiftUI
import UIKit
import CoreLocation

/// GPS tab — iPhone's built-in GNSS via `CoreLocation`. The Android peer
/// (`UsbGpsScreen.kt`) drives an external u-blox over USB; iOS doesn't
/// allow that for third-party apps without MFi, so this tab uses the
/// phone's own receiver instead. See `GpsCore.swift` for the trade-off
/// discussion.
struct GpsScreen: View {
    @Bindable var core: GpsCore
    /// 250 ms refresh tick — like LiveScreen — so the "X ms ago" /
    /// running Hz keeps updating between fix arrivals (typically ~1 Hz).
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Built-in iPhone GNSS — independent fix for cross-checking the box GPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    statusStrip
                    controlsRow
                    Divider()

                    if !core.isReading {
                        Text("Waiting — tap Start to begin reading the iPhone's GPS.")
                            .foregroundStyle(.secondary)
                    } else {
                        rateCard
                        fixCard
                        logCard
                    }
                }
                .padding(16)
            }
            .navigationTitle("GPS")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        HStack {
            Text(core.status)
                .font(.subheadline)
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        if core.isReading && core.fixAvailable { return .green }
        if core.isReading { return .orange }
        switch core.authStatus {
        case .denied, .restricted: return .red
        case .authorizedAlways, .authorizedWhenInUse: return .blue
        default: return .secondary
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsRow: some View {
        HStack(spacing: 8) {
            if !core.isReading {
                Button("Start") { core.start() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Stop") { core.stop() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Rate card

    @ViewBuilder
    private var rateCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("Measurement rate").fontWeight(.semibold)
                HStack {
                    Text(String(format: "%.2f Hz", core.hz))
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(core.sampleCount) fixes received")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("CoreLocation caps the public API at ~1 Hz — the Android external-u-blox build hits 5 Hz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Fix card

    @ViewBuilder
    private var fixCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let loc = core.latestLocation {
                    readoutRow("UTC", utcString(loc.timestamp), "", "")
                    readoutRow(
                        "Lat / Lon",
                        String(format: "%.6f°", loc.coordinate.latitude),
                        String(format: "%.6f°", loc.coordinate.longitude),
                        ""
                    )
                    readoutRow(
                        "Altitude",
                        String(format: "%.1f m", loc.altitude),
                        loc.verticalAccuracy >= 0
                            ? String(format: "± %.1f m", loc.verticalAccuracy)
                            : "",
                        ""
                    )
                    readoutRow(
                        "Speed / Course",
                        loc.speed >= 0 ? String(format: "%.2f km/h", loc.speed * 3.6) : "—",
                        loc.course >= 0 ? String(format: "%.1f°", loc.course) : "—",
                        ""
                    )
                    readoutRow(
                        "Accuracy",
                        loc.horizontalAccuracy >= 0
                            ? String(format: "± %.1f m", loc.horizontalAccuracy)
                            : "no fix",
                        "",
                        ""
                    )
                    // Latency: how long since this fix landed. Useful for
                    // distinguishing "fresh fix" from "stale, GPS lost".
                    let elapsed = now.timeIntervalSince(loc.timestamp)
                    Text(elapsed < 5
                         ? String(format: "fix %.1f s ago", elapsed)
                         : String(format: "no fresh fix for %.0f s — check sky view", elapsed))
                        .font(.caption)
                        .foregroundStyle(elapsed < 5 ? .green : .orange)
                } else {
                    Text("Waiting for first fix from CoreLocation…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Log card

    @ViewBuilder
    private var logCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("CSV log").fontWeight(.semibold)
                HStack(spacing: 8) {
                    if !core.isLogging {
                        Button("Start recording") { core.startLogging() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Stop recording") { core.stopLogging() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let url = currentLogURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            copyCsvToPasteboard(url)
                        } label: {
                            Label(copyButtonLabel, systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if core.isLogging {
                    Text("Recording → \(core.logPath ?? "?")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(core.loggedRows) rows written")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let p = core.logPath {
                    Text("Last log: \(p) (\(core.loggedRows) rows)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Schema matches the box's Gps*.csv — Replay tab will pick it up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// File URL of the active or most-recent CSV log, if any. Used to wire
    /// the Share + Copy buttons to whichever file the user just recorded
    /// (or is recording right now — Share/Copy work mid-recording too).
    private var currentLogURL: URL? {
        guard let p = core.logPath else { return nil }
        return URL(fileURLWithPath: p)
    }

    @State private var copyButtonLabel: String = "Copy"

    private func copyCsvToPasteboard(_ url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            UIPasteboard.general.string = text
            copyButtonLabel = "Copied"
            // Revert after a short delay so repeated taps are still visible.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copyButtonLabel = "Copy"
            }
        } catch {
            copyButtonLabel = "Copy failed"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copyButtonLabel = "Copy"
            }
        }
    }

    // MARK: - Helpers

    private func utcString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d) + " UTC"
    }

    @ViewBuilder
    private func readoutRow(_ label: String, _ a: String, _ b: String, _ c: String) -> some View {
        HStack {
            Text(label).fontWeight(.semibold)
            Spacer()
            Group {
                Text(a)
                Text(b)
                Text(c)
            }
            .font(.system(.subheadline, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
