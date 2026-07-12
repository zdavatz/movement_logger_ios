import Foundation
import Observation
import WatchKit

/// Orchestrates one recording session and owns the box/GPS decision.
///
/// Rule (from the brief): if a box is connected, start a session **on the box**;
/// otherwise fall back to logging the **watch's own GPS** at 1 Hz. Either way a
/// workout session holds the app awake and the elapsed time is surfaced for the
/// UI to render.
@Observable
final class SessionController {

    /// The single app-wide controller. Shared so the Action-button / Siri
    /// `AppIntent` (`ToggleSessionIntent`) drives the SAME session the UI shows
    /// — a hardware-button press and an on-screen tap must not create two
    /// separate controllers. The SwiftUI `App` binds to this instance too.
    static let shared = SessionController()

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

    /// True while a session is meant to hold **Water Lock**. The app's scene
    /// (re-)calls `engageWaterLockIfNeeded()` whenever it becomes frontmost, and
    /// the workout session calls it when it reaches `.running`. Both triggers
    /// exist because `WKInterfaceDevice.enableWaterLock()` silently does nothing
    /// unless the app is frontmost — and on an Action-button launch the workout
    /// often reaches `.running` *before* the app is active (auth already
    /// granted → no delay), which is why Water Lock used to be skipped and a
    /// wet-screen tap could hit "End Session" mid-ride.
    @ObservationIgnored private var wantsWaterLock = false

    var isRunning: Bool { phase == .running || phase == .starting }

    init() {
        ble.startScanning()
        keepAlive.onSessionRunning = { [weak self] in self?.engageWaterLockIfNeeded() }
    }

    /// Engage Water Lock if a session wants it. Safe to call repeatedly and from
    /// either trigger — a redundant call while already locked is a no-op, and a
    /// call while the app isn't frontmost is a no-op too (which is exactly why
    /// we retry on scene-active). The `enableWaterLock()` call is marshalled to
    /// the main thread (it's a UI operation). No effect on non-Ultra hardware
    /// beyond the standard touchscreen lock.
    func engageWaterLockIfNeeded() {
        guard wantsWaterLock else { return }
        DispatchQueue.main.async { WKInterfaceDevice.current().enableWaterLock() }
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

    /// Entry point for the Action-button workout intent (`BeginSessionIntent`):
    /// begin a session if idle, otherwise leave the running one alone (a stray
    /// second press must never end a ride mid-water). Ending stays on-screen /
    /// Siri.
    @MainActor
    func startFromActionButton() {
        if phase == .idle { start() }
    }

    private func start() {
        guard phase == .idle else { return }
        wantsWaterLock = true      // engaged once the workout runs / app is frontmost
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
        wantsWaterLock = false
        keepAlive.end()
        waterTemp.stop()
        sessionStart = nil
        source = nil
        phase = .idle
    }
}
