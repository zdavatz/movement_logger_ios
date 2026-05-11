import Foundation
import Observation

/// State + orchestration for the Replay screen. Mirrors the Android
/// `ReplayViewModel.kt`: pick a video and one or two CSV files from
/// the Sync tab's downloads, run the fusion / baro / nose-angle pipeline
/// on a background task, and surface the per-row series plus a per-row
/// absolute-UTC array for time alignment against the video playhead.
@Observable
final class ReplayViewModel {

    var videoUrl: URL? = nil
    var videoMeta: VideoMetadata? = nil
    var sensorFile: URL? = nil
    var gpsFile: URL? = nil
    var sensorRows: [SensorRow] = []
    var gpsRows: [GpsRow] = []
    var gpsAnchorUtcMillis: Int64? = nil
    /// Smoothed position-derived speed per GPS row, km/h.
    var speedSmoothedKmh: [Double] = []
    /// Absolute UTC ms per GPS row. -1 sentinel when the row's `utc` was unparseable.
    var gpsAbsTimesMs: [Int64] = []
    /// Drift-corrected nose angle (Nasenwinkel) per sensor row, degrees.
    var pitchDeg: [Double] = []
    /// Baro-only height above water per sensor row, metres.
    var baroHeightM: [Double] = []
    /// Complementary-fused baro + IMU height per sensor row, metres.
    var fusedHeightM: [Double] = []
    /// Absolute UTC ms per sensor row, derived from ticks against the GPS anchor.
    var sensorAbsTimesMs: [Int64] = []
    /// Sampling rate of the sensor stream, Hz (auto-detected from median tick delta).
    var sampleHz: Double = 0
    var loading: Bool = false
    var computing: Bool = false
    var error: String? = nil

    /// `Sens*`, `Gps*`, `Bat*` files already saved by the Sync tab.
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
            sensorRows = rows
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
                () -> (rows: [GpsRow], smooth: [Double], times: [Int64], anchor: Int64?) in
                let rows = try CsvParsers.parseGpsFile(url)
                // Precompute the speed series + per-row absolute UTC. Done off
                // the main thread since smoothing a multi-thousand-row session
                // shouldn't block UI even though it's fast in absolute terms.
                let raw = GpsMath.positionDerivedSpeedKmh(rows)
                let cleaned = GpsMath.rejectAccOutliers(rows, rawKmh: raw)
                let smooth = GpsMath.smoothSpeedKmh(cleaned)
                let today = GpsTime.todayUtc()
                var times = [Int64](repeating: -1, count: rows.count)
                for i in 0..<rows.count {
                    times[i] = GpsTime.toUtcMillis(
                        rows[i].utc, year: today.year,
                        month1to12: today.month, day: today.day
                    ) ?? -1
                }
                let firstAnchor = times.first(where: { $0 >= 0 })
                return (rows, smooth, times, firstAnchor)
            }.value

            gpsFile = url
            gpsRows = result.rows
            gpsAnchorUtcMillis = result.anchor
            speedSmoothedKmh = result.smooth
            gpsAbsTimesMs = result.times
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

    /// Run the full fusion / baro / height pipeline once both sensor and
    /// GPS CSVs are loaded. Quaternions, drift-corrected pitch, GPS-anchored
    /// baro height, complementary-fused height, and per-sensor-row absolute
    /// UTC all land in state when this returns.
    @MainActor
    private func maybeComputeFusion() async {
        guard !sensorRows.isEmpty, !gpsRows.isEmpty else { return }
        computing = true; error = nil

        let sRows = sensorRows
        let gRows = gpsRows
        let speed = speedSmoothedKmh
        let anchor = gpsAnchorUtcMillis ?? 0

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
            // Per-sensor-row absolute UTC: anchor onto the first GPS fix
            // by tick offset (1 tick = 10 ms).
            let firstGpsTicks = gRows.first!.ticks
            var sensorTimes = [Int64](repeating: 0, count: sRows.count)
            for i in 0..<sRows.count {
                let deltaTicks = sRows[i].ticks - firstGpsTicks
                sensorTimes[i] = anchor + Int64(deltaTicks * 10.0)
            }
            return FusionResults(
                pitch: pitch, baroH: baroH, fusedH: fusedH,
                sensorTimes: sensorTimes, sampleHz: sampleHz
            )
        }.value

        pitchDeg = result.pitch
        baroHeightM = result.baroH
        fusedHeightM = result.fusedH
        sensorAbsTimesMs = result.sensorTimes
        sampleHz = result.sampleHz
        computing = false
    }

    private struct FusionResults {
        let pitch: [Double]
        let baroH: [Double]
        let fusedH: [Double]
        let sensorTimes: [Int64]
        let sampleHz: Double
    }
}
