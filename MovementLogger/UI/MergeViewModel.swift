import Foundation
import Observation
import Photos

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
        for url in urls {
            let meta = await VideoMetadataReader.read(url)
            let start = meta.creationTimeMillis ?? Self.fileModMillis(url)
            clips.append(Clip(
                url: url, meta: meta, startMs: start,
                hasCreation: meta.creationTimeMillis != nil
            ))
        }
        // Chronological by capture time — pick order is irrelevant.
        clips.sort { $0.startMs < $1.startMs }
        loadingClips = false
    }

    @MainActor
    func removeClip(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
    }

    @MainActor
    func clearClips() {
        clips = []
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
                self.error = "saved to Documents but not Photos: \(error.localizedDescription)"
            }
            exporting = false
        } catch {
            self.error = error.localizedDescription
            exporting = false
        }
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
