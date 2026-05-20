import Foundation
import Observation

struct DiscoveredDevice: Identifiable, Equatable {
    let identifier: UUID
    let name: String
    let rssi: Int
    var id: UUID { identifier }
}

struct RemoteFile: Identifiable, Equatable {
    let name: String
    let size: Int64
    var id: String { name }
}

struct DownloadProgress: Equatable {
    let bytesDone: Int64
    let total: Int64
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(bytesDone) / Double(total)))
    }
}

enum ConnectionStatus { case disconnected, connecting, connected }

/// Sparkline sample for the Live tab. `tSec` is seconds since the first
/// sample of this connection (relative — the box has no RTC), `value` is
/// already in display units (g for acc magnitude, hPa for pressure).
struct LivePoint: Equatable {
    let tSec: Double
    let value: Double
}

/// Live SensorStream state. Cleared on disconnect.
struct LiveState: Equatable {
    var latestSample: LiveSample? = nil
    /// Wall-clock receive time for the latest sample. Drives the "x s ago"
    /// freshness label so a stalled stream becomes obvious.
    var latestSampleAt: Date? = nil
    var sampleCount: UInt64 = 0
    var accHistory: [LivePoint] = []
    var pressureHistory: [LivePoint] = []
    /// True iff the connected firmware exposed the SensorStream char.
    var streamCapable: Bool = false
}

/// In-flight LOG session on the box. Recorded optimistically when the user
/// taps Start session: the firmware reboots ~50 ms later so the BLE link
/// dies, and the box is invisible to Scan until `durationSeconds` elapses.
/// Used to render the countdown banner.
struct SessionRunning: Equatable {
    let startedAt: Date
    let durationSeconds: Int

    func remaining(at now: Date) -> TimeInterval {
        let deadline = startedAt.addingTimeInterval(TimeInterval(durationSeconds))
        return max(0, deadline.timeIntervalSince(now))
    }
}

@Observable
final class FileSyncViewModel {

    /// Process-wide instance. Used by both the SwiftUI views (via `MainNav`)
    /// and the background sync agent (`SyncTaskHandler`) so they drive the
    /// **same** `BleClient` — single source of truth, single CoreBluetooth
    /// central, single sync state machine. Mirrors Android's `FileSyncCore`
    /// singleton and the desktop's `AppState`. Constructed lazily but
    /// touched early from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// so the `CBCentralManager`'s restoration identifier is registered
    /// before iOS has a chance to deliver any restored state.
    static let shared = FileSyncViewModel()

    var connection: ConnectionStatus = .disconnected
    var scanning: Bool = false
    var discovered: [DiscoveredDevice] = []
    var files: [RemoteFile] = []
    var downloads: [String: DownloadProgress] = [:]
    var savedPaths: [String: String] = [:]
    /// Bytes already in the local mirror per file, refreshed on LIST and
    /// after each download. A file counts as fully downloaded (no more
    /// "Download" button) when its mirror size >= the box's size.
    var localBytes: [String: Int64] = [:]
    var listing: Bool = false
    /// "Sync now" in progress (LIST → diff → serial pull of new files).
    var syncing: Bool = false
    /// One-line sync result, mirrors the desktop status line
    /// ("Sync: 3 new, 12 already synced — downloading…" / "up to date").
    var syncStatus: String? = nil
    /// A DELETE the box rejected (BUSY / NOT_FOUND / IO_ERROR /
    /// BAD_REQUEST). Surfaced as a dismissable banner; cleared on a
    /// successful delete, a fresh attempt, or disconnect (desktop #7).
    var deleteError: String? = nil
    /// A transfer was cut by a link drop / stall; the partial is safe in
    /// the mirror. Drives the reconnect banner and the auto-resume on
    /// the next `.connected` (desktop v0.0.9). Persists across the
    /// disconnect on purpose.
    var transferInterrupted: Bool = false
    var log: [String] = []
    var sessionDurationSeconds: Int = 1800  // 30-min default, matches desktop
    var sessionRunning: SessionRunning? = nil
    var live: LiveState = LiveState()

