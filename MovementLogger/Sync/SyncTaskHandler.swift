import Foundation
import BackgroundTasks
import os.log

/// Body of one `BGAppRefreshTask` slot.
///
/// Coordinates with the foreground UI via the shared `FileSyncViewModel.shared`
/// — same `BleClient`, single source of truth. Flow:
///
///   1. Reschedule the next BG refresh first (so the loop self-perpetuates
///      even if we error / time out).
///   2. Gate on `AgentConfig.active` (keepSynced + boxId + !manual).
///   3. **GUI wins**: if the foreground app already has a BLE op in flight,
///      yield — the user's already doing it.
///   4. Connect to the saved box, kick a `syncNow()` pass, wait until the
///      pass reports complete OR the slot runs out.
///   5. Disconnect, complete the task.
///
/// iOS gives ~30 s for a BGAppRefreshTask; we budget 25 s and call
/// `disconnect()` from `expirationHandler` so we don't leave the link half
/// open. CB state restoration handles the actual link revival when the box
/// comes into range — this handler is the *trigger*, not the comms layer.
enum SyncTaskHandler {
    private static let log = Logger(subsystem: "ch.pumptsueri.movementlogger",
                                    category: "background-sync")
    private static let runBudget: TimeInterval = 25
    private static let pollInterval: TimeInterval = 0.5

    @MainActor
    static func handle(_ task: BGAppRefreshTask) {
        // 1) Re-arm the schedule so the loop continues even if we bail out
        //    below. iOS keeps only the latest submission, so this is safe.
        BackgroundSync.refresh()

        // 2) Gating — keepSynced && boxId != nil && logModeManual != true.
        guard AgentConfig.active,
              let saved = AgentConfig.boxId,
              let boxUUID = UUID(uuidString: saved) else {
            log.info("BG sync: gating off (keepSynced=\(AgentConfig.keepSynced, privacy: .public), boxId=\(AgentConfig.boxId ?? "nil", privacy: .public), manual=\(String(describing: AgentConfig.logModeManual), privacy: .public))")
            task.setTaskCompleted(success: true)
            return
        }

        let vm = FileSyncViewModel.shared

        // 3) GUI wins — back off if the user has the BLE machine busy.
        if vm.isBusy {
            log.info("BG sync: foreground busy, yielding")
            task.setTaskCompleted(success: true)
            return
        }

        log.info("BG sync: starting run for box \(boxUUID.uuidString, privacy: .public)")

        // Wrap the run in a Task so we can cancel from expirationHandler.
        let runner = Task { @MainActor in
            await runOne(vm: vm, boxUUID: boxUUID)
        }

        task.expirationHandler = {
            // iOS is reclaiming the slot — cancel the runner and tear down
            // the link so we don't leak BLE state into the next launch.
            log.info("BG sync: slot expired, tearing down")
            runner.cancel()
            Task { @MainActor in vm.disconnect() }
        }

        Task { @MainActor in
            await runner.value
            log.info("BG sync: run complete")
            task.setTaskCompleted(success: true)
        }
    }

    @MainActor
    private static func runOne(vm: FileSyncViewModel, boxUUID: UUID) async {
        // Issue connect. `BleClient.connect` falls back to
        // `central.retrievePeripherals(withIdentifiers:)` when the UUID
        // isn't in scan results — the BG case where we haven't scanned.
        vm.connect(identifier: boxUUID)

        // The deadline guards against a box that never came into range
        // during this slot. iOS won't kill us before expirationHandler,
        // but we shouldn't burn the full 30 s if there's nothing to do.
        let deadline = Date().addingTimeInterval(runBudget)
        var triggered = false

        while Date() < deadline {
            if Task.isCancelled { break }

            // Once we're connected and idle, fire one sync pass. We only
            // trigger once per slot — let the existing `.listDone` →
            // `runSyncDiff` → `pumpSyncQueue` pipeline drain naturally.
            if !triggered, vm.connection == .connected,
               !vm.listing, !vm.syncing, vm.downloads.isEmpty {
                vm.syncNow()
                triggered = true
            }

            // Exit early when the pass has drained. Status strings are
            // the same the desktop+Android use — keeping the contract
            // implicit in the existing UI string is OK because this
            // handler is the only out-of-app consumer.
            if triggered, !vm.syncing,
               let status = vm.syncStatus,
               status.hasPrefix("Sync: complete") || status.hasPrefix("Sync: up to date") {
                break
            }

            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }

        // Always disconnect on the way out. Restoration will hand us the
        // peripheral back next time it comes into range; we don't need to
        // keep the link nominally open between BG slots.
        vm.disconnect()
    }
}
