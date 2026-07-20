import SwiftUI
import AVKit
import PhotosUI

/// Merge screen — pick MULTIPLE videos, optionally a Sens*/Gps* CSV pair
/// from the Sync tab, and export one film: per clip a 2.5 s black title
/// card (recording date + start time), the COMPLETE clip (never trimmed),
/// and a 3 s fade-out. With CSVs loaded every clip carries the Replay
/// panel stack; without them the merge is plain video.
struct MergeScreen: View {
    @State private var vm = MergeViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPlayer: Bool = false
    @State private var recordings: [URL] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick several clips — they are sorted by recording time, shown complete (never cut), each introduced by a date/time title card and closed with a fade to black.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 50,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label("Add videos", systemImage: "film.stack")
                    }
                    .buttonStyle(.borderedProminent)

                    if vm.importingTotal > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Loading videos… \(vm.importingDone)/\(vm.importingTotal)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(
                                value: Double(vm.importingDone),
                                total: Double(max(vm.importingTotal, 1))
                            )
                        }
                    } else if vm.loadingClips {
                        InlineSpinner(label: "reading video metadata…")
                    }

                    ClipList(vm: vm)

                    Divider()

                    SensorDataSection(vm: vm, recordings: $recordings)

                    if vm.parsingCsv {
                        InlineSpinner(label: "parsing CSV…")
                    }
                    if vm.computing {
                        InlineSpinner(label: "running fusion + baro + nose-angle…")
                    }

                    if let err = vm.error {
                        ErrorBanner(message: err, onDismiss: vm.clearError)
                    }

                    MergeRow(vm: vm, showingPlayer: $showingPlayer)
                }
                .padding(16)
            }
            .navigationTitle("Merge")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            // Clear the binding IMMEDIATELY (before the slow import below).
            // Video imports take seconds; while the old code waited for them
            // the binding still held the previous selection, so re-opening
            // the picker re-delivered those items ticked and the next
            // onChange appended them AGAIN — "more videos end up in the
            // list than I select". `addClips` dedups as the second belt.
            pickerItems = []
            Task {
                await MainActor.run { vm.beginImport(items.count) }
                var urls: [URL] = []
                // Import up to 4 videos concurrently — the photo-library
                // copies are I/O-bound, so parallelism cuts the wait
                // roughly linearly. Order is irrelevant (clips are sorted
                // by capture time later); each finished copy ticks the bar.
                let chunkSize = 4
                var idx = 0
                while idx < items.count {
                    let chunk = Array(items[idx..<min(idx + chunkSize, items.count)])
                    idx += chunk.count
                    await withTaskGroup(of: URL?.self) { group in
                        for item in chunk {
                            group.addTask {
                                (try? await item.loadTransferable(type: VideoFile.self))?.url
                            }
                        }
                        for await maybeUrl in group {
                            if let u = maybeUrl { urls.append(u) }
                            await MainActor.run { vm.importTick() }
                        }
                    }
                }
                await vm.addClips(urls)
                await MainActor.run { vm.endImport() }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if let path = vm.lastExportedPath {
                MergedVideoPlayer(url: URL(fileURLWithPath: path)) {
                    showingPlayer = false
                }
            }
        }
    }
}

// MARK: - Clip list

private struct ClipList: View {
    @Bindable var vm: MergeViewModel

    var body: some View {
        if vm.clips.isEmpty {
            Text("No clips yet — add at least one video.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clips (chronological)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Clear all") { vm.clearClips() }
                        .buttonStyle(.bordered)
                        .disabled(vm.exporting)
                }
                ForEach(Array(vm.clips.enumerated()), id: \.element.id) { idx, clip in
                    ClipRow(vm: vm, clip: clip, index: idx + 1, skipped: false)
                }
                Text(mergeSummary(vm.clips))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SkippedClips(vm: vm)
            }
        }
    }
}

/// One clip row. `skipped` rows are landscape picks held out of the merge:
/// red-tinted, numberless, and with a note saying why.
private struct ClipRow: View {
    @Bindable var vm: MergeViewModel
    let clip: MergeViewModel.Clip
    let index: Int
    let skipped: Bool

