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
    var log: [String] = []
    var sessionDurationSeconds: Int = 1800  // 30-min default, matches desktop
    var sessionRunning: SessionRunning? = nil

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
        logLine("READ \(file.name) (\(file.size) B)")
        ble.send(.read(name: file.name, size: file.size))
    }

    func delete(_ file: RemoteFile) {
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
        case .error(let msg): logLine("ERROR: \(msg)")
        case .discovered(let id, let name, let rssi):
            if !discovered.contains(where: { $0.identifier == id }) {
                discovered.append(DiscoveredDevice(identifier: id, name: name, rssi: rssi))
            }
        case .scanStopped:
            scanning = false
            logLine("scan stopped (\(discovered.count) found)")
        case .connected:
            connection = .connected
            logLine("connected")
        case .disconnected:
            connection = .disconnected
            files = []
            listing = false
            downloads = [:]
            logLine("disconnected")
        case .listEntry(let name, let size):
            files.append(RemoteFile(name: name, size: size))
        case .listDone:
            listing = false
            logLine("LIST done (\(files.count) files)")
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
        case .deleteDone(let name):
            files.removeAll { $0.name == name }
            logLine("deleted \(name)")
        }
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
}
