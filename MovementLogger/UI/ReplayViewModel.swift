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
    /// One-line summary of what `autoPickMatchingCsvs` decided on the
    /// most recent video pick. Surfaced in `LoadedStatusBar` so the user
    /// can immediately see what (if anything) was auto-loaded.
    var autoPickSummary: String? = nil
    /// How the panels are time-aligned to the video, so the user knows
    /// whether the cursor is exact or a best-effort sweep:
    /// "Phone-clock sync — exact" (firmware `# SYNC` markers, the new path),
    /// "GPS-derived time", or "Approximate — …" (cursor sweep, no real
    /// wall-clock). Surfaced in the Alignment block.
    var alignmentSource: String? = nil

    // ----- Internal full-data backing (NOT observed) --------------------------

    @ObservationIgnored private var fullSensorRows: [SensorRow] = []
    @ObservationIgnored private var fullGpsRows: [GpsRow] = []
    @ObservationIgnored private var fullSmoothedSpeed: [Double] = []
    @ObservationIgnored private var fullGpsAbsTimesMs: [Int64] = []
    /// Host-clock time-sync anchors (`# SYNC` markers) extracted from the
    /// loaded sensor / GPS CSVs. When present, they drive a drift-free,
    /// GPS-independent tick→wall-clock mapping that shares the video's clock
    /// domain — see `applyVideoAndSlice` / `absTimesFromSyncAnchors`.
    @ObservationIgnored private var sensorSyncAnchors: [SyncAnchor] = []
    @ObservationIgnored private var gpsSyncAnchors: [SyncAnchor] = []

    // -------------------------------------------------------------------------

    func listLocalRecordings() -> [URL] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        // Newest-first by content modification date — the most recent box
        // sync / iPhone-GPS recording floats to the top so the user lands on
        // the latest session without scrolling past `Sens000…SensNNN-1`.
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
    func pickVideo(_ url: URL) async {
        loading = true; error = nil
        let meta = await VideoMetadataReader.read(url)
        videoUrl = url
        videoMeta = meta
        // Video creation_time changes the alignment date and the ride window
        // bounds — re-slice the full sensor/GPS data, re-derive timestamps,
        // and re-run fusion on the slice.
        applyVideoAndSlice()
        // ALWAYS attempt auto-pick — fall back to the video file's mod date
        // when `creation_time` is missing (PhotosPicker drops it on some
        // re-encode paths). Without an unconditional run, picking a fresh
        // iPhone capture would silently leave the previous session's
        // sensor/gps loaded.
        let referenceMs = meta.creationTimeMillis ?? Self.fileModMillis(url)
        await autoPickMatchingCsvs(referenceMs: referenceMs)
        loading = false
    }

    private static func fileModMillis(_ url: URL) -> Int64 {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) else { return 0 }
        return Int64(d.timeIntervalSince1970 * 1000.0)
    }

    /// Pick the Sens* / Gps* CSV files that best match the just-picked
    /// video. Strategy: prefer **filename token overlap** (e.g. video
    /// `Ayano_Pump_25.4.2026_Ermioni.MOV` ↔ `Sens_ayano_25.4.2026.csv`
    /// share `ayano`, `25`, `4`, `2026`); fall back to mod-date proximity
    /// within ±7 days when no filename tokens match. The user's box
    /// recordings can be synced days after the actual session, so
    /// mod-date alone is unreliable as the primary signal.
    @MainActor
    private func autoPickMatchingCsvs(referenceMs: Int64) async {
        let recordings = listLocalRecordings()
        let videoDate = Date(timeIntervalSince1970: TimeInterval(referenceMs) / 1000.0)
        let videoTokens = Self.fileTokens(videoUrl?.lastPathComponent ?? "")

        func bestMatch(_ predicate: (String) -> Bool) -> URL? {
            let scored: [(url: URL, overlap: Int, dateDiff: TimeInterval)] =
                recordings
                .filter { predicate($0.lastPathComponent) }
                .map { url in
                    let toks = Self.fileTokens(url.lastPathComponent)
                    let overlap = videoTokens.intersection(toks).count
                    let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    return (url, overlap, abs(d.timeIntervalSince(videoDate)))
                }
            // Primary: highest filename token overlap.
            let tokenMatches = scored.filter { $0.overlap > 0 }
            if !tokenMatches.isEmpty {
                return tokenMatches.max { a, b in
                    if a.overlap != b.overlap { return a.overlap < b.overlap }
                    return a.dateDiff > b.dateDiff   // smaller diff wins → reverse
                }?.url
            }
            // Fallback: closest mod date within ±7 days. Without this,
            // numeric-only filenames (Sens001.csv) get no match at all.
            let dateMatches = scored.filter { $0.dateDiff < 7 * 86400 }
            return dateMatches.min(by: { $0.dateDiff < $1.dateDiff })?.url
        }

        // ---- Tier 1 (most reliable): true wall-clock coverage. A file whose
        // firmware `# SYNC` markers prove the recording spans the video's
        // timestamp IS the session the video belongs to — no filename
        // guessing. `wallClockCoverage` maps the file's first/last row tick
        // to absolute epoch via its anchors.
        let coverageTolMs: Int64 = 5 * 60 * 1000   // 5 min slack at the edges
        func coverageMatch(_ predicate: (String) -> Bool) -> URL? {
            let scored = recordings
                .filter { predicate($0.lastPathComponent) }
                .compactMap { url -> (url: URL, dist: Int64)? in
                    guard let cov = Self.wallClockCoverage(url) else { return nil }
                    guard referenceMs >= cov.start - coverageTolMs,
                          referenceMs <= cov.end + coverageTolMs else { return nil }
                    return (url, abs(referenceMs - (cov.start + cov.end) / 2))
                }
            return scored.min(by: { $0.dist < $1.dist })?.url
        }

        var sensorMatch = coverageMatch(Self.isSensCsv)
        var gpsMatch = coverageMatch(Self.isGpsCsv)
        let coverageHit = sensorMatch != nil || gpsMatch != nil

        // ---- Tier 2: numeric-suffix companion. On a real SD card the Sens
        // and Gps file of one session share their NNN (SENS002 ↔ GPS002 —
        // the desktop's canonical pairing rule). If one side matched by
        // coverage, pull its companion across even if the other side's own
        // coverage was inconclusive.
        if let s = sensorMatch, gpsMatch == nil {
            gpsMatch = companionBySessionNumber(of: s, recordings: recordings, predicate: Self.isGpsCsv)
        }
        if let g = gpsMatch, sensorMatch == nil {
            sensorMatch = companionBySessionNumber(of: g, recordings: recordings, predicate: Self.isSensCsv)
        }

        // ---- Tier 3 (fallback): filename token overlap, then ±7-day mod date.
        if sensorMatch == nil { sensorMatch = bestMatch(Self.isSensCsv) }
        if gpsMatch == nil { gpsMatch = bestMatch(Self.isGpsCsv) }

        var summaryBits: [String] = []
        if let s = sensorMatch, s != sensorFile {
            summaryBits.append("Sens → \(s.lastPathComponent)")
            await pickSensorCsv(s)
        } else if sensorMatch == nil {
            summaryBits.append("Sens: no match")
        }
        if let g = gpsMatch, g != gpsFile {
            summaryBits.append("GPS → \(g.lastPathComponent)")
            await pickGpsCsv(g)
        } else if gpsMatch == nil {
            summaryBits.append("GPS: no match")
        }
        let how = coverageHit ? " (by recorded time)" : ""
        autoPickSummary = summaryBits.isEmpty ? nil
            : "auto-pick\(how): " + summaryBits.joined(separator: " · ")
        // If neither auto-picked, fusion still needs to run for the
        // re-sliced data (existing sensor/GPS against the new ride window).
        if sensorMatch == nil && gpsMatch == nil {
            await maybeComputeFusion()
        }
    }

    private static func isSensCsv(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("._") { return false }
        return n.hasPrefix("sens") && n.hasSuffix(".csv")
    }

    private static func isGpsCsv(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("._") { return false }
        // Box-side `Gps*.csv` + iPhone-side `iPhoneGps_*.csv`.
        return (n.hasPrefix("gps") || n.hasPrefix("iphonegps")) && n.hasSuffix(".csv")
    }

    /// Lowercase the filename, strip the extension, split on common
    /// separators, drop generic tokens (`sens`, `gps`, …) so the
    /// remaining tokens are descriptive (name/date/location). Used by
    /// the video → CSV auto-match.
    private static func fileTokens(_ name: String) -> Set<String> {
        let lower = name.lowercased()
        let stem = (lower as NSString).deletingPathExtension
        let parts = stem
            .components(separatedBy: CharacterSet(charactersIn: "_- .,()[]{}/"))
            .filter { !$0.isEmpty }
        let skip: Set<String> = [
            "sens", "gps", "bat", "iphonegps", "mov", "csv", "mp4", "m4v",
            "img", "video", "log", "data", "ble"
        ]
        return Set(parts.filter { $0.count >= 2 && !skip.contains($0) })
    }

    /// The session number shared by a Sens/Gps pair on the SD card
    /// (`SENS002.CSV` / `GPS002.CSV` → `"002"`). nil for iPhone-GPS or
    /// otherwise un-numbered names.
    private static func sessionNumber(_ name: String) -> String? {
        let stem = ((name.lowercased()) as NSString).deletingPathExtension
        for p in ["sens", "gps", "bat"] where stem.hasPrefix(p) {
            let digits = stem.dropFirst(p.count).prefix(while: { $0.isNumber })
            if !digits.isEmpty { return String(digits) }
        }
        return nil
    }

    /// Find the `predicate`-matching recording that shares `url`'s session
    /// number — the companion of a matched file (SENS002 → GPS002).
    private func companionBySessionNumber(
        of url: URL, recordings: [URL], predicate: (String) -> Bool
    ) -> URL? {
        guard let num = Self.sessionNumber(url.lastPathComponent) else { return nil }
        return recordings.first {
            predicate($0.lastPathComponent) && Self.sessionNumber($0.lastPathComponent) == num
        }
    }

    /// Absolute wall-clock span of a recording, derived from its firmware
    /// `# SYNC` markers: map the first and last data-row tick to epoch ms
    /// through the file's anchors. nil when the file carries no markers
    /// (legacy / never-connected) — auto-pick then falls back to filename
    /// heuristics. Reads the file once; cheap enough for a one-shot pick.
    private static func wallClockCoverage(_ url: URL) -> (start: Int64, end: Int64)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let anchors = CsvParsers.parseSyncAnchors(text)
        guard !anchors.isEmpty else { return nil }

        var tickDiv = 10.0
        var sawHeader = false
        var firstTick: Double?
        var lastTick: Double?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r \t"))
            if line.isEmpty { continue }
            if !sawHeader {
                sawHeader = true
                if line.lowercased().contains("time [") { tickDiv = 1.0 }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let firstField = line.split(separator: ",", maxSplits: 1).first,
                  let ms = Double(firstField.trimmingCharacters(in: .whitespaces)) else { continue }
            let t = ms / tickDiv
            if firstTick == nil { firstTick = t }
            lastTick = t
        }
        guard let ft = firstTick, let lt = lastTick else { return nil }
        let ep = absTimesFromSyncAnchors(ticks: [ft, lt], anchors: anchors)
        guard ep.count == 2 else { return nil }
        return (min(ep[0], ep[1]), max(ep[0], ep[1]))
    }

    @MainActor
    func pickSensorCsv(_ url: URL) async {
        loading = true; error = nil
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

    /// Drop the loaded video and re-slice CSVs against the full session
    /// (no ride window). Used by the "Clear video" affordance when the
    /// picked clip doesn't overlap the loaded sensor / GPS dates.
    @MainActor
    func clearVideo() {
        videoUrl = nil
        videoMeta = nil
        applyVideoAndSlice()
        Task { await maybeComputeFusion() }
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

        // ----- Step 2: compute FULL-data abs UTC arrays. Crucially we
        // interpolate sensor abs times BEFORE slicing — so even when the
        // video window falls outside GPS coverage we can still slice
        // sensors by absolute time.
        //
        // PRIMARY source = the firmware's `# SYNC` markers (phone wall clock,
        // paired with the box tick on every connect). These are drift-free,
        // need no GPS fix, and live in the SAME clock domain as the video's
        // creation_time — so they remove the cross-clock skew that made the
        // old GPS-only path desync. They also make the alignment date
        // irrelevant (the anchor carries absolute epoch directly), sidestepping
        // the timezone / midnight-rollover fragility of hhmmss.ss.
        //
        // FALLBACK (legacy files / never-connected sessions) = the old
        // GPS-hhmmss.ss piecewise interpolation, or an all-zero array that
        // step 5 turns into a cursor sweep.
        if !gpsSyncAnchors.isEmpty {
            fullGpsAbsTimesMs = Self.absTimesFromSyncAnchors(
                ticks: fullGpsRows.map { $0.ticks }, anchors: gpsSyncAnchors)
        } else {
            fullGpsAbsTimesMs = fullGpsRows.map { row in
                GpsTime.toUtcMillis(
                    row.utc, year: date.year, month1to12: date.month, day: date.day
                ) ?? -1
            }
        }
        let usedSyncAnchors = !sensorSyncAnchors.isEmpty
        let fullSensorAbsTimesMs: [Int64]
        if usedSyncAnchors {
            fullSensorAbsTimesMs = Self.absTimesFromSyncAnchors(
                ticks: fullSensorRows.map { $0.ticks }, anchors: sensorSyncAnchors)
        } else {
            fullSensorAbsTimesMs = interpolateSensorAbsTimes(
                sensorRows: fullSensorRows, gpsRows: fullGpsRows,
                gpsAbsTimesMs: fullGpsAbsTimesMs
            )
        }

        // ----- Step 3: ride window slicing by ABSOLUTE TIME. Both sensor
        // and GPS arrays get sliced against [videoCreation, +duration]
        // independently — so different videos from the same session pick
        // out different sub-ranges of the sensor data.
        let summary: String?
        if let creation = videoMeta?.creationTimeMillis,
           videoMeta!.durationMillis > 0 {
            let rideStart = creation
            let rideEnd = creation + videoMeta!.durationMillis

            // Slice GPS
            let gs = firstIndexWhereTimeAtLeast(fullGpsAbsTimesMs, rideStart)
            let ge = firstIndexWhereTimeGreaterThan(fullGpsAbsTimesMs, rideEnd)
            let validGS = max(0, gs)
            let validGE = max(validGS, min(fullGpsRows.count, ge))
            gpsRows = Array(fullGpsRows[validGS..<validGE])
            gpsAbsTimesMs = Array(fullGpsAbsTimesMs[validGS..<validGE])
            speedSmoothedKmh = (fullSmoothedSpeed.count == fullGpsRows.count)
                ? Array(fullSmoothedSpeed[validGS..<validGE])
                : []

            // Slice sensor against abs UTC (extrapolated when needed).
            // When the video window falls entirely outside the GPS-covered
            // portion of the sensor session, the slice will be empty —
            // we fall back to showing the full session in step 4.
            let ss = firstIndexWhereTimeAtLeast(fullSensorAbsTimesMs, rideStart)
            let se = firstIndexWhereTimeGreaterThan(fullSensorAbsTimesMs, rideEnd)
            let validSS = max(0, ss)
            let validSE = max(validSS, min(fullSensorRows.count, se))
            sensorRows = Array(fullSensorRows[validSS..<validSE])
            sensorAbsTimesMs = Array(fullSensorAbsTimesMs[validSS..<validSE])

            let creationLocal = formatLocalTime(creation)
            let endLocal = formatLocalTime(rideEnd)
            let keptG = validGE - validGS
            let keptS = validSE - validSS
            var bits = "ride window: \(creationLocal) – \(endLocal) (sensor \(keptS) / gps \(keptG))"
            if keptS == 0 && !fullSensorRows.isEmpty {
                bits += " — video outside sensor coverage"
            }
            summary = bits
        } else {
            gpsRows = fullGpsRows
            gpsAbsTimesMs = fullGpsAbsTimesMs
            speedSmoothedKmh = fullSmoothedSpeed
            sensorRows = fullSensorRows
            sensorAbsTimesMs = fullSensorAbsTimesMs
            summary = nil
        }
        gpsAnchorUtcMillis = gpsAbsTimesMs.first(where: { $0 >= 0 })

        // ----- Step 4: empty-slice fallback. When the video window falls
        // outside the sensor's covered time (e.g. evening video against a
        // morning-only session), show the FULL session instead of nothing.
        // Both abs-time arrays get re-stretched in step 5 so the cursor
        // sweeps from 0% to 100% of the panel as the video plays.
        let usedFullSensorFallback = sensorRows.isEmpty && !fullSensorRows.isEmpty
        if usedFullSensorFallback {
            sensorRows = fullSensorRows
            sensorAbsTimesMs = fullSensorAbsTimesMs
        }
        let usedFullGpsFallback = gpsRows.isEmpty && !fullGpsRows.isEmpty
        if usedFullGpsFallback {
            gpsRows = fullGpsRows
            gpsAbsTimesMs = fullGpsAbsTimesMs
            speedSmoothedKmh = fullSmoothedSpeed
        }

        // ----- Step 5: cursor-sweep fallback. Apply when either:
        //   (a) sensorAbsTimesMs is all-zero — no GPS anchors at all, OR
        //   (b) we just fell back to the full session because the video
        //       window didn't overlap (abs times are real UTC values but
        //       way outside the [videoCreation, +duration] window, so the
        //       cursor target lands past the end and parks there).
        // Stretching the abs-time arrays across the video duration makes
        // the red cursor sweep cleanly from start to end in lock-step.
        let needsSensorStretch = !sensorRows.isEmpty
            && (sensorAbsTimesMs.allSatisfy({ $0 == 0 }) || usedFullSensorFallback)
        if needsSensorStretch {
            sensorAbsTimesMs = linearAbsTimes(
                count: sensorRows.count, durationMs: videoMeta?.durationMillis ?? 0,
                anchorMs: videoMeta?.creationTimeMillis ?? 0,
                baseTick: sensorRows.first?.ticks ?? 0,
                lastTick: sensorRows.last?.ticks ?? 0
            )
        }
        if usedFullGpsFallback {
            gpsAbsTimesMs = linearAbsTimes(
                count: gpsRows.count, durationMs: videoMeta?.durationMillis ?? 0,
                anchorMs: videoMeta?.creationTimeMillis ?? 0,
                baseTick: gpsRows.first?.ticks ?? 0,
                lastTick: gpsRows.last?.ticks ?? 0
            )
        }

        // ----- Honest alignment label. `needsSensorStretch` means we fell
        // back to the linear cursor-sweep (no real wall-clock correspondence)
        // — say so rather than pretend the cursor is exact.
        let approximate = needsSensorStretch
        if usedSyncAnchors || !gpsSyncAnchors.isEmpty {
            alignmentSource = approximate
                ? "Phone-clock sync — video outside session, approximate"
                : "Phone-clock sync — exact"
        } else if approximate {
            alignmentSource = "Approximate — no sync marker or GPS fix"
        } else {
            alignmentSource = "GPS-derived time"
        }

        rideSlicingSummary = summary
    }

    /// Map row ticks → absolute epoch ms through the firmware's host-clock
    /// `# SYNC` anchors. Piecewise-linear between anchors (drift-free when
    /// several connects produced markers across the session); constant
    /// 10 ms/tick extrapolation before the first / after the last anchor.
    /// A single anchor degenerates to a fixed 10 ms/tick offset from that
    /// one connect — still phone-clock-correct near the connect, only
    /// re-accumulating ThreadX drift far from it. `anchors` must be
    /// tick-sorted + deduped (as `CsvParsers.parseSyncAnchors` returns).
    static func absTimesFromSyncAnchors(ticks: [Double], anchors: [SyncAnchor]) -> [Int64] {
        let n = ticks.count
        guard n > 0, let first = anchors.first, let last = anchors.last else { return [] }
        var out = [Int64](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = ticks[i]
            if t <= first.ticks {
                out[i] = first.epochMs + Int64((t - first.ticks) * 10.0)
            } else if t >= last.ticks {
                out[i] = last.epochMs + Int64((t - last.ticks) * 10.0)
            } else {
                while j + 1 < anchors.count && anchors[j + 1].ticks <= t { j += 1 }
                let a = anchors[j], b = anchors[j + 1]
                let frac = (t - a.ticks) / (b.ticks - a.ticks)
                out[i] = Int64(Double(a.epochMs) + Double(b.epochMs - a.epochMs) * frac)
            }
        }
        return out
    }

    /// Build a linear abs-time array of `count` entries that spans the
    /// video's [creation, creation+duration] window — i.e. cursor moves
    /// from 0% to 100% of the panel as the video plays. Used as the
    /// cursor-sweep fallback when real UTC alignment is unavailable or
    /// outside the video window. Falls back to tick-based layout when
    /// the video has no duration.
    private func linearAbsTimes(
        count: Int, durationMs: Int64, anchorMs: Int64,
        baseTick: Double, lastTick: Double
    ) -> [Int64] {
        guard count > 0 else { return [] }
        if durationMs > 0 && count > 1 {
            let denom = Int64(count - 1)
            return (0..<count).map { i in
                anchorMs + (Int64(i) * durationMs) / denom
            }
        }
        // No video duration — at least keep relative ordering correct.
        let span = max(lastTick - baseTick, 1)
        let denom = Double(count - 1)
        return (0..<count).map { i in
            let t = Double(i) / denom
            return anchorMs + Int64(t * span * 10.0)
        }
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
        // Sensor-only is enough: pitch is pure IMU, and Baro has a
        // session-max-pressure fallback for empty GPS. The user explicitly
        // asked to render whatever data is available rather than refusing
        // when one stream is absent.
        guard !sensorRows.isEmpty else {
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
        // Allow export with ANY data series available — sensor-only or
        // GPS-only sessions still produce useful composites. The exporter
        // omits panels whose backing series are empty.
        let haveSensor = !sensorRows.isEmpty && !pitchDeg.isEmpty && !fusedHeightM.isEmpty
        let haveGps = !gpsRows.isEmpty && !speedSmoothedKmh.isEmpty
        guard haveSensor || haveGps else {
            error = "Load at least one of Sensor or GPS CSV before exporting"
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
