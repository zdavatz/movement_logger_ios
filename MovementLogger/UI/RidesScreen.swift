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
                            HStack(spacing: 12) {
                                Image(systemName: "map.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline).lineLimit(1).truncationMode(.middle)
                                    Text(Self.subtitle(url, receiver: receiver))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Share the raw CSV straight from the row; the
                                // map PNG is shared from inside RideMapView.
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
                        }
                        .buttonStyle(.plain)
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

    private static func subtitle(_ url: URL, receiver: WatchRideReceiver) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short
        let when = receiver.modDate(url).map { df.string(from: $0) } ?? "—"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let kb = Double(size) / 1024
        return String(format: "%@ · %.0f KB", when, kb)
    }
}
