import Foundation
import Observation
import Photos

/// State + orchestration for the Replay screen.
///
/// Holds the FULL parsed sensor/GPS data internally and exposes a SLICED
/// view (`sensorRows`, `gpsRows`, …) that's narrowed down to the ride
/// window once a video with `creation_time` is loaded. The slice is the
/// portion of the session that overlaps with the video — typically a
/// handful of seconds out of a multi-minute session.
///
/// Sensor-side absolute UTC is built by piecewise-linear interpolation
/// across the GPS rows' wall-clock timestamps (Rust `animate_cmd.rs` style)
/// rather than tick-offset from a single anchor — the ThreadX clock
/// drifts ~7 s over a 21-min session so a single anchor desyncs the
/// cursor on Pitch / Height panels.
@Observable
final class ReplayViewModel {

    // ----- Public state (exposed to the screen) -------------------------------

    var videoUrl: URL? = nil
    var videoMeta: VideoMetadata? = nil
    var sensorFile: URL? = nil
    var gpsFile: URL? = nil
    /// Sliced to the ride window if a video is loaded; full data otherwise.
    var sensorRows: [SensorRow] = []
    var gpsRows: [GpsRow] = []
    var gpsAnchorUtcMillis: Int64? = nil
    var speedSmoothedKmh: [Double] = []
    var gpsAbsTimesMs: [Int64] = []
    var pitchDeg: [Double] = []
    var baroHeightM: [Double] = []
    var fusedHeightM: [Double] = []
    var sensorAbsTimesMs: [Int64] = []
    var sampleHz: Double = 0
    var loading: Bool = false
    var computing: Bool = false
    var error: String? = nil
    var exportProgress: Double = 0
    var exporting: Bool = false
    var lastExportedPath: String? = nil
    var savedToPhotos: Bool = false
    /// One-line summary of the slicing decision — surfaced in the
    /// Alignment block so the user can sanity-check it.
    var rideSlicingSummary: String? = nil

    // ----- Internal full-data backing (NOT observed) --------------------------

    @ObservationIgnored private var fullSensorRows: [SensorRow] = []
    @ObservationIgnored private var fullGpsRows: [GpsRow] = []
    @ObservationIgnored private var fullSmoothedSpeed: [Double] = []
    @ObservationIgnored private var fullGpsAbsTimesMs: [Int64] = []

    // -------------------------------------------------------------------------

    func listLocalRecordings() -> [URL] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor
    func pickVideo(_ url: URL) async {
        loading = true; error = nil
        let meta = await VideoMetadataReader.read(url)
        videoUrl = url
        videoMeta = meta
        // Video creation_time changes the alignment date and the ride window
        // bounds — re-slice the full sensor/GPS data, re-derive timestamps,
        // and re-run fusion on the slice.
        applyVideoAndSlice()
        await maybeComputeFusion()
        loading = false
    }

    @MainActor
    func pickSensorCsv(_ url: URL) async {
        loading = true; error = nil
        do {
            let rows = try await Task.detached(priority: .userInitiated) {
                try CsvParsers.parseSensorFile(url)
            }.value
            sensorFile = url
            fullSensorRows = rows
            applyVideoAndSlice()
            loading = false
            await maybeComputeFusion()
        } catch {
            loading = false
            self.error = "Sensor: \(error.localizedDescription)"
        }
    }

    @MainActor
    func pickGpsCsv(_ url: URL) async {
        loading = true; error = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                () -> (rows: [GpsRow], smooth: [Double]) in
                let rows = try CsvParsers.parseGpsFile(url)
                let raw = GpsMath.positionDerivedSpeedKmh(rows)
                let cleaned = GpsMath.rejectAccOutliers(rows, rawKmh: raw)
                let smooth = GpsMath.smoothSpeedKmh(cleaned)
                return (rows, smooth)
            }.value

