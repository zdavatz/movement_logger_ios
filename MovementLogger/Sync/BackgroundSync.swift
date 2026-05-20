import Foundation
import BackgroundTasks
import os.log

/// `BGTaskScheduler` facade for the background sync agent.
///
/// iOS lookalike of Android's `sync/BackgroundSync.kt` (WorkManager) and the
/// desktop's `--agent` LaunchAgent / `.desktop` / Registry. The cadence is
/// **opportunistic** — iOS schedules `BGAppRefreshTask` when it sees fit (no
/// 15-min guarantee, no firing at all if the user never opens the app, no
/// firing while the device is in Low Power Mode). The more reliable wake-up
/// path is CoreBluetooth state restoration in `BleClient`, which fires
/// whenever the known box reconnects in range. The two layers complement
/// each other:
///
///   - Restoration: "box came back into range → wake me up and resume."
///   - BGAppRefresh: "every once in a while, check if there's anything to
///                     pull even if the box hasn't moved."
///
/// Gating is locked (mirrors Android/desktop): `AgentConfig.active`.
enum BackgroundSync {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "ch.pumptsueri.movementlogger.sync"

    /// 15-min hint — Apple treats this as "no sooner than" and may delay
    /// arbitrarily. Mirrors the Android WorkManager interval, but iOS
    /// owns the actual cadence.
    private static let earliestBeginInterval: TimeInterval = 15 * 60

    private static let log = Logger(subsystem: "ch.pumptsueri.movementlogger",
                                    category: "background-sync")

    /// Register the BGAppRefresh task handler with iOS.
    ///
    /// **Must be called from `application(_:didFinishLaunchingWithOptions:)`
    /// BEFORE that method returns** — iOS drops late-registered identifiers
    /// and the handler will never fire.
    static func register() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            SyncTaskHandler.handle(refresh)
        }
        if !registered {
            log.error("BGTaskScheduler.register returned false for \(taskIdentifier, privacy: .public) — check Info.plist BGTaskSchedulerPermittedIdentifiers")
        }
    }

    /// Submit (or cancel) the next BG refresh based on `AgentConfig.active`.
    /// Idempotent — call from any state change that might flip the gate.
    static func refresh() {
        if AgentConfig.active {
            schedule()
        } else {
            cancel()
        }
    }

    /// Submit a fresh request. Replaces any previously-scheduled instance
    /// with the same identifier (iOS only ever keeps the latest).
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginInterval)
        do {
            try BGTaskScheduler.shared.submit(req)
            log.info("scheduled next BG refresh ≥ \(Int(earliestBeginInterval), privacy: .public) s from now")
        } catch {
            log.error("BG submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        log.info("cancelled scheduled BG refresh")
    }
}
