import Foundation
import Observation

/// Orchestrates one recording session and owns the box/GPS decision.
///
/// Rule (from the brief): if a box is connected, start a session **on the box**;
/// otherwise fall back to logging the **watch's own GPS** at 1 Hz. Either way a
/// workout session holds the app awake and the elapsed time is surfaced for the
/// UI to render.
@Observable
final class SessionController {

    enum Source: String, Equatable { case box = "Box", watchGPS = "Watch GPS" }
    enum Phase: Equatable { case idle, starting, running, stopping }

    let ble = BoxBleClient()
    let gps = WatchGpsLogger()
    let waterTemp = WaterTempManager()
    @ObservationIgnored private let keepAlive = WorkoutKeepAlive()

    private(set) var phase: Phase = .idle
    private(set) var source: Source? = nil
    /// Wall-clock instant the session started; `nil` when idle. The UI renders
    /// elapsed time from this via a `TimelineView`, so no timer lives here.
    private(set) var sessionStart: Date? = nil
    private(set) var message: String = ""

    var isRunning: Bool { phase == .running || phase == .starting }

    init() {
        ble.startScanning()
    }

    /// Line shown while idle: reflects whether a box will be used.
    var readiness: String {
        if ble.isConnected {
            return "Box ready" + (ble.boxName.map { " · \($0)" } ?? "")
        }
        switch ble.link {
        case .connecting, .scanning: return "Searching for box — Watch GPS ready"
        case .poweredOff:            return "Bluetooth off — Watch GPS ready"
        case .unavailable:           return "No box — Watch GPS ready"
        default:                     return "No box — Watch GPS ready"
        }
    }

    func toggle() {
        switch phase {
        case .idle:    start()
        case .running: stop()
        default:       break   // ignore taps mid-transition
        }
    }

    private func start() {
        guard phase == .idle else { return }
        keepAlive.begin()
        waterTemp.start()
        gps.waterTempProvider = { [weak self] in self?.waterTemp.temperatureC }
        sessionStart = Date()

        if ble.isConnected {
            source = .box
            phase = .starting
            message = "Starting box session…"
            ble.startLog { [weak self] ok in
                guard let self, self.phase == .starting else { return }
                if ok {
                    self.phase = .running
                    self.message = "Recording on box"
                } else {
                    // Couldn't start on the box — abort cleanly so the user can
                    // retry (they may prefer to move in range / power-cycle it).
                    self.message = "Box didn't start — try again"
                    self.abort()
                }
            }
        } else {
            source = .watchGPS
            phase = .running
            message = "Recording Watch GPS"
            gps.start()
        }
    }

    private func stop() {
        guard phase == .running || phase == .starting else { return }
        phase = .stopping
        switch source {
        case .box:
            ble.stopLog()
        case .watchGPS:
            gps.stop()
            // Sync this ride's CSV to the phone (queued; delivered even if the
            // iOS app isn't open).
            if let url = gps.csvURL { WatchSync.shared.send(csv: url) }
        case .none:
            break
        }
        finish()
        message = "Session ended"
    }

    /// Failure path from `start()`: undo the half-started session.
    private func abort() {
        gps.stop()
        finish()
    }

    private func finish() {
        keepAlive.end()
        waterTemp.stop()
        sessionStart = nil
        source = nil
        phase = .idle
    }
}