    /// First-sample box-timestamp; sparkline X axis is
    /// `(s.timestampMs - liveT0Ms) / 1000`. Tracked outside `LiveState` so
    /// SwiftUI doesn't re-render when only this internal anchor changes.
    private var liveT0Ms: UInt32? = nil

    // ---- Sync-state (port of desktop sync_db.rs + issues #3/#4) ----
    /// Stable per-install id of the connected box (`CBPeripheral.identifier`).
    /// The DB partition key — sync history is per-box.
    private var connectedBoxId: String? = nil
    /// Opened once; nil only if SQLite itself failed (then sync degrades to
    /// "nothing is synced" rather than crashing the tab).
    private let syncDb: SyncDb? = SyncDb()
    /// Set by `syncNow()`, consumed by the next `.listDone` so the auto-LIST
    /// on connect never triggers a sync (mirrors the desktop's sync flag).
    private var syncPending: Bool = false
    /// Files this sync still has to pull, oldest-first; drained serially
    /// because the BLE worker is single-op (one READ at a time).
    private var syncQueue: [RemoteFile] = []
    /// Name of the file the *sync* is currently pulling (nil for a manual
    /// download), so `.readDone` knows whether to advance the queue.
    private var syncInFlight: String? = nil
    /// "Keep synced" continuous-mirror toggle + its 30 s poll loop
    /// (desktop v0.0.14). The pass only fetches each file's new tail.
    private(set) var keepSynced: Bool = false
    private var syncPollTask: Task<Void, Never>?

    /// Box log-mode: nil = unknown (not yet queried / legacy firmware
    /// that ignores GET_MODE), false = auto (logs on boot), true =
    /// manual (idle until START_LOG).
    private(set) var logModeManual: Bool? = nil
    private static let syncPollSeconds: UInt64 = 30

