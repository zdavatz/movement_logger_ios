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
        /// AVFoundation's estimate of this clip's H.264 output bytes when it
        /// is re-encoded on its own (see `estimateClipsBytes`). nil = the
        /// clip failed to load; it then counts as zero toward the budget.
        var estBytes: Int64? = nil
        var isLandscape: Bool {
            meta.displayedSize.width > meta.displayedSize.height
        }
    }

    // ----- Public state -------------------------------------------------------

    var clips: [Clip] = []
    /// Landscape picks, kept out of the merge — see `addClips`.
    var skippedClips: [Clip] = []
    /// Portrait picks that did not fit under the 2 GB share limit — the
    /// chronological tail of the pick, held aside so the user sees exactly
    /// where the film was cut off (see `rebalanceSizeBudget`).
    var oversizeClips: [Clip] = []
    var loadingClips: Bool = false
    /// Photo-library import progress ("Loading videos… N/M"): copying the
    /// picked movies out of the library takes seconds per clip, so the
    /// picker phase gets its own progress bar. total == 0 → idle.
    var importingDone: Int = 0
    var importingTotal: Int = 0
    var sensorFile: URL? = nil
    var gpsFile: URL? = nil
    var sensorRowCount: Int = 0
    var gpsRowCount: Int = 0
    /// Optional background-music track for the merged film (a local audio
    /// file — imported from the Files app or already in Documents). Mixed
    /// under the clips' own audio; nothing is ever downloaded (5.2.3).
    var musicFile: URL? = nil
    /// Background-music level, 0…1 (below the footage audio by default).
    var musicVolume: Double = 0.35
    /// Drop the clips' original sound so the music carries the film alone.
    var muteClipAudio: Bool = false
    var parsingCsv: Bool = false
    var computing: Bool = false
    var error: String? = nil
    var exporting: Bool = false
    var exportProgress: Double = 0
    var lastExportedPath: String? = nil
    var savedToPhotos: Bool = false
    /// Estimated size of the merged film (bytes), refreshed whenever the clip
    /// set or the sensor-panel selection changes — from AVFoundation's own
    /// output-length estimator, so the user is warned BEFORE spending minutes
    /// of CPU on the export. nil = not yet known.
    var estimatedExportBytes: Int64? = nil
    /// True when the estimate is at/over WhatsApp's 2 GB share ceiling.
    var exceedsShareLimit: Bool = false

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
    func beginImport(_ total: Int) {
        importingDone = 0
        importingTotal = total
    }

    @MainActor
    func importTick() {
        importingDone += 1
    }

    @MainActor
    func endImport() {
        importingDone = 0
        importingTotal = 0
    }

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
            var clip = Clip(
                url: url, meta: meta, startMs: start,
                hasCreation: meta.creationTimeMillis != nil
            )
            // PORTRAIT ONLY. The merge canvas is the UNION of every clip's
            // displayed size — max width by max height — so a single
            // landscape clip among portrait ones turns a 1080×1920 canvas
            // into a 1920×1920 square: 78 % more pixels in every frame,
            // bars on all of them, and a far heavier export (a mixed
            // 30-clip merge failed where an all-portrait 50-clip merge
            // succeeded). Landscape picks are held aside, not deleted, and
            // listed so the user can see exactly what was left out.
            if clip.isLandscape {
                skippedClips.append(clip)
            } else {
                clip.estBytes = await Self.estimateClipsBytes([clip])
                clips.append(clip)
            }
        }
        skippedClips.sort { $0.startMs < $1.startMs }
        // Chronological by capture time — pick order is irrelevant — and
        // cut off where the film would cross the 2 GB share limit.
        rebalanceSizeBudget()
        loadingClips = false
    }

    /// Admit clips in capture order while the projected film stays under
    /// `shareSizeLimitBytes`; everything after that point moves to
    /// `oversizeClips`. The user asked for the picker to STOP at 2 GB rather
    /// than warn afterwards: "I could select 100 videos and the output file
    /// was 3.2 GB". Chronological admission gives a deterministic answer
    /// ("the film contains the first N clips that fit") and the cut-off
    /// clips stay listed, so any of them can be brought back by removing an
    /// admitted one. Re-run whenever clips or the panel set change — the
    /// panel stack changes the per-second cost, so a film that fit without
    /// panels may not with them (and vice versa).
    @MainActor
    func rebalanceSizeBudget() {
        let all = (clips + oversizeClips).sorted { $0.startMs < $1.startMs }
        var admitted: [Clip] = []
        var overflow: [Clip] = []
        for clip in all {
            if overflow.isEmpty,
               projectedBytes(admitted + [clip]) < Self.shareSizeLimitBytes {
                admitted.append(clip)
            } else {
                overflow.append(clip)
            }
        }
        clips = admitted
        oversizeClips = overflow
        refreshSizeEstimate()
    }

    private static func clipKey(_ startMs: Int64, _ durationMs: Int64) -> String {
        "\(startMs)|\(durationMs)"
    }

    @MainActor
    func removeSkipped(_ clip: Clip) {
        skippedClips.removeAll { $0.id == clip.id }
        Self.deleteTempCopy(clip.url)
    }

    @MainActor
    func removeOversize(_ clip: Clip) {
        oversizeClips.removeAll { $0.id == clip.id }
        Self.deleteTempCopy(clip.url)
    }

    @MainActor
    func removeClip(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        Self.deleteTempCopy(clip.url)
        // Freed budget may let a cut-off clip back in.
        rebalanceSizeBudget()
    }

    @MainActor
    func clearClips() {
        for c in clips + skippedClips + oversizeClips { Self.deleteTempCopy(c.url) }
        clips = []
        skippedClips = []
        oversizeClips = []
        refreshSizeEstimate()
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

    /// Delete every video file in the app's tmp dir. Called once at cold
    /// launch (before any picker can run): the only videos tmp ever holds
    /// are PhotosPicker import copies and the outro anchor, and none of
    /// them can be in use before a scene exists — anything found is a leak
    /// from a force-quit or a killed import.
    static func sweepTmpVideos() {
        let tmp = FileManager.default.temporaryDirectory
        let exts: Set<String> = ["mov", "mp4", "m4v"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)) ?? []
        for f in files where exts.contains(f.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: f)
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
        rebalanceSizeBudget()
    }

    func clearError() {
        error = nil
    }

    // -------------------------------------------------------------------------
    //  Background music (optional)
    // -------------------------------------------------------------------------

    /// Audio-file extensions we surface as background-music candidates.
    private static let audioExts: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "m4r",
    ]

    /// Canonical on-device home for background-music tracks: `Documents/Music/`
    /// (created on demand). Push audio here (`devicectl device copy to …
    /// Documents/Music/`) and it shows in the picker; the same folder receives
    /// files imported through the Files picker. Mirrors Android's `files/Music/`.
    @discardableResult
    func musicDir() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Music", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Audio files in `Documents/Music/` plus any loose in `Documents/`
    /// (legacy / dropped straight in), newest-first, de-duplicated by name.
    func listLocalAudio() -> [URL] {
        var urls: [URL] = []
        if let dir = musicDir() {
            urls += (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        }
        urls += listLocalRecordings()   // Documents root (legacy)
        var seen = Set<String>()
        return urls
            .filter { Self.audioExts.contains($0.pathExtension.lowercased()) }
            .filter { seen.insert($0.lastPathComponent).inserted }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// Import a music file picked from the Files app. The `.fileImporter`
    /// URL is security-scoped and in-place, so copy it into `Documents/Music/`
    /// (where the exporter can read it freely and it survives for re-merges)
    /// while the scope is held. A file already in the Music folder is used
    /// as-is; a loose Documents-root file is consolidated into Music on pick.
    @MainActor
    func pickMusic(_ src: URL) {
        if let dir = musicDir(),
           src.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) {
            musicFile = src
            return
        }
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let dir = musicDir() else {
            error = "Music: no storage directory"
            return
        }
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            musicFile = dest
        } catch {
            self.error = "Music import: \(error.localizedDescription)"
        }
    }

    @MainActor
    func clearMusic() {
        musicFile = nil
    }

    /// Full-session fusion (pitch / baro height / fused height), computed
    /// once; per-clip export inputs slice these by row index.
    @MainActor
    private func computeFullFusion() async {
        guard !fullSensorRows.isEmpty else {
            fullPitchDeg = []
            fullBaroHeightM = []
            fullFusedHeightM = []
            rebalanceSizeBudget()
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
        rebalanceSizeBudget()
    }

    // -------------------------------------------------------------------------
    //  Output-size estimate (WhatsApp 2 GB guard)
    // -------------------------------------------------------------------------

    /// WhatsApp refuses to send a video larger than 2 GB. We estimate the
    /// merged size the moment the clip set changes and flag a film that would
    /// land over the limit BEFORE the export burns minutes of CPU.
    static let shareSizeLimitBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2 GiB

    /// Projected size of a film made of `specs`: the sum of the clips' own
    /// re-encode estimates, scaled for the extra film seconds and the
    /// sensor-panel stack. Synchronous — the per-clip estimates were taken
    /// when the clip was added — so `rebalanceSizeBudget` can decide
    /// admission clip by clip.
    @MainActor
    func projectedBytes(_ specs: [Clip]) -> Int64 {
        guard !specs.isEmpty else { return 0 }
        let base = specs.reduce(Int64(0)) { $0 + max($1.estBytes ?? 0, 0) }
        // Timeline scale: the film adds a 3 s intro, a 2.5 s title + 3 s
        // freeze per clip, and a 5 s outro on top of the clip seconds
        // (mirrors `mergeSummary` / the exporter). The extras are low-motion,
        // so charging them at the average clip bitrate slightly over-estimates
        // — the safe direction for a "will it exceed 2 GB" decision.
        let clipMs = specs.reduce(Int64(0)) { $0 + max($1.meta.durationMillis, 0) }
        let filmMs = clipMs + Int64(specs.count) * (2500 + 3000) + 3000 + 5000
        let filmFactor = clipMs > 0 ? Double(filmMs) / Double(clipMs) : 1.0
        // Panel-stack scale: the render frame grows by the panel band height.
        let panelCount = panelKindCount()
        var panelFactor = 1.0
        if panelCount > 0 {
            let videoH = max(specs.map { $0.meta.displayedSize.height }.max() ?? 1920, 1)
            let stackH = CompositeExporter.panelHeight * CGFloat(panelCount)
            panelFactor = Double((videoH + stackH) / videoH)
        }
        return Int64(Double(base) * filmFactor * panelFactor)
    }

    /// Recompute `estimatedExportBytes` / `exceedsShareLimit` from the current
    /// clip list + panel availability.
    @MainActor
    func refreshSizeEstimate() {
        guard !clips.isEmpty else {
            estimatedExportBytes = nil
            exceedsShareLimit = false
            return
        }
        let est = projectedBytes(clips)
        estimatedExportBytes = est
        exceedsShareLimit = est >= Self.shareSizeLimitBytes
    }

    /// The panel kinds that would render, from full-session availability
    /// (same rule as `mergeAndExport`).
    private func panelKindCount() -> Int {
        var n = 0
        if fullSmoothedSpeed.count >= 2 { n += 1 }
        if fullPitchDeg.count >= 2 { n += 1 }
        if fullFusedHeightM.count >= 2 { n += 1 }
        if fullGpsRows.count >= 2 { n += 1 }
        return n
    }

    /// Build a clips-only composition and ask AVFoundation to estimate the
    /// highest-quality H.264 .mov output length. Returns nil if nothing loads.
    private static func estimateClipsBytes(_ clips: [Clip]) async -> Int64? {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        var cursor = CMTime.zero
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                  let dur = try? await asset.load(.duration),
                  CMTimeGetSeconds(dur) > 0 else { continue }
            try? vTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)
            cursor = CMTimeAdd(cursor, dur)
        }
        guard CMTimeGetSeconds(cursor) > 0,
              let session = AVAssetExportSession(
                  asset: comp, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        session.outputFileType = .mov
        // The estimator returns 0 unless a finite timeRange is set.
        session.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        return try? await session.estimatedOutputFileLengthInBytes
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
        // Keep the (multi-minute) export undisturbed, restored below whatever
        // the outcome:
        //  • Screen awake — auto-lock revokes the hardware encoder and the
        //    export dies with AVError -11847 "Operation Interrupted".
        //  • PORTRAIT-locked — a device rotation mid-export interrupts the
        //    offline render and STOPS the merge (confirmed on device: the
        //    progress halts the instant the phone is rotated). Pinning the
        //    orientation means the screen simply doesn't rotate until the film
        //    is done, then rotates freely again.
        //  • A background-task assertion so switching to another app doesn't
        //    immediately suspend the encode. iOS still caps the background
        //    window, but within it the export keeps running, and beyond it the
        //    session is paused and resumes on return rather than failing.
        UIApplication.shared.isIdleTimerDisabled = true
        AppDelegate.lockPortrait = true
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "merge-export")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            AppDelegate.lockPortrait = false
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        do {
            try await MergeExporter.export(
                clips: specs, panelKinds: kinds,
                backgroundMusic: musicFile,
                musicVolume: Float(musicVolume),
                muteClipAudio: muteClipAudio,
                to: outURL
            ) { p in
                Task { @MainActor [weak self] in self?.exportProgress = p }
            }
            lastExportedPath = outURL.path
            exporting = false
            await saveExportToPhotos()
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

    /// True while the finished film is being copied into the Photos library.
    var savingToPhotos: Bool = false

    /// Add the last exported film to Photos. Also the target of the "Save to
    /// Photos again" button, so a failed import never loses the film (it is
    /// already safe in Documents).
    @MainActor
    func saveExportToPhotos() async {
        guard let path = lastExportedPath, !savingToPhotos else { return }
        savingToPhotos = true
        defer { savingToPhotos = false }
        do {
            try await saveVideoToPhotos(URL(fileURLWithPath: path))
            savedToPhotos = true
            if error?.hasPrefix("saved to Documents but not Photos") == true { error = nil }
        } catch {
            self.error = "saved to Documents but not Photos: \(Self.describeError(error))"
                + " — tap “Save to Photos again” below."
        }
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
        // Importing a multi-GB film is a long copy inside photolibraryd, and
        // it fails with PHPhotosErrorOperationInterrupted (3301, "transient"
        // per Apple) when the app is backgrounded or the media server is
        // still busy tearing down the export. Seen on device after a 1.4 GB
        // merge. Retry a few times with a growing pause before giving up.
        var attempt = 0
        while true {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: url, options: nil)
                }
                return
            } catch {
                let ns = error as NSError
                let transient = ns.domain == PHPhotosErrorDomain
                    && ns.code == PHPhotosError.operationInterrupted.rawValue
                attempt += 1
                guard transient, attempt < 4 else { throw error }
                try? await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }
}