    var body: some View {
        HStack {
            if skipped {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("\(index).")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.url.lastPathComponent)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(skipped ? Color.red : Color.primary)
                HStack(spacing: 6) {
                    Text(formatClipStart(clip.startMs))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatClipDuration(clip.meta.durationMillis))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if skipped {
                        Text("landscape — not merged")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    if !clip.hasCreation {
                        Text("no capture date — using file date")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                if skipped { vm.removeSkipped(clip) } else { vm.removeClip(clip) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(vm.exporting)
        }
        .padding(8)
        .background(skipped ? Color.red.opacity(0.10)
                            : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The landscape picks that were left out, with the reason.
private struct SkippedClips: View {
    @Bindable var vm: MergeViewModel

    var body: some View {
        if !vm.skippedClips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not merged — landscape (\(vm.skippedClips.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text("The film is portrait. Mixing in a landscape clip forces a "
                    + "square canvas, which puts bars on every clip and makes the "
                    + "export much heavier — so these are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(vm.skippedClips) { clip in
                    ClipRow(vm: vm, clip: clip, index: 0, skipped: true)
                }
            }
            .padding(.top, 4)
        }
    }
}

private func mergeSummary(_ clips: [MergeViewModel.Clip]) -> String {
    let clipMs = clips.reduce(Int64(0)) { $0 + max($1.meta.durationMillis, 0) }
    // Per clip: 2.5 s title card + 3 s freeze fade-out; plus the 3 s
    // gradient intro and the 5 s logo outro.
    let totalMs = clipMs + Int64(clips.count) * (2500 + 3000) + 3000 + 5000
    return "\(clips.count) clip\(clips.count == 1 ? "" : "s") · merged length \(formatClipDuration(totalMs)) incl. intro, cards, fade-outs + outro"
}

// MARK: - Sensor data (optional)

private struct SensorDataSection: View {
    @Bindable var vm: MergeViewModel
    @Binding var recordings: [URL]
    /// The CSV file lists only appear once the user opts in — a plain
    /// video merge shows no session files at all.
    @State private var includeSensorData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeSensorData) {
                Text("Include sensor data")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(vm.exporting)
            .onChange(of: includeSensorData) { _, on in
                if on {
                    recordings = vm.listLocalRecordings()
                } else if vm.sensorFile != nil || vm.gpsFile != nil {
                    vm.clearCsvs()
                }
            }

            if includeSensorData {
                let sensorCandidates = recordings.filter { isSensCsvName($0.lastPathComponent) }
                let gpsCandidates = recordings.filter { isGpsCsvName($0.lastPathComponent) }

                HStack {
                    Text("Load a Sens*/Gps* CSV to composite the sensor panels under every clip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        recordings = vm.listLocalRecordings()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    CsvChip(label: "Sensor",
                            detail: vm.sensorFile?.lastPathComponent,
                            rows: vm.sensorRowCount)
                    CsvChip(label: "GPS",
                            detail: vm.gpsFile?.lastPathComponent,
                            rows: vm.gpsRowCount)
                    if vm.sensorFile != nil || vm.gpsFile != nil {
                        Button("Clear") { vm.clearCsvs() }
                            .buttonStyle(.bordered)
                            .disabled(vm.exporting)
                    }
                }

                if sensorCandidates.isEmpty && gpsCandidates.isEmpty {
                    Text("No CSVs in this app's storage — use the Sync tab to download some first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if !sensorCandidates.isEmpty {
                        Text("Sensor CSV").font(.caption.weight(.semibold))
                        CsvChooserList(files: sensorCandidates, selected: vm.sensorFile) { url in
                            Task { await vm.pickSensorCsv(url) }
                        }
                    }
                    if !gpsCandidates.isEmpty {
                        Text("GPS CSV").font(.caption.weight(.semibold))
                        CsvChooserList(files: gpsCandidates, selected: vm.gpsFile) { url in
                            Task { await vm.pickGpsCsv(url) }
                        }
                    }
                }
            }
        }
    }
}

private struct CsvChip: View {
    let label: String
    let detail: String?
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: detail != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(detail != nil ? Color.green : Color.secondary)
                Text(label).font(.caption.weight(.semibold))
            }
            Text(detail ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if rows > 0 {
                Text("\(rows) rows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CsvChooserList: View {
    let files: [URL]
    let selected: URL?
    let onPick: (URL) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(files, id: \.path) { f in
                let isSelected = f == selected
                HStack {
                    Text(f.lastPathComponent)
                        .font(.footnote)
                        .fontWeight(isSelected ? .bold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(isSelected ? "Reload" : "Load") { onPick(f) }
                        .buttonStyle(.bordered)
                }
                .padding(8)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.15)
                        : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
    }
}

// MARK: - Merge + result row

private struct MergeRow: View {
    @Bindable var vm: MergeViewModel
    @Binding var showingPlayer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    Task { await vm.mergeAndExport() }
                } label: {
                    Text(vm.exporting ? "Merging…" : "Merge videos")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    vm.exporting || vm.clips.isEmpty
                    || vm.loadingClips || vm.parsingCsv || vm.computing
                )
                if vm.exporting {
                    ProgressView(value: vm.exportProgress)
                        .frame(maxWidth: .infinity)
                }
            }
            if !vm.clips.isEmpty && !vm.exporting {
                Text(vm.hasPanelData
                     ? "Merging with sensor panels under every clip."
                     : "Merging plain videos (no session data loaded).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let path = vm.lastExportedPath {
                Text("saved → \(path)")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
                if vm.savedToPhotos {
                    Text("also added to Photos library")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
                HStack(spacing: 12) {
                    Button {
                        showingPlayer = true
                    } label: {
                        Label("Play merged video", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: URL(fileURLWithPath: path)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// Full-screen, native playback of the merged film (same pattern as the
/// Replay tab's exported-composite player).
private struct MergedVideoPlayer: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MergedPlayerContainer(url: url)
                .ignoresSafeArea()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding()
            }
        }
        .background(Color.black)
    }
}

private struct MergedPlayerContainer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

// MARK: - Helpers

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .foregroundStyle(Color(.systemRed))
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InlineSpinner: View {
    let label: String
    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(label)
        }
    }
}

private let _clipStartFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return f
}()

private func formatClipStart(_ epochMs: Int64) -> String {
    _clipStartFormatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0))
}

private func formatClipDuration(_ ms: Int64) -> String {
    let totalS = Int(max(ms, 0) / 1000)
    return String(format: "%d:%02d", totalS / 60, totalS % 60)
}

private func isSensCsvName(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    return n.hasPrefix("sens") && n.hasSuffix(".csv")
}

private func isGpsCsvName(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    return (n.hasPrefix("gps") || n.hasPrefix("iphonegps")) && n.hasSuffix(".csv")
}
