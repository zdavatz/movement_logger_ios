import Foundation
import HealthKit

/// Holds an `HKWorkoutSession` for the lifetime of a logging session so watchOS
/// keeps the app running after the wrist lowers — otherwise the app is
/// suspended within seconds and both the BLE link and the 1 Hz GPS timer stop.
///
/// Degrades gracefully: if HealthKit is unavailable or the user declines the
/// prompt, the session still records while the app is in the foreground; it
/// just won't survive backgrounding. The workout is used purely for runtime —
/// nothing is written to the Health store.
final class WorkoutKeepAlive: NSObject, HKWorkoutSessionDelegate {

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

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
        config.activityType = .other
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

    // MARK: - HKWorkoutSessionDelegate (required, unused)

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}