// MARK: - Headless merge self-test (simulator diagnostics)

/// `MERGE_SELFTEST=1` launch-env hook (same family as `INITIAL_TAB`):
/// merges every video already in Documents — plain, no panels, no Photos
/// write, no UI — and prints the detailed result to stdout. Lets
/// `simctl launch --console-pty` reproduce an export failure and capture
/// the REAL NSError chain without driving the picker UI.
/// Print-throttle for the self-test's progress callback (which fires every
/// 100 ms): emit a line only when the percentage advances by ≥5, so a
/// failure's position on the timeline is visible without flooding the log.
/// A class because the callback is an escaping @Sendable closure.
final class Pct: @unchecked Sendable {
    private var last = -5
    func shouldPrint(_ pct: Int) -> Bool {
        guard pct >= last + 5 else { return false }
        last = pct
        return true
    }
}

enum MergeSelfTest {

    static func runIfRequested() {
        // MERGE_SELFTEST_PHOTOS=<N>: merge the last N videos from the Photos
        // library through the REAL MergeViewModel path (estimate + export),
        // reproducing a user-scale merge on device. Takes precedence.
        if let raw = ProcessInfo.processInfo.environment["MERGE_SELFTEST_PHOTOS"],
           let count = Int(raw), count > 0 {
            Task.detached(priority: .userInitiated) { await runPhotos(count: count) }
            return
        }
        guard ProcessInfo.processInfo.environment["MERGE_SELFTEST"] == "1" else { return }
        Task.detached(priority: .userInitiated) { await run() }
    }

