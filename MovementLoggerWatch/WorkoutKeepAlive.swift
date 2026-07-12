import Foundation
import HealthKit
import WatchKit

/// Holds an `HKWorkoutSession` for the lifetime of a logging session. On
/// watchOS this does two things this app needs:
///  - keeps the app **foreground / running** during a session (so the duration
///    readout, BLE link and 1 Hz GPS timer stay alive even with the wrist down);
///  - provides the workout context required to engage **Water Lock**, which we
///    turn on once the session is running so wet-screen taps don't register
///    (it's a water sport — pump foiling). The user turns the Digital Crown to
///    unlock + eject water when ending the session.
///
/// Degrades gracefully: if HealthKit is unavailable or the user declines, the
/// session still records in the foreground; it just won't hold Water Lock or
/// survive backgrounding. Nothing is written to the Health store.
final class WorkoutKeepAlive: NSObject, HKWorkoutSessionDelegate {

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    /// Invoked on the main thread each time the workout session enters the
    /// `.running` state. `SessionController` uses it to (re-)engage Water Lock.
    /// Water Lock lives on the controller, not here, because `enableWaterLock()`
    /// is a no-op unless the app is frontmost — so it needs a second trigger
    /// (scene-active) that this class doesn't observe.
    var onSessionRunning: (() -> Void)?

    /// Request authorization (once) and start the runtime-holding session.
    func begin() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { [weak self] _, _ in
            // Start regardless of the grant result: on watchOS an ungranted
            // workout session still provides foreground runtime, and the
            // prompt only needs to be answered once.
            DispatchQueue.main.async { self?.startSession() }
        }
    }

    private func startSession() {
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .paddleSports   // water sport → foreground + Water Lock
        config.locationType = .outdoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            s.delegate = self
            s.startActivity(with: Date())
            session = s
        } catch {
            session = nil
        }
    }

    func end() {
        session?.end()
        session = nil
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        // Once the session is actually running, ask the controller to engage
        // Water Lock (touchscreen guard against wet-screen taps). Must run on
        // the main thread; delegate callbacks may arrive off-main. This is one
        // of two triggers — the app may not be frontmost yet on an
        // Action-button launch, so the controller also re-tries on scene-active.
        if toState == .running {
            DispatchQueue.main.async { [weak self] in
                self?.onSessionRunning?()
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}
