import SwiftUI

/// Rides synced from the Apple Watch — each is a Start→End session's 1 Hz GPS
/// CSV. Tap Share to send the CSV anywhere (AirDrop, Files, Mail, …).
struct RidesScreen: View {
    @State private var receiver = WatchRideReceiver.shared

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
                        HStack(spacing: 12) {
                            Image(systemName: "location.circle.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.subheadline).lineLimit(1).truncationMode(.middle)
                                Text(Self.subtitle(url, receiver: receiver))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up").imageScale(.large)
                            }
                        }
                        .padding(.vertical, 2)
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