    /// Merge the last `count` videos in the Photos library via the full
    /// `MergeViewModel` path — so the size estimate, portrait lock, and the
    /// actual export are all exercised exactly as a user tap would. Prints the
    /// estimate up front (before the long encode) and the final result.
    private static func runPhotos(count: Int) async {
        // Reading the library needs NSPhotoLibraryUsageDescription; the app
        // only ships the add-only string (it uses the out-of-process
        // PhotosPicker, which needs no read permission). Requesting read access
        // without that key makes iOS abort (SIGABRT) — so this dev harness only
        // runs when the key has been added to Info.plist for a test build.
        guard Bundle.main.object(
            forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            print("[selftest-photos] SKIPPED: add NSPhotoLibraryUsageDescription to "
                + "Info.plist for this dev build to read the Photos library "
                + "(the shipping app never requests read access).")
            return
        }
        print("[selftest-photos] requesting Photos access")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            print("[selftest-photos] FAILED: Photos access denied (status \(status.rawValue)) "
                + "— grant Photos access to MovementLogger and relaunch")
            return
        }
        // Wait for foreground-active (VideoToolbox denies codec sessions to
        // apps that aren't active yet — -12780).
        var waitedMs = 0
        while waitedMs < 20000 {
            let s = await MainActor.run { UIApplication.shared.applicationState }
            if s == .active { break }
            try? await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
        }
        print("[selftest-photos] app active after \(waitedMs) ms")