    private let ble: BleClient
    private var eventTask: Task<Void, Never>?

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// File log keeps the date too — one file spans many sessions/days.
    private let fileTsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// On-disk log in the same Documents folder as the downloaded
    /// recordings (visible in the Files app under On My iPhone →
    /// Movement Logger, survives app restarts).
    var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("movement_logger.log")
    }

    init(ble: BleClient = BleClient()) {
        self.ble = ble
        // Restore the user-visible toggle from AgentConfig so a cold-launch
        // shows the correct state. The 30 s in-process poll is only armed
        // by `setKeepSynced(true)`, so we route through that helper if it's
        // on — fires from the @MainActor init, which is fine.
        self.keepSynced = AgentConfig.keepSynced
        self.logModeManual = AgentConfig.logModeManual
        self.eventTask = Task { [weak self] in
            guard let stream = self?.ble.events else { return }
            for await event in stream {
                await self?.onEvent(event)
            }
        }
        if self.keepSynced {
            // Re-arm the in-process poll loop on cold launch.
            self.setKeepSynced(true)
        }
    }

    /// True iff anything is in flight from the foreground UI's perspective.
    /// The BG handler uses this to honour the "GUI wins, agent yields"
    /// policy (Android+desktop locked decision): when the user has the
    /// foreground BLE machine busy, the background task backs off so they
    /// don't fight for the single CoreBluetooth queue.
    var isBusy: Bool {
        connection != .disconnected || listing || syncing || !downloads.isEmpty
    }

    /// Connect by saved `CBPeripheral.identifier` — the BG handler path,
    /// which doesn't have a `DiscoveredDevice` because it hasn't scanned.
    /// `BleClient.connect` falls back to `central.retrievePeripherals` so
    /// this works after a relaunch without a fresh scan.
    func connect(identifier: UUID) {
        connection = .connecting
        logLine("connect (agent) \(identifier.uuidString)")
        ble.send(.connect(identifier: identifier))
    }

    deinit {
        eventTask?.cancel()
        syncPollTask?.cancel()
        ble.close()
    }

    // ---------------- UI intents ----------------------------------------------

    func scan() {
        scanning = true
        discovered = []
        logLine("scan…")
        ble.send(.scan)
    }

    func connect(_ device: DiscoveredDevice) {
        connection = .connecting
        logLine("connect \(device.identifier.uuidString)")
        ble.send(.connect(identifier: device.identifier))
    }

    func disconnect() {
        logLine("disconnect")
        ble.send(.disconnect)
    }

    func listFiles() {
        listing = true
        files = []
        logLine("LIST")
        ble.send(.list)
    }

    func download(_ file: RemoteFile) {
        // Live-mirror: resume/grow from whatever is already on disk. The
        // firmware seeks to `offset`, so an interrupted file continues
        // and a grown log only fetches its new tail (desktop v0.0.14).
        let offset = mirrorOffset(name: file.name, boxSize: file.size)
        if file.size > 0, offset >= file.size {
            logLine("\(file.name) already mirrored (\(file.size) B)")
            return
        }
        downloads[file.name] = DownloadProgress(bytesDone: offset, total: file.size)
        logLine("READ \(file.name) @\(offset)/\(file.size) B")
        ble.send(.read(name: file.name, size: file.size, offset: offset))
    }

    /// "Sync now" — pull every session file whose local mirror is behind
    /// the box. Port of the desktop Sync tab's distinct-from-manual
    /// transfer (issues #3, #14). Additive only: never issues DELETE.
    func syncNow() { startSyncPass(reason: "Sync now") }

    /// "Keep synced" — while connected and idle, re-run a sync pass every
    /// 30 s so a continuously-growing log keeps mirrored (desktop
    /// v0.0.14). The pass itself only fetches each file's new tail.
    ///
    /// Also persists the new state to `AgentConfig` and reschedules the
    /// `BGTaskScheduler` so the out-of-app agent gate flips immediately.
    func setKeepSynced(_ on: Bool) {
        keepSynced = on
        AgentConfig.keepSynced = on
        BackgroundSync.refresh()
        logLine("Keep synced \(on ? "on" : "off")")
        syncPollTask?.cancel()
        syncPollTask = nil
        guard on else { return }
        syncPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.syncPollSeconds))
                guard let self, !Task.isCancelled else { return }
                await self.keepSyncedTick()
            }
        }
    }

    @MainActor
    private func keepSyncedTick() {
        guard keepSynced, connection == .connected,
              !listing, !syncing, downloads.isEmpty, syncInFlight == nil
        else { return }
        startSyncPass(reason: "Keep synced")
    }

    /// Begin one sync pass: fresh LIST, then the diff runs in the
    /// `.listDone` handler (gated on `syncPending` so the auto-LIST on
    /// connect never starts a sync by itself). Shared by the button and
    /// the continuous loop (desktop `start_sync_pass`).
    private func startSyncPass(reason: String) {
        guard connection == .connected else { return }
        guard connectedBoxId != nil else {
            syncStatus = "Sync: no box id (reconnect and retry)"
            return
        }
        syncing = true
        syncPending = true
        syncQueue = []
        syncInFlight = nil
        syncStatus = "Sync: listing SD card…"
        files = []
        listing = true
        logLine("\(reason) — LIST")
        ble.send(.list)
    }

    /// Session-data filter — same predicate as the Sync tab's grouping and
    /// the desktop's auto-sync set (Sens/Gps/Bat/Mic; AppleDouble excluded).
    /// Only these are auto-pulled by `syncNow`; FW_INFO / CHK / error logs
    /// stay manual-only.
    static func isSensorData(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("._") { return false }
        return (n.hasPrefix("sens") && n.hasSuffix(".csv")) ||
               (n.hasPrefix("gps")  && n.hasSuffix(".csv")) ||
               (n.hasPrefix("bat")  && n.hasSuffix(".csv")) ||
               (n.hasPrefix("mic")  && n.hasSuffix(".wav"))
    }

    func delete(_ file: RemoteFile) {
        deleteError = nil  // clear a stale rejection on a fresh attempt
        logLine("DELETE \(file.name)")
        ble.send(.delete(name: file.name))
    }

    func stopLog() {
        logLine("STOP_LOG")
        ble.send(.stopLog)
    }

    func setSessionDuration(_ seconds: Int) {
        sessionDurationSeconds = min(86_400, max(1, seconds))
    }

    func startSession() {
        let dur = sessionDurationSeconds
        // Current firmware does not reboot on START_LOG — it opens a
        // session and auto-stops after `dur` s, the link stays up. Only
        // meaningful in manual mode (in auto the box already logs).
        logLine("START_LOG \(dur) s")
        ble.send(.startLog(durationSeconds: dur))
        sessionRunning = SessionRunning(startedAt: Date(), durationSeconds: dur)
    }

    /// Persist the box log-mode and remember it locally.
    func setLogMode(_ manual: Bool) {
        logLine("SET_MODE \(manual ? "manual" : "auto")")
        ble.send(.setLogMode(manual: manual))
    }

    func clearSession() {
        if sessionRunning != nil {
            logLine("LOG session duration reached — box is idle again (manual mode)")
            sessionRunning = nil
        }
    }

    // ---------------- Event handling ------------------------------------------

    @MainActor
    private func onEvent(_ e: BleEvent) {
        switch e {
        case .status(let msg): logLine(msg)
        case .error(let msg):
            logLine("ERROR: \(msg)")
            // Surface DELETE rejections prominently — the box refuses
            // some Debug rows (8.3-name miss → NOT_FOUND, >15 chars →
            // BAD_REQUEST, logging active → BUSY). Without this it only
            // hits the log and looks like the tap did nothing (#7).
            if msg.hasPrefix("DELETE ") {
                deleteError = msg
            }
            // A BLE error mid-sync would otherwise strand the queue
            // (syncInFlight never clears). Abort cleanly so the next
            // "Sync now" starts fresh; the size key means a partial
            // file is just re-pulled next time (desktop-equivalent).
            if syncing {
                syncing = false
                syncPending = false
                syncQueue = []
                syncInFlight = nil
                // A resumable interruption (readAborted already fired)
                // keeps its own resume message + banner — don't stomp
                // it with "try again".
                if !transferInterrupted {
                    syncStatus = "Sync aborted (BLE error) — try again"
                }
            }
        case .discovered(let id, let name, let rssi):
            if !discovered.contains(where: { $0.identifier == id }) {
                discovered.append(DiscoveredDevice(identifier: id, name: name, rssi: rssi))
            }
        case .scanStopped:
            scanning = false
            logLine("scan stopped (\(discovered.count) found)")
        case .connected(let boxId):
            connection = .connected
            connectedBoxId = boxId.isEmpty ? nil : boxId
            // Persist the box id for the background agent so it can
            // reconnect after the app has been suspended/terminated.
            // BG schedule may flip live → refresh either way.
            if let bid = connectedBoxId { AgentConfig.boxId = bid }
            BackgroundSync.refresh()
            logLine("connected")
            // Ask the box which log-mode it's in so the UI toggle
            // reflects reality. Legacy PumpTsueri ignores 0x07 (no
            // reply) — the toggle just stays at its last/unknown state.
            ble.send(.getLogMode)
            // Resume after an interrupted transfer (desktop v0.0.9): the
            // aborted partial is already in the mirror, so a fresh sync
            // pass skips every complete file and re-pulls only the
            // unfinished one from its mirror offset. Also resume if
            // "Keep synced" is on. A plain first connect does neither.
            if transferInterrupted || keepSynced {
                let why = transferInterrupted ? "Resume" : "Keep synced"
                transferInterrupted = false
                startSyncPass(reason: why)
            }
        case .disconnected:
            connection = .disconnected
            connectedBoxId = nil
            deleteError = nil
            syncing = false
            syncPending = false
            syncQueue = []
            syncInFlight = nil
            // Keep the "Keep synced" toggle + poll task alive across a
            // disconnect — its tick guards on `.connected`, so it simply
            // resumes after a reconnect (sets up Stage 3 auto-resume).
            files = []
            listing = false
            downloads = [:]
            // Drop the live-stream buffers so a stale sparkline doesn't
            // masquerade as a live stream on reconnect (the box restarts
            // its monotonic timestamp axis on reboot).
            live = LiveState()
            liveT0Ms = nil
            logLine("disconnected")
        case .listEntry(let name, let size):
            files.append(RemoteFile(name: name, size: size))
        case .listDone:
            listing = false
            // Refresh per-file mirror sizes so the UI knows which files
            // are already fully downloaded (survives app restart).
            localBytes = Dictionary(
                uniqueKeysWithValues: files.map { ($0.name, mirrorLocalSize(name: $0.name)) })
            logLine("LIST done (\(files.count) files)")
            if syncPending {
                syncPending = false
                runSyncDiff()
            }
        case .readStarted:
            break
        case .readProgress(let name, let bytesDone):
            if let cur = downloads[name] {
                downloads[name] = DownloadProgress(bytesDone: bytesDone, total: cur.total)
            }
        case .readDone(let name, let content, let base):
            // Append the streamed segment into the local mirror at the
            // resume offset (desktop v0.0.14). The mirror file *is* the
            // saved download — always a valid prefix of the box file.
            let (path, localSize) = appendMirror(name: name, base: base, bytes: content)
            downloads.removeValue(forKey: name)
            savedPaths[name] = path
            localBytes[name] = localSize
            logLine("saved \(name) → \(path) (\(localSize) B)")
            // DB is an audit log now (not the fetch decision): record
            // that this file reached this size, saved here.
            if path != "<save failed>", let box = connectedBoxId {
                syncDb?.markSynced(boxId: box, name: name,
                                   size: localSize, localPath: path)
            }
            // If this file was pulled by the sync queue, advance it.
            if syncInFlight == name {
                syncInFlight = nil
                pumpSyncQueue()
            }
        case .readAborted(let name, let content, let base):
            // Link dropped / stalled mid-file. Persist the partial into
            // the mirror so the resume continues from the *true* break
            // point (desktop v0.0.9). NOT markSynced — it's incomplete;
            // the next sync pass re-pulls only the remaining tail via
            // mirrorOffset. The `.error` that follows clears the queue.
            let (_, have) = appendMirror(name: name, base: base, bytes: content)
            downloads.removeValue(forKey: name)
            syncInFlight = nil
            transferInterrupted = true
            syncStatus = "Transfer interrupted — reconnect to resume " +
                "(\(have) B of \(name) kept)"
            logLine("kept \(have) B of \(name) for resume")
        case .deleteDone(let name):
            files.removeAll { $0.name == name }
            deleteError = nil
            logLine("deleted \(name)")
        case .logMode(let manual):
            logModeManual = manual
            // Persist + reschedule — the gating policy is sensitive to
            // MANUAL (which disables BG sync).
            AgentConfig.logModeManual = manual
            BackgroundSync.refresh()
            logLine("box log mode: \(manual ? "manual" : "auto")")
        case .sample(let s):
            onSample(s)
        }
    }

    private func onSample(_ s: LiveSample) {
        let t0 = liveT0Ms ?? s.timestampMs
        if liveT0Ms == nil { liveT0Ms = t0 }
        let dt = Double(s.timestampMs &- t0) / 1000.0
        var acc = live.accHistory
        var pres = live.pressureHistory
        acc.append(LivePoint(tSec: dt, value: s.accMagnitudeG()))
        pres.append(LivePoint(tSec: dt, value: Double(s.pressurePa) / 100.0))
        if acc.count > Self.liveHistoryLen { acc.removeFirst(acc.count - Self.liveHistoryLen) }
        if pres.count > Self.liveHistoryLen { pres.removeFirst(pres.count - Self.liveHistoryLen) }
        live = LiveState(
            latestSample: s,
            latestSampleAt: Date(),
            sampleCount: live.sampleCount &+ 1,
            accHistory: acc,
            pressureHistory: pres,
            streamCapable: true
        )
    }

    /// Decide what to fetch by **local mirror size vs box size**, not a
    /// DB lookup (desktop v0.0.14). That's what makes a continuously-
    /// growing log work: each pass fetches only the new tail (offset =
    /// local size) instead of re-pulling the whole file, so no single
    /// big file can starve GPS/BAT in the serial queue either. The
    /// SQLite DB is now an audit log, not the fetch decision.
    @MainActor
    private func runSyncDiff() {
        let candidates = files.filter { Self.isSensorData($0.name) }
        var fetch: [RemoteFile] = []
        var upToDate = 0
        for f in candidates {
            // local < box → grow/resume; local > box → rotated
            // (mirrorOffset resets it). Either way, fetch.
            if mirrorLocalSize(name: f.name) == f.size {
                upToDate += 1
            } else {
                fetch.append(f)
            }
        }
        if fetch.isEmpty {
            syncing = false
            syncStatus = "Sync: up to date (\(upToDate) files)"
            logLine("Sync: up to date — \(upToDate) files")
            return
        }
        syncQueue = fetch
        syncStatus = "Sync: fetching \(fetch.count) (\(upToDate) up to date)…"
        logLine("Sync: fetching \(fetch.count), \(upToDate) up to date")
        pumpSyncQueue()
    }

    /// Pull the next queued file. The BLE worker is single-op, so sync
    /// downloads must be strictly serial — the next READ is only issued
    /// from `.readDone` of the previous one.
    @MainActor
    private func pumpSyncQueue() {
        guard !syncQueue.isEmpty else {
            if syncing {
                syncing = false
                syncStatus = "Sync: complete"
                logLine("Sync: complete")
            }
            return
        }
        let next = syncQueue.removeFirst()
        syncInFlight = next.name
        download(next)
    }

    // ---------------- Live mirror (desktop v0.0.14) ---------------------------
    //
    // The local file `Documents/<name>` *is* the running mirror — we
    // accumulate straight into it (no `.part`/rename). The box's logs grow
    // continuously, so "done" is a moving target; what matters is the local
    // file is always a valid prefix and we only fetch bytes we don't have.
    // Local size is the single source of truth for the resume/grow offset —
    // survives an app restart, a dropped link, and "grew since last sync"
    // identically. The DB is a separate audit log.

    private func mirrorURL(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(name)
    }

    /// Current local mirror length, 0 if absent.
    private func mirrorLocalSize(name: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: mirrorURL(name).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Resume offset given the box's current size:
    /// missing → 0; local ≤ box → local (resume/grow); local > box → the
    /// file rotated (name reused, box file shorter) → drop local, 0.
    private func mirrorOffset(name: String, boxSize: Int64) -> Int64 {
        let url = mirrorURL(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let len = (attrs[.size] as? NSNumber)?.int64Value else { return 0 }
        if len <= boxSize { return len }
        try? FileManager.default.removeItem(at: url)   // rotated/stale
        return 0
    }

    /// Append a streamed segment at `base` (creating the file). If the
    /// file length doesn't match `base` the resume is misaligned —
    /// realign to `base` so we never interleave a corrupt prefix.
    /// Returns (path, new local size).
    private func appendMirror(name: String, base: Int64, bytes: Data) -> (String, Int64) {
        let url = mirrorURL(name)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let cur = Int64((try? handle.seekToEnd()) ?? 0)
            if cur != base {
                try handle.truncate(atOffset: UInt64(max(0, min(base, cur))))
            }
            try handle.seekToEnd()
            handle.write(bytes)
            let newSize = Int64((try? handle.offset()) ?? UInt64(base) + UInt64(bytes.count))
            return (url.path, newSize)
        } catch {
            logLine("ERROR: mirror \(name): \(error.localizedDescription)")
            return ("<save failed>", base + Int64(bytes.count))
        }
    }

    private func logLine(_ msg: String) {
        let now = Date()
        let stamp = tsFormatter.string(from: now)
        var next = log
        next.append("\(stamp)  \(msg)")
        if next.count > Self.maxLogLines {
            next.removeFirst(next.count - Self.maxLogLines)
        }
        log = next
        appendLogFile(stamp: fileTsFormatter.string(from: now), msg: msg)
    }

    /// Persist every log line to `movement_logger.log`. Append-only with a
    /// soft size cap: past `maxLogFileBytes` it's rotated to `.1` so it
    /// can't grow forever. Logging must never crash the app, so all IO
    /// errors are swallowed (a full disk just means no on-disk copy).
    private func appendLogFile(stamp: String, msg: String) {
        let url = logFileURL
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           size > Self.maxLogFileBytes {
            let bak = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".1")
            try? fm.removeItem(at: bak)
            try? fm.moveItem(at: url, to: bak)
        }
        guard let data = "\(stamp)  \(msg)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let maxLogLines = 200
    /// Rotate the on-disk log past this size (1 MiB ≈ tens of sessions).
    private static let maxLogFileBytes: Int64 = 1 * 1024 * 1024
    /// Bounded rolling buffer for the Live tab sparklines. 120 × 2 s = 4 min. */
    private static let liveHistoryLen = 120
}
