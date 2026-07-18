import Foundation
import Observation
import Photos
import AVFoundation
import UIKit

/// State + orchestration for the Merge screen.
///
/// The user picks MULTIPLE videos (PhotosPicker multi-select or files in
/// Documents); clips are sorted by capture time (`creationTimeMillis`,
/// falling back to the file's modification date) — pick order is
/// irrelevant. Optionally a Sens*/Gps* CSV pair from the Sync tab wires
/// the Replay-style sensor panels under every clip; without CSVs the
/// merge is plain video.
///
/// Unlike `ReplayViewModel` (which slices data to ONE video window and
/// runs fusion on the slice), fusion here runs ONCE over the full session
/// and each clip's export inputs are index-sliced out of the full-session
/// series — same numbers, one compute, N clips.
@Observable
final class MergeViewModel {

    struct Clip: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let meta: VideoMetadata
        /// creation_time when present, file mod-date otherwise. Drives the
        /// chronological sort, the title card, and the panel alignment.
        let startMs: Int64
        let hasCreation: Bool
    }

    // ----- Public state -------------------------------------------------------

    var clips: [Clip] = []
    var loadingClips: Bool = false
    var sensorFile: URL? = nil
    var gpsFile: URL? = nil
    var sensorRowCount: Int = 0
    var gpsRowCount: Int = 0
    var parsingCsv: Bool = false
    var computing: Bool = false
    var error: String? = nil
    var exporting: Bool = false
    var exportProgress: Double = 0
    var lastExportedPath: String? = nil
    var savedToPhotos: Bool = false

    // ----- Full-session backing (NOT observed) --------------------------------

    @ObservationIgnored private var fullSensorRows: [SensorRow] = []
    @ObservationIgnored private var fullGpsRows: [GpsRow] = []
    @ObservationIgnored private var fullSmoothedSpeed: [Double] = []
    @ObservationIgnored private var sensorSyncAnchors: [SyncAnchor] = []
    @ObservationIgnored private var gpsSyncAnchors: [SyncAnchor] = []
    @ObservationIgnored private var fullPitchDeg: [Double] = []
    @ObservationIgnored private var fullBaroHeightM: [Double] = []
    @ObservationIgnored private var fullFusedHeightM: [Double] = []

    // -------------------------------------------------------------------------
    //  Clip management
    // -------------------------------------------------------------------------

    @MainActor
    func addClips(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        loadingClips = true
        error = nil
        // Dedup by identity, NOT by URL — every PhotosPicker import copies
        // to a fresh UUID temp path, so the same video re-delivered by a
        // stale picker selection arrives under a different URL. The
        // (capture time, duration) pair identifies the recording itself.
        var seen = Set<String>(clips.map { Self.clipKey($0.startMs, $0.meta.durationMillis) })
        for url in urls {
            let meta = await VideoMetadataReader.read(url)
            let start = meta.creationTimeMillis ?? Self.fileModMillis(url)
            let key = Self.clipKey(start, meta.durationMillis)
            if seen.contains(key) {
                Self.deleteTempCopy(url)   // duplicate — drop its temp copy
                continue
            }
            seen.insert(key)
            clips.append(Clip(
                url: url, meta: meta, startMs: start,
                hasCreation: meta.creationTimeMillis != nil
            ))
        }
        // Chronological by capture time — pick order is irrelevant.
        clips.sort { $0.startMs < $1.startMs }
        loadingClips = false
    }

    private static func clipKey(_ startMs: Int64, _ durationMs: Int64) -> String {
        "\(startMs)|\(durationMs)"
    }

    @MainActor
    func removeClip(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        Self.deleteTempCopy(clip.url)
    }

    @MainActor
    func clearClips() {
        for c in clips { Self.deleteTempCopy(c.url) }
        clips = []
    }

    /// PhotosPicker imports live in the app's tmp dir (`VideoFile`
    /// Transferable copies them there); delete a clip's copy when it
    /// leaves the list. Files elsewhere (e.g. Documents) are untouched.
    private static func deleteTempCopy(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(tmp) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func fileModMillis(_ url: URL) -> Int64 {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) else { return 0 }
        return Int64(d.timeIntervalSince1970 * 1000.0)
    }

    // -------------------------------------------------------------------------
    //  Session CSVs (optional)
    // -------------------------------------------------------------------------

    /// CSV candidates in Documents, newest-first (same listing as Replay).
    func listLocalRecordings() -> [URL] {
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    @MainActor
    func pickSensorCsv(_ url: URL) async {
        parsingCsv = true
        error = nil
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                () -> (rows: [SensorRow], anchors: [SyncAnchor]) in
                let text = try String(contentsOf: url, encoding: .utf8)
                return (try CsvParsers.parseSensorText(text),
                        CsvParsers.parseSyncAnchors(text))
            }.value
            sensorFile = url
            fullSensorRows = parsed.rows
            sensorSyncAnchors = parsed.anchors
            sensorRowCount = parsed.rows.count
            parsingCsv = false
            await computeFullFusion()
        } catch {
            parsingCsv = false
            self.error = "Sensor: \(error.localizedDescription)"
        }
    }

    @MainActor
    func pickGpsCsv(_ url: URL) async {
        parsingCsv = true
        error = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                () -> (rows: [GpsRow], smooth: [Double], anchors: [SyncAnchor]) in
                let text = try String(contentsOf: url, encoding: .utf8)
                let rows = try CsvParsers.parseGpsText(text)
                let raw = GpsMath.positionDerivedSpeedKmh(rows)
                let cleaned = GpsMath.rejectAccOutliers(rows, rawKmh: raw)
                let smooth = GpsMath.smoothSpeedKmh(cleaned)
                return (rows, smooth, CsvParsers.parseSyncAnchors(text))
            }.value
            gpsFile = url
            fullGpsRows = result.rows
            fullSmoothedSpeed = result.smooth
            gpsSyncAnchors = result.anchors
            gpsRowCount = result.rows.count
            parsingCsv = false
            // Baro's water reference is GPS-anchored — refresh the fusion.
            await computeFullFusion()
        } catch {
            parsingCsv = false
            self.error = "GPS: \(error.localizedDescription)"
        }
    }

    @MainActor
    func clearCsvs() {
        sensorFile = nil
        gpsFile = nil
        sensorRowCount = 0
        gpsRowCount = 0
        fullSensorRows = []
        fullGpsRows = []
        fullSmoothedSpeed = []
        sensorSyncAnchors = []
        gpsSyncAnchors = []
        fullPitchDeg = []
        fullBaroHeightM = []
        fullFusedHeightM = []
    }

    func clearError() {
        error = nil
    }

    /// Full-session fusion (pitch / baro height / fused height), computed
    /// once; per-clip export inputs slice these by row index.
    @MainActor
    private func computeFullFusion() async {
        guard !fullSensorRows.isEmpty else {
            fullPitchDeg = []
            fullBaroHeightM = []
            fullFusedHeightM = []
            return
        }
        computing = true
        let sRows = fullSensorRows
        let gRows = fullGpsRows
        let speed = fullSmoothedSpeed
        let result = await Task.detached(priority: .userInitiated) {
            () -> (pitch: [Double], baroH: [Double], fusedH: [Double]) in
            let dt = Fusion.detectDtSeconds(sRows)
            let sampleHz = 1.0 / dt
            let quats = Fusion.computeQuaternions(sRows, beta: 0.1)
            let hzInt = max(Int(sampleHz), 1)
            let pitch = Fusion.noseAngleSeriesDeg(quats, sampleHz: hzInt)
            let baseTicks = sRows.first!.ticks
            let baroH = Baro.heightAboveWaterM(
                sensors: sRows, gps: gRows, speedKmh: speed, baseTicks: baseTicks
            )
            let fusedH = FusionHeight.fusedHeightM(
                sensors: sRows, quats: quats, baroHeight: baroH, sampleHz: sampleHz
            )
            return (pitch, baroH, fusedH)
        }.value
        fullPitchDeg = result.pitch
        fullBaroHeightM = result.baroH
        fullFusedHeightM = result.fusedH
        computing = false
    }

    // -------------------------------------------------------------------------
    //  Merge + export
    // -------------------------------------------------------------------------

    var hasPanelData: Bool {
        fullPitchDeg.count >= 2 || fullSmoothedSpeed.count >= 2 || fullGpsRows.count >= 2
    }

    @MainActor
    func mergeAndExport() async {
        guard !clips.isEmpty else {
            error = "Pick at least one video first"
            return
        }
        let sorted = clips.sorted { $0.startMs < $1.startMs }

        // Global panel kinds from full-session availability so every clip
        // gets the same panel stack geometry (a clip whose window misses
        // the session just shows the empty panel frames).
        var kinds: [CompositeExporter.PanelKind] = []
        if fullSmoothedSpeed.count >= 2 { kinds.append(.speed) }
        if fullPitchDeg.count >= 2 { kinds.append(.pitch) }
        if fullFusedHeightM.count >= 2 { kinds.append(.height) }
        if fullGpsRows.count >= 2 { kinds.append(.gpsTrack) }

        let gpsAbs = kinds.isEmpty ? [] : gpsAbsTimes()
        let senAbs = kinds.isEmpty ? [] : sensorAbsTimes(gpsAbs: gpsAbs)

        let specs = sorted.map { clip in
            MergeClipSpec(
                url: clip.url,
                startEpochMs: clip.startMs,
                panelInputs: kinds.isEmpty
                    ? nil
                    : sliceInputs(for: clip, gpsAbs: gpsAbs, senAbs: senAbs)
            )
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stampF = DateFormatter()
        stampF.locale = Locale(identifier: "en_US_POSIX")
        stampF.dateFormat = "yyyyMMdd_HHmmss"
        let outURL = docs.appendingPathComponent("merged_\(stampF.string(from: Date())).mov")

        exporting = true
        exportProgress = 0
        lastExportedPath = nil
        savedToPhotos = false
        error = nil
        do {
            try await MergeExporter.export(clips: specs, panelKinds: kinds, to: outURL) { p in
                Task { @MainActor [weak self] in self?.exportProgress = p }
            }
            lastExportedPath = outURL.path
            do {
                try await saveVideoToPhotos(outURL)
                savedToPhotos = true
            } catch {
                self.error = "saved to Documents but not Photos: \(Self.describeError(error))"
            }
            exporting = false
        } catch {
            self.error = Self.describeError(error)
            exporting = false
        }
    }

    /// Human-debuggable error text: localizedDescription PLUS the NSError
    /// domain+code and the underlying-error chain. A bare
    /// "The operation could not be completed" from AVFoundation is
    /// useless in a bug report; the codes are what identify the failure.
    static func describeError(_ error: Error) -> String {
        if let m = error as? MergeExportError { return m.localizedDescription }
        let ns = error as NSError
        var msg = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let u = underlying {
            msg += " ← \(u.domain) \(u.code): \(u.localizedDescription)"
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return msg
    }

    /// Full-session GPS abs times: `# SYNC` anchors when present (drift-free,
    /// same clock domain as the videos), else legacy hhmmss.ss parsing dated
    /// by the earliest clip's capture day.
    private func gpsAbsTimes() -> [Int64] {
        guard !fullGpsRows.isEmpty else { return [] }
        if !gpsSyncAnchors.isEmpty {
            return ReplayViewModel.absTimesFromSyncAnchors(
                ticks: fullGpsRows.map { $0.ticks }, anchors: gpsSyncAnchors)
        }
        let date: (year: Int, month: Int, day: Int)
        if let first = clips.map({ $0.startMs }).min(), first > 0 {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents(
                [.year, .month, .day],
                from: Date(timeIntervalSince1970: TimeInterval(first) / 1000.0))
            date = (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        } else {
            date = GpsTime.todayUtc()
        }
        return fullGpsRows.map { row in
            GpsTime.toUtcMillis(
                row.utc, year: date.year, month1to12: date.month, day: date.day
            ) ?? -1
        }
    }

    private func sensorAbsTimes(gpsAbs: [Int64]) -> [Int64] {
        guard !fullSensorRows.isEmpty else { return [] }
        if !sensorSyncAnchors.isEmpty {
            return ReplayViewModel.absTimesFromSyncAnchors(
                ticks: fullSensorRows.map { $0.ticks }, anchors: sensorSyncAnchors)
        }
        return ReplayViewModel.interpolateSensorAbsTimes(
            sensorRows: fullSensorRows, gpsRows: fullGpsRows, gpsAbsTimesMs: gpsAbs)
    }

    /// Slice the full-session series down to one clip's window
    /// [startMs, startMs + duration] — the merge-time analogue of
    /// `ReplayViewModel.applyVideoAndSlice`, minus the fallbacks (a clip
    /// outside the session simply gets empty panel series).
    private func sliceInputs(
        for clip: Clip, gpsAbs: [Int64], senAbs: [Int64]
    ) -> CompositeExportInputs {
        let start = clip.startMs
        let end = start + max(clip.meta.durationMillis, 0)

        let gs = lowerBound(gpsAbs, start)
        let ge = upperBound(gpsAbs, end)
        let vgs = max(0, min(gs, fullGpsRows.count))
        let vge = max(vgs, min(fullGpsRows.count, ge))

        let ss = lowerBound(senAbs, start)
        let se = upperBound(senAbs, end)
        let vss = max(0, min(ss, fullSensorRows.count))
        let vse = max(vss, min(fullSensorRows.count, se))

        func sliceD(_ a: [Double], _ lo: Int, _ hi: Int) -> [Double] {
            guard lo >= 0, hi <= a.count, lo <= hi else { return [] }
            return Array(a[lo..<hi])
        }
        return CompositeExportInputs(
            sourceVideoURL: clip.url,
            videoCreationMs: start,
            speedSmoothedKmh: (fullSmoothedSpeed.count == fullGpsRows.count)
                ? sliceD(fullSmoothedSpeed, vgs, vge) : [],
            gpsAbsTimesMs: Array(gpsAbs[vgs..<vge]),
            pitchDeg: sliceD(fullPitchDeg, vss, vse),
            sensorAbsTimesMs: Array(senAbs[vss..<vse]),
            baroHeightM: sliceD(fullBaroHeightM, vss, vse),
            fusedHeightM: sliceD(fullFusedHeightM, vss, vse),
            gpsRows: Array(fullGpsRows[vgs..<vge])
        )
    }

    /// First index with arr[i] >= target (negative sentinels skipped).
    private func lowerBound(_ arr: [Int64], _ target: Int64) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = arr[mid]
            if v < 0 || v < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index with arr[i] > target (negative sentinels skipped).
    private func upperBound(_ arr: [Int64], _ target: Int64) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = arr[mid]
            if v < 0 || v <= target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func saveVideoToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "MovementLogger", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Photos write permission denied — enable in Settings → Privacy → Photos."]
            )
        }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

// MARK: - Headless merge self-test (simulator diagnostics)

/// `MERGE_SELFTEST=1` launch-env hook (same family as `INITIAL_TAB`):
/// merges every video already in Documents — plain, no panels, no Photos
/// write, no UI — and prints the detailed result to stdout. Lets
/// `simctl launch --console-pty` reproduce an export failure and capture
/// the REAL NSError chain without driving the picker UI.
enum MergeSelfTest {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["MERGE_SELFTEST"] == "1" else { return }
        Task.detached(priority: .userInitiated) { await run() }
    }

    private static func run() async {
        print("[selftest] merge self-test starting")
        // Wait for foreground-active FIRST: this task starts at
        // didFinishLaunching, and VideoToolbox denies codec sessions to
        // apps that are not yet active (-12780) — which would fail the
        // export for a reason a user-tapped merge never sees.
        var waitedMs = 0
        while waitedMs < 20000 {
            let state = await MainActor.run { UIApplication.shared.applicationState }
            if state == .active { break }
            try? await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
        }
        print("[selftest] app active after \(waitedMs) ms")
        try? await Task.sleep(for: .milliseconds(750))
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            print("[selftest] FAILED: no Documents dir")
            return
        }
        let exts: Set<String> = ["mov", "mp4", "m4v"]
        // Optional name-prefix filter so device runs can select a clip set
        // without deleting files from Documents.
        let prefix = ProcessInfo.processInfo.environment["MERGE_SELFTEST_FILTER"] ?? ""
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter {
                exts.contains($0.pathExtension.lowercased())
                    && !$0.lastPathComponent.hasPrefix("merged_")
                    && (prefix.isEmpty || $0.lastPathComponent.hasPrefix(prefix))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("[selftest] found \(files.count) clips in Documents")
        guard !files.isEmpty else {
            print("[selftest] FAILED: nothing to merge")
            return
        }
        // Controls: isolate the AVFoundation layer at fault before the
        // real merge — (A) plain asset export, (B) minimal composition,
        // then stepwise toward the merge's construction.
        await controlPlainExport(files[0], docs: docs)
        await controlCompositionExport(files[0], docs: docs)
        await controlStep(files[0], docs: docs, name: "ctlC-audio",
                          audio: true, optimize: false, poller: false)
        await controlStep(files[0], docs: docs, name: "ctlD-optimize",
                          audio: true, optimize: true, poller: false)
        await controlStep(files[0], docs: docs, name: "ctlE-poller",
                          audio: true, optimize: true, poller: true)

        var specs: [MergeClipSpec] = []
        var expectedS = 5.0   // logo outro
        for f in files {
            let meta = await VideoMetadataReader.read(f)
            let start = meta.creationTimeMillis ?? 0
            expectedS += 2.5 + Double(meta.durationMillis) / 1000.0
            print("[selftest] clip \(f.lastPathComponent): "
                + "dur=\(meta.durationMillis)ms size=\(Int(meta.displayedSize.width))x\(Int(meta.displayedSize.height)) "
                + "creation=\(start)")
            specs.append(MergeClipSpec(url: f, startEpochMs: start, panelInputs: nil))
        }
        specs.sort { $0.startEpochMs < $1.startEpochMs }
        let out = docs.appendingPathComponent("merged_selftest.mov")
        let t0 = Date()
        do {
            try await MergeExporter.export(clips: specs, panelKinds: [], to: out) { p in
                let pct = Int(p * 100)
                if pct % 25 == 0 { print("[selftest] progress \(pct)%") }
            }
            let asset = AVURLAsset(url: out)
            let durS = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? -1
            let bytes = (try? FileManager.default.attributesOfItem(
                atPath: out.path)[.size] as? Int64) ?? 0
            print(String(format: "[selftest] SUCCESS in %.1fs — duration=%.2fs (expected %.2fs)",
                         Date().timeIntervalSince(t0), durS, expectedS)
                + " bytes=\(bytes)")
            print("[selftest] output: \(out.path)")
        } catch {
            print("[selftest] FAILED: \(MergeViewModel.describeError(error))")
            let ns = error as NSError
            print("[selftest] userInfo: \(ns.userInfo)")
        }
        print("[selftest] done")
    }

    /// Control A: export the raw asset — no composition, no instructions.
    private static func controlPlainExport(_ src: URL, docs: URL) async {
        let out = docs.appendingPathComponent("merged_ctlA.mov")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            print("[selftest] ctlA: no session")
            return
        }
        s.outputURL = out
        s.outputFileType = .mov
        await s.export()
        let err = s.error.map { MergeViewModel.describeError($0) } ?? "nil"
        print("[selftest] ctlA(plain asset) status=\(s.status.rawValue) err=\(err)")
    }

    /// Control B: one-track composition of the same clip — no videoComposition.
    private static func controlCompositionExport(_ src: URL, docs: URL) async {
        let out = docs.appendingPathComponent("merged_ctlB.mov")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let v = try? await asset.loadTracks(withMediaType: .video).first,
              let dur = try? await asset.load(.duration),
              let ct = comp.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            print("[selftest] ctlB: setup failed")
            return
        }
        do {
            try ct.insertTimeRange(
                CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
        } catch {
            print("[selftest] ctlB: insert failed \(error)")
            return
        }
        guard let s = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            print("[selftest] ctlB: no session")
            return
        }
        s.outputURL = out
        s.outputFileType = .mov
        await s.export()
        let err = s.error.map { MergeViewModel.describeError($0) } ?? "nil"
        print("[selftest] ctlB(composition) status=\(s.status.rawValue) err=\(err)")
    }

    /// Stepwise control: ctlB + optional audio insert (merge-style clamped
    /// range), optional shouldOptimizeForNetworkUse, optional progress
    /// poller — the remaining deltas between ctlB and the failing merge.
    private static func controlStep(
        _ src: URL, docs: URL, name: String,
        audio: Bool, optimize: Bool, poller: Bool
    ) async {
        let out = docs.appendingPathComponent("merged_\(name).mov")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let v = try? await asset.loadTracks(withMediaType: .video).first,
              let dur = try? await asset.load(.duration),
              let ct = comp.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            print("[selftest] \(name): setup failed")
            return
        }
        try? ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
        if audio, let a = try? await asset.loadTracks(withMediaType: .audio).first,
           let cat = comp.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let ar = (try? await a.load(.timeRange)) ?? .zero
            let aDur = CMTimeMinimum(ar.duration, dur)
            try? cat.insertTimeRange(
                CMTimeRange(start: ar.start, duration: aDur), of: a, at: .zero)
        }
        guard let s = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            print("[selftest] \(name): no session")
            return
        }
        s.outputURL = out
        s.outputFileType = .mov
        if optimize { s.shouldOptimizeForNetworkUse = true }
        var p: CompositeExporter.ProgressPoller? = nil
        if poller {
            p = CompositeExporter.ProgressPoller(session: s) { _ in }
            p?.start()
        }
        await s.export()
        p?.stop()
        let err = s.error.map { MergeViewModel.describeError($0) } ?? "nil"
        print("[selftest] \(name) status=\(s.status.rawValue) err=\(err)")
    }
}