        // Fetch the newest `count` videos.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = count
        let assets = PHAsset.fetchAssets(with: .video, options: opts)
        print("[selftest-photos] fetched \(assets.count) videos (requested \(count))")
        guard assets.count > 0 else { print("[selftest-photos] FAILED: no videos"); return }

        // Materialize each into tmp (same as PhotosPicker's own import copy).
        let tmp = FileManager.default.temporaryDirectory
        var urls: [URL] = []
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            let dst = tmp.appendingPathComponent("selftest_photo_\(i).mov")
            if await materialize(asset, to: dst) { urls.append(dst) }
        }
        print("[selftest-photos] materialized \(urls.count)/\(assets.count) clips to tmp")
        guard !urls.isEmpty else { print("[selftest-photos] FAILED: nothing materialized"); return }

        // Drive the REAL view-model path.
        let vm = await MainActor.run { MergeViewModel() }
        await vm.addClips(urls)
        // Let the (async) size estimate land.
        try? await Task.sleep(for: .seconds(2))
        let (nClips, nSkipped, nOver, est, over) = await MainActor.run {
            (vm.clips.count, vm.skippedClips.count, vm.oversizeClips.count,
             vm.estimatedExportBytes, vm.exceedsShareLimit)
        }
        let estStr = est.map { String(format: "%.2f GB (%lld bytes)", Double($0) / 1_073_741_824.0, $0) } ?? "nil"
        print("[selftest-photos] clips(portrait)=\(nClips) skipped(landscape)=\(nSkipped) cut(over2GB)=\(nOver)")
        print("[selftest-photos] estimated size = \(estStr) — over 2 GB? \(over)")

        // The full merge is a many-minute encode that also writes the (possibly
        // multi-GB) film to Photos, so it only runs with the explicit opt-in;
        // otherwise the harness stops at the estimate.
        guard ProcessInfo.processInfo.environment["MERGE_SELFTEST_PHOTOS_MERGE"] == "1" else {
            for u in urls { try? FileManager.default.removeItem(at: u) }
            print("[selftest-photos] estimate-only (set MERGE_SELFTEST_PHOTOS_MERGE=1 to also run the merge)")
            print("[selftest-photos] done")
            return
        }

        // Run the actual merge (this is the long part).
        print("[selftest-photos] starting merge export…")
        let t0 = Date()
        await vm.mergeAndExport()
        let (outPath, errMsg, saved) = await MainActor.run {
            (vm.lastExportedPath, vm.error, vm.savedToPhotos)
        }
        if let outPath {
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: outPath)[.size]) as? Int64) ?? 0
            print(String(format: "[selftest-photos] SUCCESS in %.1fs — actual %.2f GB (%lld bytes), estimate was %@",
                         Date().timeIntervalSince(t0),
                         Double(bytes) / 1_073_741_824.0, bytes, estStr))
            print("[selftest-photos] savedToPhotos=\(saved) output=\(outPath)")
            if let errMsg { print("[selftest-photos] note: \(errMsg)") }
        } else {
            print("[selftest-photos] FAILED: \(errMsg ?? "unknown")")
        }
        // Clean up the tmp import copies.
        for u in urls { try? FileManager.default.removeItem(at: u) }
        print("[selftest-photos] done")
    }

    /// Copy a Photos video asset's original file into `dst` (fast path via the
    /// AVURLAsset the request hands back), falling back to a passthrough export
    /// for edited/slow-motion assets that don't expose a plain URL.
    private static func materialize(_ asset: PHAsset, to dst: URL) async -> Bool {
        try? FileManager.default.removeItem(at: dst)
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        let av: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(
                forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }
        if let urlAsset = av as? AVURLAsset {
            if (try? FileManager.default.copyItem(at: urlAsset.url, to: dst)) != nil { return true }
        }
        guard let av,
              let session = AVAssetExportSession(
                  asset: av, presetName: AVAssetExportPresetPassthrough) else { return false }
        session.outputURL = dst
        session.outputFileType = .mov
        await session.export()
        return session.status == .completed
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
        var expectedS = 3.0 + 5.0   // gradient intro + logo outro
        for f in files {
            let meta = await VideoMetadataReader.read(f)
            let start = meta.creationTimeMillis ?? 0
            // Per clip: 2.5 s title card + full clip + 3 s freeze fade-out.
            expectedS += 2.5 + Double(meta.durationMillis) / 1000.0 + 3.0
            print("[selftest] clip \(f.lastPathComponent): "
                + "dur=\(meta.durationMillis)ms size=\(Int(meta.displayedSize.width))x\(Int(meta.displayedSize.height)) "
                + "creation=\(start)")
            specs.append(MergeClipSpec(url: f, startEpochMs: start, panelInputs: nil))
        }
        specs.sort { $0.startEpochMs < $1.startEpochMs }
        let out = docs.appendingPathComponent("merged_selftest.mov")
        let t0 = Date()
        do {
            let lastPct = Pct()
            try await MergeExporter.export(clips: specs, panelKinds: [], to: out) { p in
                let pct = Int(p * 100)
                if lastPct.shouldPrint(pct) { print("[selftest] progress \(pct)%") }
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
