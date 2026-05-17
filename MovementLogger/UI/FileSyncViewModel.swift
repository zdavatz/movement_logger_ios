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

    var connection: ConnectionStatus = .disconnected
    var scanning: Bool = false
    var discovered: [DiscoveredDevice] = []
    var files: [RemoteFile] = []
    var downloads: [String: DownloadProgress] = [:]
    var savedPaths: [String: String] = [:]
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
    /// LIST-reported size per in-flight download. The sync DB key is
    /// `(box, name, size)` and `size` must be the LIST size (matches what a
    /// later `isSynced` check compares against), not the received byte
    /// count — so we stash it at download-issue time.
    private var pendingSizes: [String: Int64] = [:]

    private let ble: BleClient
    private var eventTask: Task<Void, Never>?

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(ble: BleClient = BleClient()) {
        self.ble = ble
        self.eventTask = Task { [weak self] in
            guard let stream = self?.ble.events else { return }
            for await event in stream {
                await self?.onEvent(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
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
        downloads[file.name] = DownloadProgress(bytesDone: 0, total: file.size)
        pendingSizes[file.name] = file.size
        logLine("READ \(file.name) (\(file.size) B)")
        ble.send(.read(name: file.name, size: file.size))
    }

    /// "Sync now" — pull every session file on the box that isn't already
    /// recorded locally, and remember what was pulled. Port of the desktop
    /// Sync tab's distinct-from-manual-transfer button (issue #3).
    /// Additive only: never issues DELETE.
    func syncNow() {
        guard connection == .connected else { return }
        guard connectedBoxId != nil, syncDb != nil else {
            logLine("ERROR: sync DB unavailable — sync disabled")
            syncStatus = "Sync unavailable (no local DB)"
            return
        }
        syncing = true
        syncPending = true
        syncQueue = []
        syncInFlight = nil
        syncStatus = "Sync: listing…"
        files = []
        listing = true
        logLine("Sync now — LIST")
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
        logLine("START_LOG \(dur) s — box rebooting to LOG mode")
        ble.send(.startLog(durationSeconds: dur))
        // Firmware NVIC_SystemReset's ~50 ms after START_LOG, so the BLE link
        // dies abruptly without LL_TERMINATE_IND. Send an explicit Disconnect
        // right after to tear down host state proactively; either way the
        // worker ends up Idle.
        ble.send(.disconnect)
        sessionRunning = SessionRunning(startedAt: Date(), durationSeconds: dur)
        files = []
        downloads = [:]
        listing = false
    }

    func clearSession() {
        if sessionRunning != nil {
            logLine("LOG session deadline reached — box should be advertising again")
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
                syncStatus = "Sync aborted (BLE error) — try again"
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
            logLine("connected")
        case .disconnected:
            connection = .disconnected
            connectedBoxId = nil
            deleteError = nil
            syncing = false
            syncPending = false
            syncQueue = []
            syncInFlight = nil
            pendingSizes = [:]
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
        case .readDone(let name, let content):
            let path = saveFile(name: name, bytes: content)
            downloads.removeValue(forKey: name)
            savedPaths[name] = path
            logLine("saved \(name) → \(path)")
            // Register every successful save — manual *and* sync-driven —
            // so a later "Sync now" skips it regardless of how it landed
            // (desktop: "Manual downloads also register in the DB").
            let size = pendingSizes.removeValue(forKey: name)
                ?? Int64(content.count)
            if path != "<save failed>", let box = connectedBoxId {
                syncDb?.markSynced(boxId: box, name: name, size: size,
                                   localPath: path)
            }
            // If this file was pulled by the sync queue, advance it.
            if syncInFlight == name {
                syncInFlight = nil
                pumpSyncQueue()
            }
        case .deleteDone(let name):
            files.removeAll { $0.name == name }
            deleteError = nil
            logLine("deleted \(name)")
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

    /// Diff the just-LISTed files against the sync DB and enqueue the
    /// session files we haven't pulled. Mirrors the desktop's `ListDone`
    /// sync handler: filter to session data, skip anything `isSynced`,
    /// enqueue the rest onto the existing serial download path.
    @MainActor
    private func runSyncDiff() {
        guard let box = connectedBoxId, let db = syncDb else {
            syncing = false
            syncStatus = "Sync unavailable (no local DB)"
            return
        }
        let candidates = files.filter { Self.isSensorData($0.name) }
        let fresh = candidates.filter { !db.isSynced(boxId: box, name: $0.name, size: $0.size) }
        let already = candidates.count - fresh.count
        if fresh.isEmpty {
            syncing = false
            syncStatus = "Sync: up to date (\(already) already synced)"
            logLine("Sync: up to date — \(already) already synced, 0 new")
            return
        }
        syncQueue = fresh
        syncStatus = "Sync: \(fresh.count) new, \(already) already synced — downloading…"
        logLine("Sync: \(fresh.count) new, \(already) already synced — downloading")
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

    private func saveFile(name: String, bytes: Data) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = docs.appendingPathComponent(name)
        do {
            try bytes.write(to: url, options: .atomic)
            return url.path
        } catch {
            logLine("ERROR: save \(name): \(error.localizedDescription)")
            return "<save failed>"
        }
    }

    private func logLine(_ msg: String) {
        let stamp = tsFormatter.string(from: Date())
        var next = log
        next.append("\(stamp)  \(msg)")
        if next.count > Self.maxLogLines {
            next.removeFirst(next.count - Self.maxLogLines)
        }
        log = next
    }

    private static let maxLogLines = 200
    /// Bounded rolling buffer for the Live tab sparklines. 120 × 2 s = 4 min. */
    private static let liveHistoryLen = 120
}