            gpsFile = url
            fullGpsRows = result.rows
            fullSmoothedSpeed = result.smooth
            applyVideoAndSlice()
            loading = false
            await maybeComputeFusion()
        } catch {
            loading = false
            self.error = "GPS: \(error.localizedDescription)"
        }
    }

    func clearError() {
        error = nil
    }

    // -------------------------------------------------------------------------
    //  Alignment + slicing
    // -------------------------------------------------------------------------

    /// Re-parse GPS UTC strings against the alignment date, slice both
    /// streams down to the ride window (the portion of the session that
    /// overlaps with the video), and refresh per-row absolute UTC arrays.
    /// Called whenever any of {video, sensor, gps} changes.
    @MainActor
    private func applyVideoAndSlice() {
        // ----- Step 1: pick a date for parsing hhmmss.ss UTC strings.
        let date: (year: Int, month: Int, day: Int)
        if let creation = videoMeta?.creationTimeMillis {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let d = Date(timeIntervalSince1970: TimeInterval(creation) / 1000.0)
            let c = cal.dateComponents([.year, .month, .day], from: d)
            date = (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        } else {
            date = GpsTime.todayUtc()
        }

        // ----- Step 2: compute full-data UTC times from GPS strings.
        fullGpsAbsTimesMs = fullGpsRows.map { row in
            GpsTime.toUtcMillis(
                row.utc, year: date.year, month1to12: date.month, day: date.day
            ) ?? -1
        }

        // ----- Step 3: ride window. With video creation_time + duration,
        // the relevant slice is [creation, creation + duration]. Without a
        // video, "ride window" is the full session.
        let (gpsStart, gpsEnd, summary): (Int, Int, String?)
        if let creation = videoMeta?.creationTimeMillis,
           videoMeta!.durationMillis > 0,
           !fullGpsRows.isEmpty {
            let rideStart = creation
            let rideEnd = creation + videoMeta!.durationMillis
            let s = firstIndexWhereTimeAtLeast(fullGpsAbsTimesMs, rideStart)
            let e = firstIndexWhereTimeGreaterThan(fullGpsAbsTimesMs, rideEnd)
            let validS = max(0, s)
            let validE = max(validS, min(fullGpsRows.count, e))
            gpsStart = validS
            gpsEnd = validE
            let kept = validE - validS
            let dropped = fullGpsRows.count - kept
            let creationLocal = formatLocalTime(creation)
            let endLocal = formatLocalTime(rideEnd)
            summary = "ride window: \(creationLocal) – \(endLocal) " +
                "(kept \(kept) gps rows, dropped \(dropped))"
        } else {
            gpsStart = 0
            gpsEnd = fullGpsRows.count
            summary = nil
        }

        // ----- Step 4: slice GPS series.
        gpsRows = Array(fullGpsRows[gpsStart..<gpsEnd])
        gpsAbsTimesMs = Array(fullGpsAbsTimesMs[gpsStart..<gpsEnd])
        if fullSmoothedSpeed.count == fullGpsRows.count {
            speedSmoothedKmh = Array(fullSmoothedSpeed[gpsStart..<gpsEnd])
        } else {
            speedSmoothedKmh = []
        }
        gpsAnchorUtcMillis = gpsAbsTimesMs.first(where: { $0 >= 0 })

        // ----- Step 5: slice sensor rows by tick range bracketed by the
        // GPS slice. ThreadX ticks are shared between sensor and GPS streams,
        // so this stays correct even under HSI drift.
        if !fullSensorRows.isEmpty && !gpsRows.isEmpty {
            let firstTick = gpsRows.first!.ticks
            let lastTick = gpsRows.last!.ticks
            // Allow a small grace at edges for sensor samples just before the
            // first GPS fix / just after the last one — the per-sensor
            // interpolator handles extrapolation safely.
            let s = firstSensorIndexWithTickAtLeast(fullSensorRows, firstTick)
            let e = firstSensorIndexWithTickGreaterThan(fullSensorRows, lastTick)
            sensorRows = Array(fullSensorRows[s..<max(s, e)])
        } else {
            sensorRows = fullSensorRows
        }

        // ----- Step 6: sensor abs UTC via piecewise-linear interpolation
        // across GPS (tick, utcMs) anchor pairs. Replaces the old
        // single-anchor-extrapolation that drifted by seconds over long sessions.
        sensorAbsTimesMs = interpolateSensorAbsTimes(
            sensorRows: sensorRows, gpsRows: gpsRows, gpsAbsTimesMs: gpsAbsTimesMs
        )

        rideSlicingSummary = summary
    }

    private func firstIndexWhereTimeAtLeast(_ arr: [Int64], _ target: Int64) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = arr[mid]
            if v < 0 || v < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func firstIndexWhereTimeGreaterThan(_ arr: [Int64], _ target: Int64) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = arr[mid]
            if v < 0 || v <= target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func firstSensorIndexWithTickAtLeast(_ rows: [SensorRow], _ tick: Double) -> Int {
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if rows[mid].ticks < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func firstSensorIndexWithTickGreaterThan(_ rows: [SensorRow], _ tick: Double) -> Int {
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if rows[mid].ticks <= tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Piecewise-linear interpolation of (gpsTick → gpsUtcMs) onto sensor ticks.
    /// Outside the GPS coverage we fall back to constant 10 ms/tick from the
    /// nearest GPS anchor; over short overshoots that's fine. Within GPS
    /// coverage this exactly matches the Rust client's behaviour.
    private func interpolateSensorAbsTimes(
        sensorRows: [SensorRow], gpsRows: [GpsRow], gpsAbsTimesMs: [Int64]
    ) -> [Int64] {
        let nSensor = sensorRows.count
        guard nSensor > 0 else { return [] }
        // Build a deduped list of GPS anchors with valid times, sorted by tick.
        var anchors: [(tick: Double, utcMs: Int64)] = []
        anchors.reserveCapacity(gpsRows.count)
        var lastTick: Double = -.infinity
        for i in 0..<gpsRows.count {
            let u = gpsAbsTimesMs[i]
            guard u >= 0 else { continue }
            let t = gpsRows[i].ticks
            if t > lastTick {
                anchors.append((t, u))
                lastTick = t
            }
        }
        guard let firstAnchor = anchors.first else {
            // Fall back to a flat zero baseline — no usable GPS anchors.
            return Array(repeating: 0, count: nSensor)
        }

        var out = [Int64](repeating: 0, count: nSensor)
        var j = 0
        for i in 0..<nSensor {
            let t = sensorRows[i].ticks
            if t <= firstAnchor.tick {
                out[i] = firstAnchor.utcMs + Int64((t - firstAnchor.tick) * 10.0)
                continue
            }
            if t >= anchors.last!.tick {
                let last = anchors.last!
                out[i] = last.utcMs + Int64((t - last.tick) * 10.0)
                continue
            }
            // Advance j to the bracket: anchors[j].tick <= t < anchors[j+1].tick
            while j + 1 < anchors.count && anchors[j + 1].tick <= t { j += 1 }
            let a = anchors[j]
            let b = anchors[j + 1]
            let frac = (t - a.tick) / (b.tick - a.tick)
            let interp = Double(a.utcMs) + Double(b.utcMs - a.utcMs) * frac
            out[i] = Int64(interp)
        }
        return out
    }

    // -------------------------------------------------------------------------
    //  Fusion pipeline
    // -------------------------------------------------------------------------

    @MainActor
    private func maybeComputeFusion() async {
        guard !sensorRows.isEmpty, !gpsRows.isEmpty else {
            pitchDeg = []
            baroHeightM = []
            fusedHeightM = []
            return
        }
        computing = true; error = nil

        let sRows = sensorRows
        let gRows = gpsRows
        let speed = speedSmoothedKmh

        let result = await Task.detached(priority: .userInitiated) {
            () -> FusionResults in
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
            return FusionResults(pitch: pitch, baroH: baroH, fusedH: fusedH, sampleHz: sampleHz)
        }.value

        pitchDeg = result.pitch
        baroHeightM = result.baroH
        fusedHeightM = result.fusedH
        sampleHz = result.sampleHz
        computing = false
    }

    private struct FusionResults {
        let pitch: [Double]
        let baroH: [Double]
        let fusedH: [Double]
        let sampleHz: Double
    }

    // -------------------------------------------------------------------------
    //  Composite export
    // -------------------------------------------------------------------------

    @MainActor
    func exportComposite() async {
        guard let videoUrl = videoUrl,
              let creationMs = videoMeta?.creationTimeMillis else {
            error = "Need a video with creation_time before export"
            return
        }
        guard !sensorRows.isEmpty, !gpsRows.isEmpty,
              !pitchDeg.isEmpty, !fusedHeightM.isEmpty else {
            error = "Wait for fusion to finish before exporting"
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let baseName = videoUrl.deletingPathExtension().lastPathComponent
        let outURL = docs.appendingPathComponent("combined_\(baseName).mov")

        let inputs = CompositeExportInputs(
            sourceVideoURL: videoUrl,
            videoCreationMs: creationMs,
            speedSmoothedKmh: speedSmoothedKmh,
            gpsAbsTimesMs: gpsAbsTimesMs,
            pitchDeg: pitchDeg,
            sensorAbsTimesMs: sensorAbsTimesMs,
            baroHeightM: baroHeightM,
            fusedHeightM: fusedHeightM,
            gpsRows: gpsRows
        )

        exporting = true
        exportProgress = 0
        lastExportedPath = nil
        savedToPhotos = false
        error = nil

        do {
            try await CompositeExporter.export(inputs, to: outURL) { p in
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
