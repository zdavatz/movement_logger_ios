import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

/// Replay screen — pick a video and one or two CSV files saved by the
/// Sync tab, then watch them play back time-synced with overlaid panels
/// (speed, pitch / Nasenwinkel, height above water, GPS track).
struct ReplayScreen: View {
    @State private var vm = ReplayViewModel()
    @State private var player = AVPlayer()
    @State private var playheadMs: Int64 = 0
    @State private var pickerItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VideoSurface(
                        player: player,
                        hasVideo: vm.videoUrl != nil,
                        aspect: vm.videoMeta?.displayedSize
                    )
                    PhotosPicker(
                        selection: $pickerItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Text(vm.videoUrl == nil ? "Pick video" : "Replace video")
                    }
                    .buttonStyle(.borderedProminent)

                    Divider()

                    RecordingPicker(vm: vm) { url in
                        Task { await loadVideoFromUrl(url) }
                    }

                    if vm.loading {
                        InlineSpinner(label: "loading…")
                    }

                    if let err = vm.error {
                        ErrorBanner(message: err, onDismiss: vm.clearError)
                    }

                    AlignmentSummary(vm: vm)

                    ExportRow(vm: vm)

                    if !vm.speedSmoothedKmh.isEmpty {
                        SpeedPanel(
                            smoothed: vm.speedSmoothedKmh,
                            gpsAbsTimesMs: vm.gpsAbsTimesMs,
                            videoCreationMs: vm.videoMeta?.creationTimeMillis,
                            playheadMs: playheadMs
                        )
                    }
                    if vm.computing {
                        InlineSpinner(label: "running fusion + baro + nose-angle…")
                    }
                    if !vm.pitchDeg.isEmpty {
                        PitchPanel(
                            pitchDeg: vm.pitchDeg,
                            sensorAbsTimesMs: vm.sensorAbsTimesMs,
                            videoCreationMs: vm.videoMeta?.creationTimeMillis,
                            playheadMs: playheadMs
                        )
                    }
                    if !vm.fusedHeightM.isEmpty {
                        HeightPanel(
                            baroM: vm.baroHeightM,
                            fusedM: vm.fusedHeightM,
                            sensorAbsTimesMs: vm.sensorAbsTimesMs,
                            videoCreationMs: vm.videoMeta?.creationTimeMillis,
                            playheadMs: playheadMs
                        )
                    }
                    if vm.gpsRows.count > 1 {
                        GpsTrackPanel(
                            gpsRows: vm.gpsRows,
                            gpsAbsTimesMs: vm.gpsAbsTimesMs,
                            videoCreationMs: vm.videoMeta?.creationTimeMillis,
                            playheadMs: playheadMs
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: VideoFile.self) {
                    await loadVideoFromUrl(movie.url)
                }
            }
        }
        .task {
            // Poll the playhead at ~30 fps for cursor updates on the panels.
            while !Task.isCancelled {
                let t = CMTimeGetSeconds(player.currentTime())
                if t.isFinite {
                    playheadMs = Int64(t * 1000.0)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func loadVideoFromUrl(_ url: URL) async {
        await vm.pickVideo(url)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }
}

// MARK: - Video surface

private struct VideoSurface: View {
    let player: AVPlayer
    let hasVideo: Bool
    /// Real displayed size of the loaded video (after preferred transform).
    /// We use it to set the player's aspect ratio so portrait clips don't
    /// collapse to zero height — without an explicit aspect SwiftUI's
    /// `VideoPlayer` reports no intrinsic size and the view disappears.
    let aspect: CGSize?

    var body: some View {
        ZStack {
            if hasVideo {
                let a = aspect ?? CGSize(width: 9, height: 16)
                VideoPlayer(player: player)
                    .aspectRatio(a.width / a.height, contentMode: .fit)
                    .frame(maxHeight: 420)
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                Text("Pick a video to begin")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Recording picker

private struct RecordingPicker: View {
    @Bindable var vm: ReplayViewModel
    /// Invoked when the user taps Load on a video file under Documents.
    /// The parent owns the AVPlayer so it knows how to swap clips.
    let onVideoPick: (URL) -> Void

    var body: some View {
        let recordings = vm.listLocalRecordings()
        let sensorCandidates = recordings.filter { isSensCsv($0.lastPathComponent) }
        let gpsCandidates = recordings.filter { isGpsCsv($0.lastPathComponent) }
        let videoCandidates = recordings.filter { isVideoFile($0.lastPathComponent) }

        if recordings.isEmpty {
            Text("No CSVs in this app's storage yet. Use the Sync tab to download some first.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !videoCandidates.isEmpty {
                    Text("Video (in Files)").font(.subheadline.weight(.semibold))
                    FileChooserList(files: videoCandidates, selected: vm.videoUrl) { url in
                        onVideoPick(url)
                    }
                }
                Text("Sensor CSV").font(.subheadline.weight(.semibold))
                FileChooserList(files: sensorCandidates, selected: vm.sensorFile) { url in
                    Task { await vm.pickSensorCsv(url) }
                }
                Text("GPS CSV").font(.subheadline.weight(.semibold))
                FileChooserList(files: gpsCandidates, selected: vm.gpsFile) { url in
                    Task { await vm.pickGpsCsv(url) }
                }
            }
        }
    }
}

private struct FileChooserList: View {
    let files: [URL]
    let selected: URL?
    let onPick: (URL) -> Void

    var body: some View {
        if files.isEmpty {
            Text("nothing matching here")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 4) {
                ForEach(files, id: \.path) { f in
                    let isSelected = f == selected
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.lastPathComponent)
                                .fontWeight(isSelected ? .bold : .regular)
                            Text(humanBytesShort(fileSize(f)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
}

// MARK: - Alignment summary

private struct AlignmentSummary: View {
    @Bindable var vm: ReplayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alignment").font(.subheadline.weight(.semibold))
            Text(vm.videoMeta?.creationTimeMillis.map { "video creation: \(formatLocalTime($0)) (local)" }
                ?? "video creation: —")
                .font(.system(size: 12, design: .monospaced))
            Text(vm.gpsAnchorUtcMillis.map { "gps t0:          \(formatLocalTime($0)) (local)" }
                ?? "gps t0:          —")
                .font(.system(size: 12, design: .monospaced))
            Text("sensor rows:     \(vm.sensorRows.count == 0 ? "—" : String(vm.sensorRows.count))")
                .font(.system(size: 12, design: .monospaced))
            Text("gps rows:        \(vm.gpsRows.count == 0 ? "—" : String(vm.gpsRows.count))")
                .font(.system(size: 12, design: .monospaced))
            if let s = vm.rideSlicingSummary {
                Text(s)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Speed panel

private struct SpeedPanel: View {
    let smoothed: [Double]
    let gpsAbsTimesMs: [Int64]
    let videoCreationMs: Int64?
    let playheadMs: Int64

    var body: some View {
        let n = smoothed.count
        let maxV = max(smoothed.max() ?? 0, 5.0)
        let cursorIdx: Int = (videoCreationMs != nil && !gpsAbsTimesMs.isEmpty)
            ? nearestIndexByTime(gpsAbsTimesMs, target: videoCreationMs! + playheadMs)
            : -1
        let currentSpeed = (0..<n).contains(cursorIdx) ? smoothed[cursorIdx] : 0.0

        VStack(alignment: .leading, spacing: 4) {
            Text("Speed (km/h)").font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard n >= 2 else { return }
                    let w = size.width, h = size.height
                    var path = Path()
                    for i in 0..<n {
                        let x = CGFloat(i) / CGFloat(n - 1) * w
                        let y = h - CGFloat(smoothed[i] / maxV) * h
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    if (0..<n).contains(cursorIdx) {
                        let cx = CGFloat(cursorIdx) / CGFloat(n - 1) * w
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: h)) },
                            with: .color(Color(red: 0.83, green: 0.18, blue: 0.18)),
                            lineWidth: 1.5
                        )
                    }
                }
                .frame(height: 140)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.zero)

                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "now %.1f", currentSpeed))
                        .font(.system(size: 12, design: .monospaced))
                    Text(String(format: "max %.1f", maxV))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8).padding(.top, 8)
            }
            if videoCreationMs == nil {
                Text("Video has no creation_time — cursor hidden. Future slice: manual offset slider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pitch panel

private struct PitchPanel: View {
    let pitchDeg: [Double]
    let sensorAbsTimesMs: [Int64]
    let videoCreationMs: Int64?
    let playheadMs: Int64

    var body: some View {
        let n = pitchDeg.count
        if n < 2 {
            EmptyView()
        } else {
            let minV = pitchDeg.min() ?? 0
            let maxV = pitchDeg.max() ?? 0
            let absMax = max(abs(minV), abs(maxV), 5.0)
            let cursorIdx: Int = (videoCreationMs != nil && !sensorAbsTimesMs.isEmpty)
                ? nearestIndexByTime(sensorAbsTimesMs, target: videoCreationMs! + playheadMs)
                : -1
            let currentPitch = (0..<n).contains(cursorIdx) ? pitchDeg[cursorIdx] : 0.0

            VStack(alignment: .leading, spacing: 4) {
                Text("Pitch / Nasenwinkel (°)").font(.subheadline.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let w = size.width, h = size.height
                        let zeroY = h / 2
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: 0, y: zeroY)); p.addLine(to: CGPoint(x: w, y: zeroY)) },
                            with: .color(.gray.opacity(0.5)), lineWidth: 1
                        )
                        var path = Path()
                        for i in 0..<n {
                            let x = CGFloat(i) / CGFloat(n - 1) * w
                            let y = zeroY - CGFloat(pitchDeg[i] / absMax) * (h / 2)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(path, with: .color(.purple), lineWidth: 2)
                        if (0..<n).contains(cursorIdx) {
                            let cx = CGFloat(cursorIdx) / CGFloat(n - 1) * w
                            context.stroke(
                                Path { p in p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: h)) },
                                with: .color(Color(red: 0.83, green: 0.18, blue: 0.18)),
                                lineWidth: 1.5
                            )
                        }
                    }
                    .frame(height: 140)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(format: "now %+.1f°", currentPitch))
                            .font(.system(size: 12, design: .monospaced))
                        Text(String(format: "±%.0f°", absMax))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8).padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - Height panel

private struct HeightPanel: View {
    let baroM: [Double]
    let fusedM: [Double]
    let sensorAbsTimesMs: [Int64]
    let videoCreationMs: Int64?
    let playheadMs: Int64

    private func bounds() -> (Double, Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for v in baroM { if v < lo { lo = v }; if v > hi { hi = v } }
        for v in fusedM { if v < lo { lo = v }; if v > hi { hi = v } }
        if hi - lo < 0.2 { lo -= 0.1; hi += 0.1 }
        return (lo, hi)
    }

    var body: some View {
        let n = fusedM.count
        if n < 2 {
            EmptyView()
        } else {
            let (minV, maxV) = bounds()
            let span = maxV - minV

            let cursorIdx: Int = (videoCreationMs != nil && !sensorAbsTimesMs.isEmpty)
                ? nearestIndexByTime(sensorAbsTimesMs, target: videoCreationMs! + playheadMs)
                : -1
            let curBaro = (0..<baroM.count).contains(cursorIdx) ? baroM[cursorIdx] : 0.0
            let curFused = (0..<fusedM.count).contains(cursorIdx) ? fusedM[cursorIdx] : 0.0

            VStack(alignment: .leading, spacing: 4) {
                Text("Height above water (m)").font(.subheadline.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let w = size.width, h = size.height
                        func drawSeries(_ arr: [Double], color: Color, lineWidth: CGFloat) {
                            guard arr.count >= 2 else { return }
                            var path = Path()
                            for i in 0..<arr.count {
                                let x = CGFloat(i) / CGFloat(arr.count - 1) * w
                                let y = h - CGFloat((arr[i] - minV) / span) * h
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            context.stroke(path, with: .color(color), lineWidth: lineWidth)
                        }
                        drawSeries(baroM, color: .gray.opacity(0.6), lineWidth: 1)
                        drawSeries(fusedM, color: .accentColor, lineWidth: 2)
                        if (0..<n).contains(cursorIdx) {
                            let cx = CGFloat(cursorIdx) / CGFloat(n - 1) * w
                            context.stroke(
                                Path { p in p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: h)) },
                                with: .color(Color(red: 0.83, green: 0.18, blue: 0.18)),
                                lineWidth: 1.5
                            )
                        }
                    }
                    .frame(height: 160)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(format: "fused %+.2f m", curFused))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tint)
                        Text(String(format: "baro  %+.2f m", curBaro))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(String(format: "range %+.2f .. %+.2f", minV, maxV))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8).padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - GPS track panel

private struct GpsTrackPanel: View {
    let gpsRows: [GpsRow]
    let gpsAbsTimesMs: [Int64]
    let videoCreationMs: Int64?
    let playheadMs: Int64

    private func latLonBounds() -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for r in gpsRows {
            if r.lat < minLat { minLat = r.lat }
            if r.lat > maxLat { maxLat = r.lat }
            if r.lon < minLon { minLon = r.lon }
            if r.lon > maxLon { maxLon = r.lon }
        }
        return (minLat, maxLat, minLon, maxLon)
    }

    var body: some View {
        if gpsRows.count < 2 {
            EmptyView()
        } else {
            let b = latLonBounds()
            let minLat = b.minLat, maxLat = b.maxLat, minLon = b.minLon, maxLon = b.maxLon
            // Aspect-correct longitude span by cos(meanLat) so 1° lon ≠ 1° lat.
            let meanLat = (minLat + maxLat) / 2.0
            let lonScale = cos(meanLat * .pi / 180.0)
            let latSpan = max(maxLat - minLat, 1e-9)
            let lonSpan = max((maxLon - minLon) * lonScale, 1e-9)

            let cursorIdx: Int = (videoCreationMs != nil && !gpsAbsTimesMs.isEmpty)
                ? nearestIndexByTime(gpsAbsTimesMs, target: videoCreationMs! + playheadMs)
                : -1

            VStack(alignment: .leading, spacing: 4) {
                Text("GPS track").font(.subheadline.weight(.semibold))
                Canvas { context, size in
                    let w = size.width, h = size.height
                    let scale = min(w / lonSpan, h / latSpan)
                    let cx = w / 2
                    let cy = h / 2
                    let lonMid = (minLon + maxLon) / 2.0
                    let latMid = (minLat + maxLat) / 2.0
                    func project(_ lat: Double, _ lon: Double) -> CGPoint {
                        let dx = (lon - lonMid) * lonScale * scale
                        let dy = (lat - latMid) * scale
                        return CGPoint(x: cx + dx, y: cy - dy)  // North up
                    }
                    var path = Path()
                    for i in 0..<gpsRows.count {
                        let p = project(gpsRows[i].lat, gpsRows[i].lon)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(.teal), lineWidth: 2)
                    if (0..<gpsRows.count).contains(cursorIdx) {
                        let p = project(gpsRows[cursorIdx].lat, gpsRows[cursorIdx].lon)
                        let dotR: CGFloat = 6
                        let dot = Path(ellipseIn: CGRect(
                            x: p.x - dotR, y: p.y - dotR,
                            width: dotR * 2, height: dotR * 2
                        ))
                        context.fill(dot, with: .color(Color(red: 0.83, green: 0.18, blue: 0.18)))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Export

private struct ExportRow: View {
    @Bindable var vm: ReplayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    Task { await vm.exportComposite() }
                } label: {
                    Text(vm.exporting ? "Exporting…" : "Export composite MOV")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    vm.exporting
                    || vm.videoUrl == nil
                    || vm.videoMeta?.creationTimeMillis == nil
                    || vm.pitchDeg.isEmpty
                    || vm.fusedHeightM.isEmpty
                )
                if vm.exporting {
                    ProgressView(value: vm.exportProgress)
                        .frame(maxWidth: .infinity)
                }
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
            } else if vm.videoMeta?.creationTimeMillis == nil && vm.videoUrl != nil {
                Text("video has no creation_time — load a clip with embedded date")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
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

/// Transferable wrapper that lets `PhotosPicker` give us a stable file URL
/// pointing at the picked movie. Importer copies to a tmp location so the
/// URL outlives the picker session.
struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}

/// Nearest-index search by absolute time. `arr` ascending, may contain -1
/// sentinels at the edges from un-parseable utc strings.
private func nearestIndexByTime(_ arr: [Int64], target: Int64) -> Int {
    let n = arr.count
    guard n > 0 else { return -1 }
    var lo = 0
    while lo < n && arr[lo] < 0 { lo += 1 }
    if lo >= n { return -1 }
    var hi = n - 1
    if target <= arr[lo] { return lo }
    if target >= arr[hi] { return hi }
    while lo < hi {
        let mid = (lo + hi) >> 1
        if arr[mid] < target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func isSensCsv(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    return n.hasPrefix("sens") && n.hasSuffix(".csv")
}

private func isGpsCsv(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    return n.hasPrefix("gps") && n.hasSuffix(".csv")
}

private func isVideoFile(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    // Hide the exporter's own output so the picker only shows the source clip.
    if n.hasPrefix("combined_") { return false }
    return n.hasSuffix(".mov") || n.hasSuffix(".mp4") || n.hasSuffix(".m4v")
}

private func fileSize(_ url: URL) -> Int64 {
    let v = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(v?.fileSize ?? 0)
}

private func humanBytesShort(_ b: Int64) -> String {
    if b < 1024 { return "\(b) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024.0) }
    return String(format: "%.2f MB", Double(b) / (1024.0 * 1024.0))
}
