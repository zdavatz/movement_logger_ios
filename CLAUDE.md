# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

iOS port of `~/Documents/software/movement_logger_android` (Jetpack Compose + Kotlin), which is itself an Android port of the Movement Logger desktop app at `~/Documents/software/fp-sns-stbox1/Utilities/rust`. Talks to the PumpTsueri SensorTile.box over BLE, downloads CSV recordings, and replays them time-synced against a phone-recorded video. SwiftUI + CoreBluetooth + AVKit, no external dependencies.

Tabs (the first three match the desktop and Android tab order; **GPS**, **Rides**, **Analyze**, and **GPS Debug** are iOS/watch additions):

- **Live** — when connected to a PumpLogger-firmware box (advertises as `STBoxFs`), renders the 0.5 Hz SensorStream snapshot: accel / gyro / mag / baro / GPS readouts + two `Canvas` sparklines (acc magnitude, pressure), topped by a **`BoardAnglesCard`** that reads the box attitude (pitch / roll / yaw in degrees, absolute + a zeroable calibration — see the *Live tab — board angles* section below). Subscription is automatic on Connect. Legacy PumpTsueri firmware doesn't expose the SensorStream characteristic — the tab stays empty with a status-line log entry.
- **Sync** — scan / connect / LIST / READ / DELETE / SET_MODE / GET_MODE / START_LOG / SET_TIME. Auto/Manual box log-mode (firmware v0.0.7+): `GET_MODE 0x07` on connect reflects the box's persisted mode, `SET_MODE 0x06` changes it, `START_LOG 0x05 [<dur:u32-LE>]` opens a fixed-duration manual session (no reboot/disconnect — only shown in manual mode). Single-byte SET/GET replies route through a `.modeReq` op. **GPS on/off (`GpsPowerSelector`, firmware v0.0.35+):** an On/Off control next to the log-mode selector turns the box's u-blox receiver off to save battery when GPS is faulty/unused — `GPS_POWER 0x11 [<u8 on>]` (off drops the receiver into UBX-RXM-PMREQ backup, ~tens of µA vs ~25 mA; persisted on the box + re-applied at boot) and `GPS_GET_POWER 0x12` (reflects the box's persisted state on connect). Both mirror SET_MODE/GET_MODE exactly — single-byte writes whose one-byte reply routes through a `.gpsPwrReq` op (the `.modeReq` twin, same 4 s `modeReqTimeoutMs`); `handleGpsPwrNotify` decodes it, `BleEvent.gpsPower(on:)` publishes it, and `FileSyncViewModel.queryGpsPower(attempt:)` is the idle-deferred connect-time query (the same self-deferring pattern as the firmware-version query). VM state is `gpsPowerOn: Bool?` (`nil` = unknown), toggled via `setGpsPower(_:)`. The box owns the persisted state; the app only reflects + sends. With GPS off, logging (IMU + baro) keeps running and Replay still time-aligns via the `# SYNC` anchor — you lose the speed + GPS-track panels but keep pitch/roll/height. Legacy firmware (< v0.0.35) ignores 0x11/0x12 → the op times out and the toggle stays "unknown" (neither button highlights). **`SET_TIME 0x08 [<epoch_ms:u64-LE>]` (firmware v0.0.10+)** is sent on **every connect**: the box has no RTC, so the phone hands it the current wall-clock millis and the firmware stamps a `# SYNC epoch_ms=… tick_ms=…` anchor line into the open `Sens*/Gps*.csv`, pairing the phone epoch with the box's free-running `ms` counter. This is what lets Replay time-align without a GPS fix (see CSV-schema + Replay notes below). Sent *fire-and-forget* (no tracked reply — legacy firmware without 0x08 just ignores the write); the epoch is sampled right before the send so it matches the box tick the firmware stamps. **Settle window (`BleClient.setTimeSettleMs = 2000`):** after `0x08` the firmware is busy appending the `# SYNC` line to SD and **silently drops the next FileCmd that arrives too soon** — confirmed on Android's wire trace, where a LIST ~0.5 s after SET_TIME timed out (20 s watchdog) but the same LIST ≥1.8 s later always succeeded (this bit hard in **Auto mode** where the user connects then immediately taps List). `sendSetTime` sets `setTimeSettleUntil = now() + setTimeSettleMs`; `handleCommand` `await`s `awaitCmdSettle()` before dispatching `.list/.read/.delete/.setLogMode/.getLogMode` — connection-control + SET_TIME itself never wait. So the first file command after a connect is held up to ~2 s instead of being swallowed. STOP_LOG/Disconnect buttons removed (always-on firmware). Downloaded files land in the app's `Documents/` (exposed in the Files app via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
- **Replay** — pick a video (Photos picker OR a `.mov`/`.mp4`/`.m4v` already in `Documents/`) + a `Sens*.csv` + a `Gps*.csv` from the Sync tab's downloads, watch the four overlay panels (speed, pitch / Nasenwinkel, height above water, GPS track) update against the video playhead, then optionally export a V-stack composite MOV (source video on top, panels below with animated cursors) — the iOS equivalent of the desktop's `combined_*.mov`. The composite is saved to `Documents/combined_<basename>.mov` AND added to the Photos library.
- **Rides** — the ride list (`RidesScreen`). Each row is one session's 1 Hz GPS CSV. Two sources are merged (v1.0.57+): Apple-Watch rides synced over WatchConnectivity into `Documents/WatchRides/`, **plus iPhone-recorded rides** in `Documents/` — the phone-logger card's `GpsPhone_*` (and legacy `iPhoneGps_*` — the GPS tab's standalone CSV recorder was removed in v1.0.59 as a redundant subset of the phone logger, but existing files still list) — so a ride logged with **no Apple Watch connected** still maps here (it falls back to the speed-gradient rendering since there's no submersion column). `WatchRideReceiver.refresh()` scans both (`watchRideFiles()` + `phoneRideFiles()`); only watch files feed the WatchConnectivity delivery manifest. Tapping a row opens **`RideMapView`** (v1.0.23+), which plots the recorded track on an interactive Apple `Map` as **one continuous line coloured by inferred activity** — in-water swim / on-board / on-land walk (v1.0.24+) — and can export a **shareable PNG** — real map tiles under the activity-coloured track, start/end markers, a legend, and a branded footer (app logo + ride stats + the GitHub source link). See the *Rides tab — watch GPS on a map* section below. The raw CSV is still shareable straight from the row.

The Live tab observes the same `FileSyncViewModel` instance as Sync — `MainNav` owns it (`@State`) and passes a `@Bindable` reference to both tabs. The BLE client subscribes to FileData *and* SensorStream characteristics in parallel; the desktop's per-firmware advertise-name handling (`PumpTsueri` vs `STBoxFs`) is mirrored via `FileSyncProtocol.boxNames`. iOS auto-negotiates ATT MTU up to ~185 B at connect time, so the firmware delivers full 46-byte snapshots in a single notify; the 3-chunk reassembly path (sequence bytes 0x00/0x01/0x02) is implemented as a fallback but rarely triggers in practice.

The `stbox-viz/` Rust crate's board-3D animation and plotly HTML output stay desktop-only — the phone renders SwiftUI `Canvas` panels for live preview and uses `AVAssetExportSession` + `AVVideoCompositionCoreAnimationTool` for the offline composite export.

## Build & run

```sh
# CI-style compile check, no signing
xcodebuild -project MovementLogger.xcodeproj -scheme MovementLogger \
    -destination 'generic/platform=iOS' -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO

# Signed build for device (uses keychain identity for team 4B37356EGR)
xcodebuild -project MovementLogger.xcodeproj -scheme MovementLogger \
    -destination 'generic/platform=iOS' -configuration Debug \
    -allowProvisioningUpdates build

# Find connected device and install
xcrun devicectl list devices               # grab the iPhone identifier
xcrun devicectl device install app --device <UUID> \
    ~/Library/Developer/Xcode/DerivedData/MovementLogger-*/Build/Products/Debug-iphoneos/MovementLogger.app
xcrun devicectl device process launch --device <UUID> ch.pumptsueri.movementlogger
```

The phone must be **unlocked** when `devicectl install` runs (iOS needs to mount the developer disk image). If the install fails with `kAMDMobileImageMounterDeviceLocked`, unlock the screen and retry.

Targets: iOS 17.0+, universal (iPhone + iPad). Bundle id `ch.pumptsueri.movementlogger`. Marketing version is bumped via the target's Debug + Release `MARKETING_VERSION` settings.

## Signing & Release

Everything about signing and shipping this app — the manual-signing CI setup and
its cert/profile gotchas, the required GitHub Actions secrets, the tag-driven
release workflow, and how to re-roll certificates or provisioning profiles —
lives in the **`release` skill** (`.claude/skills/release/SKILL.md`). Invoke it
when cutting a release or debugging an Archive/Export/upload failure.

Four rules that must NOT wait for a skill to be loaded:

- **Never tag `0.0.x`.** That train is dead (11.7.2026): Apple rejects any
  upload — TestFlight included — whose `CFBundleShortVersionString` is lower
  than the last APPROVED store version (error 90062). Everything rides `1.x.x`,
  and every `v1.x.x` tag auto-submits to the App Store.
- **A new tag supersedes whatever is still in review.** Apple review takes ~a
  day, so a second tag the same day cancels the first version's submission and
  reuses its version record (`scripts/submit_for_review.py`). `DEVELOPER_REJECTED`
  in the release log is that cancel — self-inflicted, not a human rejection.
- **`git fetch origin --tags` before choosing a version.** Sibling repos take
  parallel pushes; check `git tag --sort=-v:refname | head` first.
- **Never mention Android in a `v1.x.x` tag message.** The tag body IS the
  App Store "What's New", and Apple rejects iOS metadata that references other
  mobile platforms (Guideline 2.3.10 — v1.0.37 bounced within 16 minutes over
  "matches … Android v0.0.59"; "desktop" is fine). `clean_notes` in
  `scripts/submit_for_review.py` strips Android-mentioning sentences as a
  backstop, but write the tag body clean — the stripped sentence is silently
  gone from the user-facing notes.

Credential *paths* are deliberately absent from this repo (it is public) — see
the global "don't commit credential paths" rule; they are in this project's
Claude memory.

## App Store assets (screenshots, previews, icon)

The full App Store asset workflow — screenshot resize/upload (incl. the
`APP_WATCH_SERIES_4` 368×448 requirement), 15–30 s app-preview video
transcodes, and app-icon regeneration, with all the dimension/format gotchas —
now lives in the **`store-assets` skill** (`.claude/skills/store-assets/SKILL.md`)
so it loads only when you're doing store-submission work. Invoke it then.

## Architecture

The Swift file layout is derivable — `find MovementLogger -name '*.swift'`, or
just read the files. The subsections below document the parts that AREN'T
obvious from the tree: the non-trivial per-tab behaviors, fusion pipeline, and
BLE/OTA/GPS-debug state machines.

### Live tab — board angles

`LiveScreen.BoardAnglesCard` sits at the top of the Live tab and shows the box attitude in degrees about the box's **physical** axes, computed by `BoardAngles.from(rows:nosePlusY:biasDeg:)` (in `BLE/LiveSample.swift`) from the drift-free gyro+accel `OrientationFilter` `OriRows` — the SAME attitude source that drives the 3D preview, NOT the per-sample raw-accel formulas.

- **Fixes a real bug.** The old "Angles (°)" row in the readout grid used phone-style accel formulas (long axis = X). This box's NOSE is the **Y** axis, so those formulas SWAPPED pitch and roll. That row was removed; `BoardAngles` decouples the three about the physical axes so the labels are literally correct: **Pitch = nose up/down (uphill/downhill)**, **Roll = lean onto the left/right side (bank about the nose)**, **Yaw = heading**. Each is a single decoupled physical quantity (not a coupled Euler triple), so the signs stay individually predictable at the modest angles a foil sees — side-stepping the gimbal / axis-order pitfalls a matrix→Euler decomposition would reintroduce.
- **Two readouts.** *Absolute* passes the real heading bias (`vm.headingBiasDeg`, so yaw is a compass heading). *Calibrated* is a tare: **"Zero here"** (`vm.zeroBoardAngles()`) captures the current pose as the reference, and the calibrated set then shows deviation from that mounted reference; **"Clear"** (`clearBoardAngleZero()`) resets. A "zeroed M:SS ago" note shows how stale the tare is. The tared yaw is sampled at `biasDeg: 0` so turn-since-zero is independent of the direction calibration; pitch/roll are bias-invariant, so both readouts agree on them.
- **The zero reference persists** across reconnect / app-restart via `AgentConfig.angleZeroRef` (`[pitch, roll, yaw]°`) + `angleZeroAtEpoch` (UserDefaults). The VM mirrors those into `angleZeroRef` / `angleZeroAt` at init and rewrites both on every zero/clear.

### Sync tab — BLE FileSync

- `BLE/FileSyncProtocol.swift` mirrors the Kotlin port one-for-one. Authoritative spec is the firmware's `ble_filesync.c`; the Rust client's `ble.rs` and the Kotlin `FileSyncProtocol.kt` are reference host implementations.
- `BLE/BleClient.swift` — single-worker state machine. CoreBluetooth delegate callbacks (on a dedicated serial `DispatchQueue`) marshal raw events into one `AsyncStream<WorkerEvent>`; a single `Task` consumes from that stream and holds `CurrentOp` (`.idle` / `.listing` / `.reading` / `.deleting`). Watchdog ticks every 200 ms are posted into the same stream so op-state mutation stays single-tasked without locks.
- `UI/FileSyncScreen.swift` — SwiftUI binds to an `@Observable` view-model that consumes `ble.events` (an `AsyncStream<BleEvent>`). Bluetooth permission is requested implicitly via the `NSBluetoothAlwaysUsageDescription` build setting — iOS prompts the first time `CBCentralManager` is instantiated. Downloaded files land in `Documents/` under the original filename; `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` surface them in the system Files app under "On My iPhone → MovementLogger".

**Sync vs. transfer (SQLite-tracked).** The Sync tab has two distinct operations, mirroring `movement_logger_desktop` (issues #3/#4): per-file **Download** (manual one-off transfer, unchanged) and **Sync now** (pull every session file on the SD card not already mirrored locally, and remember what was pulled). `BLE/SyncDb.swift` is the iOS port of the desktop's `stbox-viz-gui/src/sync_db.rs` — same `synced_files` schema, primary key `(box_id, name, size)` (`size` in the key on purpose: a regrown file with the same name re-pulls). `box_id` = `CBPeripheral.identifier.uuidString`, captured on `.connected`. DB lives at `<Application Support>/sqlite/sync.db` — anchored there, *not* `Documents/` (which is user-deletable via the Files app; the desktop's analogue is "anchored to $HOME, not the download folder"), in its own `sqlite/` subdir per desktop issue #4. Uses the system `SQLite3` module (no external dependency, no Frameworks-build-phase change — autolinked). **Live-mirror model (desktop v0.0.14):** `Documents/<name>` *is* the running mirror — downloads append straight into it (no `.part`/rename). `READ` carries a u32-LE byte offset (`0x02 + name + 0x00 + offset`); `mirrorOffset` decides per file by **local size vs box size** (local<box → fetch only the tail from `offset=local`; local==box → up to date; local>box → rotated, drop & refetch), so a continuously-growing log only pulls its delta and no big file starves GPS/BAT in the serial queue. The SQLite DB is now an **audit log only** (`isSynced` removed), not the fetch decision. **"Keep synced"** toggle: while connected + idle, re-runs a sync pass every 30 s (`syncPollTask`). Flow: `syncNow()`/keep-synced → `startSyncPass` sets a pending flag → fresh LIST → `.listDone` runs the diff *only* when the flag is set (so the auto-LIST never syncs) → `isSensorData` files behind their mirror drain serially through the single-op `startRead()` path via `pumpSyncQueue` (drained from `.readDone`, which `appendMirror`s the segment at `base` and `markSynced`s for the audit log). **Serial manual downloads:** per-file **Download** taps go through a separate `manualQueue`/`pumpManualQueue` over the same `startRead` — `download()` is a *queue entry* (dedupe + append + publish names into `queuedDownloads` so the row shows **Queued**), and `pumpManualQueue` issues the next READ only when fully idle (`!listing && downloads.isEmpty && syncInFlight == nil && fwUpload == nil && !briefOpInFlight && connected`), re-pumped from `.readDone`/`.listDone`/`.deleteDone`/`.logMode`/`.error`. Before this, a second Download tap while a big file streamed was rejected by the worker ("another op in flight") and the row stuck forever. `briefOpInFlight` covers the brief single-ops not in UI state (DELETE, GET/SET mode) so a Delete-then-Download double-tap can't collide. Mirrors Android `FileSyncCore` exactly. **Lossless resume (desktop v0.0.9):** a link drop / 20 s stall mid-READ emits `.readAborted(name, content, base)`; the VM appends that partial into the mirror (not `markSynced` — incomplete) and sets `transferInterrupted`, which shows an amber banner on the disconnected screen and, on the next `.connected`, auto-runs a sync pass that skips every complete file and re-pulls only the unfinished one from its mirror offset. So a shielded/out-of-range interruption is never lossy. **Bounded auto-reconnect (desktop v0.0.11–13):** on a mid-READ remote drop *or* a 20 s watchdog stall (box still nominally connected — no formal disconnect), `BleClient` arms a tick-driven reconnect state machine (`reconnect`/`tickReconnect`): up to 10 rounds of refresh-scan → `central.connect`, each bounded; suppresses the public `.disconnected` while retrying; subscribe-confirmed clears it and the re-emitted `.connected` drives the mirror-resume. Exhaustion → `.disconnected` + the amber banner (still lossless via the mirror). A user-initiated Disconnect clears the reconnect target so it doesn't bounce back. **Policy (locked, user decision): sync is purely additive — it never issues DELETE.** Only `Sens*/Gps*/Bat*.csv` + `Mic*.wav` are auto-synced; FW_INFO / CHK / error logs stay manual-only. Android (`ble/SyncDb.kt`, `SQLiteDatabase` direct, `filesDir/sqlite/sync.db`, box_id = BLE MAC) is the exact peer.

**Background BLE.** `UIBackgroundModes = bluetooth-central` (Info.plist) lets CoreBluetooth callbacks continue firing when the app is backgrounded — so a long READ keeps streaming bytes while the user switches to another app. To survive the quiet moments between BLE notifications (post-START_LOG 500 ms wait, LIST inactivity terminator, gaps between READ chunks), `BleClient` also holds a `UIApplication.beginBackgroundTask` assertion across the whole connected session — begins on `.connected`, ends on `disconnectInner` / `close`. Without that assertion, the `Task.sleep` calls inside the worker (watchdog tick, post-START_LOG delay) would freeze when iOS suspends the runloop. With it, ongoing BLE traffic keeps re-extending the assertion and the session stays alive in the background indefinitely. Scanning is intentionally NOT supported in the background — `centralManager.scanForPeripherals(withServices: nil)` requires the foreground, and the user is always tapping Scan in the UI anyway.

### Background sync agent

Port of Android's `sync/` (`BackgroundSync.kt`+`SyncWorker.kt`) and the desktop's `--agent` mode — but mapped to iOS's two background mechanisms because iOS does NOT allow Android-style periodic background work for arbitrary jobs.

**Two layered mechanisms:**

1. **CoreBluetooth State Preservation & Restoration.** `BleClient`'s `CBCentralManager` is constructed with `CBCentralManagerOptionRestoreIdentifierKey = "ch.pumptsueri.movementlogger.ble"`. iOS will relaunch the app in the background — *even from terminated state*, *even after a phone reboot* — when the previously-connected box reconnects in range or fires a notification on a subscribed characteristic. `centralManager(_:willRestoreState:)` picks up the restored `[CBPeripheral]`, re-attaches our delegate, rebinds `cmdChar/dataChar/streamChar`, and re-emits `.connected` if the link is already up. This is the **primary** wake-up path — most reliable, no scheduler magic, fires when the user is actually near the box.

2. **`BGAppRefreshTask`.** `Sync/BackgroundSync.swift` registers task identifier `ch.pumptsueri.movementlogger.sync` (matched by `BGTaskSchedulerPermittedIdentifiers` in Info.plist) and submits `BGAppRefreshTaskRequest`s with a 15-min `earliestBeginDate` hint. **iOS owns the actual cadence** — it fires opportunistically based on usage patterns, doesn't fire at all if the user never opens the app, and skips during Low Power Mode. Handler in `Sync/SyncTaskHandler.swift`: re-arms the next slot first → gates on `AgentConfig.active` → checks `FileSyncViewModel.shared.isBusy` (GUI-wins) → `vm.connect(identifier: savedUUID)` → polls until `Sync: complete` or `Sync: up to date` → `vm.disconnect()` → `setTaskCompleted`. Slot budget is ~25 s; `expirationHandler` tears the link down if iOS reclaims early.

**Registration order matters.** `BGTaskScheduler.register(forTaskWithIdentifier:)` MUST be called **before `application(_:didFinishLaunchingWithOptions:)` returns** or iOS drops the identifier and the handler never fires. SwiftUI's `App` lifecycle doesn't expose a synchronous pre-launch hook, so `MovementLoggerApp.swift` uses `UIApplicationDelegateAdaptor(AppDelegate.self)` and calls `BackgroundSync.register()` from the delegate. The same hook also touches `FileSyncViewModel.shared` so the `CBCentralManager` (with its restoration identifier) is constructed before iOS has a chance to deliver `willRestoreState` — SwiftUI evaluates the root view lazily and that's too late.

**Config persistence.** `Sync/AgentConfig.swift` (iOS UserDefaults wrapper) is the iOS peer of Android's `AgentConfig.kt` (SharedPreferences) and the desktop's `~/.movementlogger/config.toml`. Three keys: `boxId` (`CBPeripheral.identifier.uuidString`), `keepSynced` (Bool), `logModeManual` (tri-state — `nil` / `false` / `true`, encoded via a separate `_known` companion bit because UserDefaults has no native tri-state Boolean — same trick as Android). `FileSyncViewModel` is the only writer; the BG handler is the only out-of-app reader.

**Gating (locked, do not change without re-confirming with Peter/Zeno):** `keepSynced && boxId != nil && logModeManual != true` — MANUAL mode disables the schedule (the user controls when the box logs); AUTO + Keep-synced + known box enables it. `logModeManual == nil` (unknown / legacy firmware) is treated as not-manual so old PumpTsueri builds still participate. Identical to Android `AgentConfig.active` and desktop `cfg.keep_synced && cfg.log_mode_manual != Some(true)`.

**Coordination — GUI wins, agent yields** (decided architecture, kept verbatim from Android/desktop): both the foreground UI and the BG handler grab the **same** `FileSyncViewModel.shared` → same `BleClient` → same `CBCentralManager`. The handler checks `vm.isBusy` (connected OR any in-flight op) and yields with `setTaskCompleted(success: true)` if the foreground is active. There is no separate IPC lock (unlike the desktop, which uses fs4 advisory locks for its multi-process GUI/agent split) — iOS's two paths share an address space so they observe the same `@Observable` state directly.

**Schedule refresh triggers.** `FileSyncViewModel` calls `BackgroundSync.refresh()` from three places (gating may have flipped): `.connected` (boxId now known), `setKeepSynced(_:)` (user toggle), and `.logMode(manual:)` (AUTO ↔ MANUAL changes). Plus once on cold launch from `AppDelegate.application(_:didFinishLaunchingWithOptions:)` (in case the app was killed while the schedule was supposed to be live).

**What iOS *cannot* do** (vs Android/desktop):
- No equivalent of Android's WorkManager's "every 15 min, guaranteed" — `BGAppRefreshTask` is opportunistic; iOS schedules it when *iOS* sees fit, not on a wall clock.
- No `BOOT_COMPLETED` autostart — iOS apps cannot start themselves on device boot. Restoration covers the "user opened the app at least once" case (iOS remembers the registered identifier across reboots), but a *fresh* install only starts mirroring once the user opens the app once. Matches Android's behaviour: a fresh install does nothing until the user goes through the foreground Connect → Keep-synced flow.
- No headless background scanning. `central.scanForPeripherals(withServices: nil)` returns nothing in BG and `withServices: [...]` needs the parent service UUID (which the firmware doesn't expose under a standard service). We instead rely on `central.retrievePeripherals(withIdentifiers: [savedUUID])` + `central.connect(...)`, which iOS will fulfil when the box appears.

### Sync UI — visible-progress card

While a sync pass is draining, `FileSyncScreen.SyncProgressRow` sits under the keep-synced toggle and shows two layers of progress:

- **Headline**: cumulative bytes (`X MB / Y MB`), overall percent, and "N of M files" — derived from `syncCumulativeBytes / syncPassTotalBytes`. `syncPassTotalBytes` is the sum of every queued file's `size`; `syncCumulativeBytes` is the sum of completed-files' sizes + the in-flight file's `bytesDone`. The bar advances continuously as bytes arrive over BLE.
- **Current file**: filename + per-file byte progress + per-file bar. Refreshes whenever the queue advances to the next file.

This exists because the file list above the progress card is *deliberately empty* during a sync (the VM clears `files` at `startSyncPass` and only repopulates after `.listDone`), so without a separate progress affordance the user would have no signal that keep-synced was actually doing anything. The card is shown whenever `vm.syncing == true` — both `Sync now` taps AND the 30 s `Keep synced` poll.

**"List files" and "Sync now" are disabled while any worker op is in flight** (`listing || syncing || !downloads.isEmpty`). Without this guard, a tap during a slow READ would surface the BLE worker's `another op is in flight` rejection and look like the tap did nothing.

### Sync race-conditions worth remembering

- **Post-`.connected` sync kick is deferred 500 ms.** When restoration or a reconnect fires `.connected`, the VM sends `getLogMode` *and* (if keep-synced was on) calls `startSyncPass`. Without a defer, the LIST inside `startSyncPass` would collide with the in-flight `modeReq` and be rejected as "another op is in flight". `Task { try? await Task.sleep(for: .milliseconds(500)); startSyncPass(...) }` lets the modeReq reply land first. Idle paths still serialise correctly: the deferred task checks `connection == .connected && !syncing` before kicking.
- **"another op is in flight" is a benign collision, NOT a sync abort.** The original `.error` handler nuked the queue and surfaced a "Sync aborted (BLE error) — try again" banner on any error. Now: `isCollision = msg.hasPrefix("another op is in flight")` short-circuits before the abort path. If `syncing == true` but the queue is empty AND nothing is in-flight (the just-started case), we additionally reset `syncing = false` so the next 30 s tick retries; an active drain is left alone (the in-flight READ keeps going, the colliding command was the new one, not the running one).
- **Don't pump a READ into a reconnecting (dead) link — the orphaned-download stall (v1.0.5).** `armReconnect` suppresses the public `.disconnected` to keep the UI on the connected screen, so the VM still reads `connection == .connected` while the link is actually down. The pre-v1.0.5 bug: a mid-transfer drop → `.error("READ … aborted")` → `pumpManualQueue`/`pumpSyncQueue` issued the *next* queued READ; `startRead` optimistically set `downloads[name]` and then the write failed "not connected", leaving a phantom progress row that never cleared and blocked the queue forever (the "BAT011 hangs partially" report, confirmed in the box's `movement_logger.log` pulled over USB: `READ BAT011 @14506/34572` immediately followed by `ERROR: not connected`). Fix: `BleClient.armReconnect` emits a new `.reconnecting` event **before** `disconnectInner` (so it lands ahead of the `.readAborted`/`.error`); the VM sets a `reconnecting` flag, clears optimistic `downloads`, and both pumps gate on `!reconnecting`. Cleared by the next `.connected` (success) / `.disconnected` (exhausted). The resume sync pass re-pulls from the mirror offset.
- **`startRead` returns whether it issued a READ (v1.0.5).** An already-fully-mirrored queued file (`mirrorOffset >= size`) issues no READ, so there's no `.readDone` to re-pump — the old early-`return` silently stranded the queue (in the sync queue `syncInFlight` stuck on that file; "advances to next item but doesn't continue"). Now `@discardableResult startRead -> Bool`; both pumps loop past non-issuing files (the sync pump folds their bytes into the progress total) and stop on the first real READ.
- **`GET_MODE`/`SET_MODE` time out in 4 s, not 20 s (`modeReqTimeoutMs`, v1.0.5).** A box that never answers `0x07` (legacy/old firmware) used to hold the single-op worker for the full 20 s `opIdleTimeoutMs`, during which every `List files` tap collided — the real cause of "List does nothing for ~20 s after connect" (NOT the SET_TIME settle). The dedicated short timeout frees the worker fast.
- **Big-file drops after minutes are a BOX-firmware problem, not the iOS app.** The drop is a BLE LL supervision timeout (`CBError` "connection timed out unexpectedly"), and the `GET_MODE` silence is the box ignoring `0x07`. Both mean the box runs firmware older than `movement_logger_firmware` v0.0.17, which has the connection-stability fixes (45 s READ stall tolerance; the aggressive 4 s-supervision-timeout conn-param request disabled) and answers `GET_MODE`. The IWDG watchdog is NOT the cause — the READ runs as a main-loop-pumped state machine (`fsm_advance`, one ~244 B chunk per `BLE_Tick`) so the 8 s IWDG is fed between chunks. Fix: flash the box with the latest firmware (BLE FOTA from the desktop app's `--flash-firmware`, or DFU). See `movement_logger_firmware`.

### Firmware OTA (box FOTA over BLE)

Two entry points on the Sync tab, both driving the same `FW_BEGIN → FW_DATA… → FW_COMMIT` state machine in `BleClient` (`0x09/0x0A/0x0B`, `0x0C` abort):

- **"🔄 New box firmware vX available" banner** (v1.0.12) — the one-tap path. `startFirmwareCheck` runs on `.connected`: it queries GitHub (`FirmwareUpdate.checkLatest`, newest `firmware-v*.bin` release on `zdavatz/movement_logger_firmware`) AND the box version (`GET_VERSION 0x10`, firmware v0.0.29+; legacy boxes never reply → treated as "unknown → offer update"). If the latest release is newer (or the box version is unknown) the banner shows. "Update box" (`applyFirmwareUpdate`) **downloads the `.bin` from GitHub in-app** and hands the bytes straight to the OTA flow — the user never touches a file. During that GitHub download there is no OTA bar yet (it starts at `FW_BEGIN`).
- **"Upload firmware (.bin)"** button — the manual path: a file picker over `.bin`s already in the Files app. Only this one needs a local file.

Two v1.0.13 fixes, both found by pulling the box-side `movement_logger.log` over USB while an OTA crawled:

- **Progress bar stuck at 0 % — iOS-only bug.** `handleFwData` bumped the emit-watermark (`lastEmit`) on *every* ACK, so `done - lastEmit` never accumulated to the throttle threshold and `fwUploadProgress` only fired on the final byte — the bar sat at 0 % then jumped to 100 %. **Android (the reference) advances the watermark only inside the emit `if`; desktop emits every chunk (no throttle) — so neither has this bug.** Fixed to only advance `lastEmit` when it actually emits, and dropped `fwProgressChunkBytes` 2 KB → 512 B so a slow transfer visibly moves.
- **FW_DATA resend tuned for dropped ACKs: `fwDataTimeoutMs` 5 s → 1.5 s, `fwMaxRetries` 5 → 12.** The OTA is ACK-gated (one chunk out, wait for the box's 4-byte next-offset reply, resend the SAME chunk on timeout — the box is idempotent for `offset < cursor`, so a resend just re-ACKs, never a bad-seq). On old box firmware the ACK notify is periodically *dropped* (not merely slow), and only the resend unsticks it — so the whole transfer paced at the 5 s timeout (~140 B/s, ~12 min for 106 KB, looked frozen). All three platforms share this exact design and timeout family — **desktop `FW_DATA_TIMEOUT` 5 s / 5 retries, Android `FW_CHUNK_TIMEOUT_MS` 4 s / 5 — so they crawl the same way on a flaky link.** iOS now recovers a lost ACK in 1.5 s (~3× faster, ~3–4 min), keeping ~18 s total per-chunk tolerance (1.5 s × 12) so a genuine multi-second box stall still rides through. Worth backporting the shorter timeout to desktop/Android.
- **`FW_BEGIN: box busy (0xB0)` after an interrupted upload.** Killing the app (or reinstalling) mid-OTA leaves the box's FW staging session open; the next `FW_BEGIN` is rejected BUSY until the box is power-cycled (or a future `FW_ABORT`-before-`FW_BEGIN` self-heal is added). Not a logging conflict when the box is in Manual/idle mode.

### Throughput (carried over from desktop + Android)

PumpTsueri FileSync delivers ~**1.8–2 KB/s** in practice. Measured from real downloads: SENS001 (91 KB) in 46 s, SENS002 (188 KB) in 102 s — same on iOS, Android, and desktop. The bottleneck is the firmware notify pacing + SD-card read rate, not host-side queueing. iOS already auto-negotiates the maximum MTU (~185 B) and the BLE protocol is **single-op by design** (one FileCmd + one FileData characteristic, no multiplexing — a second READ during one in flight is rejected by the firmware with `BUSY (0xB0)`), so parallel transfers are not possible and would not help if they were. A 2 MB sensor file takes ~17 min. Live-mirror + incremental sync (next pass fetches only the new tail) is what makes day-to-day use bearable: only the *first* sync of an old session is slow.

### Replay tab — data on top of video

`ReplayViewModel` keeps the parsed sensor/GPS as `fullSensorRows`/`fullGpsRows` (`@ObservationIgnored` backing storage). On any pick (sensor, GPS, video), `applyVideoAndSlice()` runs and:

1. Picks the **alignment date** from the video's `creation_time` if loaded, else today. This replaces the v1 "today's date" assumption — without it, sensor data recorded on a different day from when the user opens the app would land 24h+ off and the cursor would never move.
2. Re-parses each GPS row's `hhmmss.ss` against that date → `fullGpsAbsTimesMs`.
3. Builds `fullSensorAbsTimesMs` by **piecewise-linear interpolation across the FULL GPS (tick → utcMs) anchor pairs** (mirroring `animate_cmd.rs`'s GPS-anchored time-alignment). v1 extrapolated from a single anchor at a fixed 10 ms/tick and accumulated ~7 s of drift over a 21-min session — that's enough to desync the cursor on Pitch/Height panels visibly. Earlier iOS versions did this on the **already-sliced** gpsRows (often empty when the video falls outside GPS coverage), which produced an all-zero array and broke abs-time slicing entirely. Doing the interpolation pre-slice lets the slice operate on real wall-clock values even when the video's window is past the GPS coverage end.
4. **Slices sensor + GPS by ABSOLUTE TIME** against `[video.creation_time, +duration]`. Both arrays get sliced independently, so different videos from the same long session pick out different sub-ranges (key for sessions where you record many short videos against one continuous box log).
5. **Empty-slice fallback** — when the video window falls entirely outside the sensor's covered time (evening video against a morning-only sensor session), show the FULL session instead of nothing. `rideSlicingSummary` includes "video outside sensor coverage" so the user understands why.
6. **Cursor-sweep fallback** — when (a) there are no usable GPS anchors at all OR (b) we just fell back to the full session in step 5, the abs-time arrays are linearly stretched across the video duration via `linearAbsTimes(...)`. This keeps the red cursor sweeping cleanly 0% → 100% of the panel during playback, instead of parking at the last index because target=`videoCreation+playhead` lies past the last UTC value.

Once sensor data exists, `maybeComputeFusion()` runs the full pipeline on a detached `Task.userInitiated`:

1. `Fusion.detectDtSeconds` → sample rate
2. `Fusion.computeQuaternions` (β = 0.1, matches `animate_cmd.rs:78`)
3. `Fusion.noseAngleSeriesDeg` — 1 s + 60 s rolling-median drift correction. `GpsMath.rollingMedian` dispatches to a sorted-array fast path for windows ≥ 32 / inputs ≥ 64 (the 60 s × 100 Hz = 6000-sample baseline would be unusable on the simple O(n·w·log w) path).
4. `Baro.heightAboveWaterM` — GPS-anchored water reference, falls back to session-max pressure when no stationary anchors exist
5. `FusionHeight.fusedHeightM` — α-β complementary baro + body→world-rotated acc

**Sensor-only / GPS-only rendering.** The pipeline runs as long as **sensorRows is non-empty** — `Baro.heightAboveWaterM` already falls back to session-max pressure when GPS is empty, so Pitch + Height panels render from sensor alone. Speed + GPS track panels render from GPS alone (no sensor needed). The Export gate accepts ANY data series — sensor-only produces a 2-panel composite (Pitch + Height), GPS-only produces a 2-panel composite (Speed + GPS track), full sessions produce the 4-panel composite. `CompositeExporter.activePanelKinds(_:)` filters the panel slots and the output height auto-shrinks (`panelHeight × activeCount`) so there are no empty rectangles in the .mov.

**Video → CSV auto-pick.** `pickVideo()` runs `autoPickMatchingCsvs(referenceMs:)` after slicing — scoring every `Sens*.csv` and `Gps*.csv` in `Documents/` by filename token overlap (e.g. video `Ayano_Pump_25.4.2026_Ermioni.MOV` ↔ `Sens_ayano_25.4.2026.csv` share `ayano`, `25`, `4`, `2026`), falling back to mod-date proximity within ±7 days when filenames are generic (`Sens001.csv` vs `IMG_4022.mov` share no tokens). `Self.fileTokens(_:)` lowercases, strips the extension, splits on `_- .,()[]{}/`, drops noise tokens (`sens`, `gps`, `bat`, `iphonegps`, `mov`, `csv`, `mp4`, `m4v`, `img`, `video`, `log`, `data`, `ble`). The picked match is published to `autoPickSummary` ("auto-pick: Sens → SENS002.CSV · GPS → GPS002.CSV") and rendered in `LoadedStatusBar` so the user can immediately see what was wired through. Reference time is `meta.creationTimeMillis ?? fileModMillis(url)` so the picker works even on re-encoded clips that lost their `creation_time` tag.

**LoadedStatusBar (in `ReplayScreen`).** Sits directly under the Pick/Replace video button, ABOVE the long file picker — so the green ✓ on Sensor / GPS / Video is visible at a glance without scrolling. Without it the only feedback after Load was a tinted row in the file list + a row-count line under ExportRow far below, easy to miss.

Video metadata read via `AVAsset.commonMetadata` for `commonKeyCreationDate`, falling back to `loadMetadata(for: .quickTimeMetadata/.iTunesMetadata/...)` for action-cam containers. Displayed dimensions (`displayedSize`) are computed from `naturalSize × preferredTransform` so the SwiftUI `VideoPlayer` can lock the correct aspect ratio — without that, portrait clips collapse to zero height.

Panels (all SwiftUI `Canvas`, all bound to a 33 ms playhead poll from `AVPlayer.currentTime()`):

- **Speed** — `GpsMath.smoothSpeedKmh` (clip > 60 km/h, linear-interp gaps, 5-sample rolling median).
- **Pitch / Nasenwinkel** — `noseAngleSeriesDeg`, symmetric ±max scaling around zero.
- **Height** — overlay of raw baro (thin grey) and fused (thick primary).
- **GPS track** — lat/lon with `cos(meanLat)` longitude correction; moving red dot at the playhead.

Each panel takes its own absolute-time array (`gpsAbsTimesMs` or `sensorAbsTimesMs`) and binary-searches the cursor index from `videoMeta.creationTimeMillis + playheadMs`. When the video has no creation_time, cursors hide.

**Video picker**: two paths. `PhotosPicker` + a `VideoFile: Transferable` shim that imports via `FileRepresentation(contentType: .movie)` and copies into `temporaryDirectory`. OR a "Video (in Files)" section in `RecordingPicker` that lists `.mov`/`.mp4`/`.m4v` files already in `Documents/` (filtered to hide `combined_*` exports). The Files path is what you want when pushing clips via `xcrun devicectl device copy to` rather than going through Photos.

### Replay tab — composite MOV export

`CompositeExporter.export(_:to:progress:)` builds a V-stack composite: source video on top, four data panels (Speed / Pitch / Height / GPS track) stacked below, with the red cursor sweeps and GPS dot animated via `CAKeyframeAnimation` tied to `AVCoreAnimationBeginTimeAtZero`. H.264 .mov at `1080 × (videoH + 4×320)`, written to `Documents/combined_<basename>.mov` and also added to the Photos library via `PHPhotoLibrary.shared().performChanges { … addResource(with: .video, fileURL:) }` (requires `NSPhotoLibraryAddUsageDescription`).

Built on **`AVAssetExportSession` + `AVVideoCompositionCoreAnimationTool`** — the OS-managed parallel pipeline with the hardware H.264 encoder. End-to-end ~30-50 s for a 39-s 1080×3200 clip on iPhone 17 Pro Max.

**Live value labels** in each panel (mirroring the Android Replay screen's "now X.X" / "fused +X.XX m" top-left stack) come from a `LiveValueLayer: CALayer` subclass. Its `@NSManaged var frameIndex: CGFloat` is animated 0 → numFrames−1 across the video duration via a `CAKeyframeAnimation`; CA's render pass calls `display()` once per output frame, which reads `presentation().frameIndex`, indexes into a precomputed per-frame `[Double]` series (one per dynamic label), and rasterises the text into the layer's `contents`. Pre-computation maps each video frame to the nearest data-array index using the same `nearestIndexByTime(gpsAbsTimesMs, target: videoCreation + t*1000)` that drives the cursor sweep — so labels and cursor stay in lock-step. Static labels (`max`, `±X°`, `range`) are baked once into the panel CGImage; only the dynamic lines re-render per frame.

Two gotchas worth remembering — both were the source of multiple bad first attempts:

1. **`videoLayer.frame` MUST equal `parentLayer.frame` MUST equal `videoComp.renderSize`.** When the videoLayer is a smaller sub-region of parent, the CA tool letterboxes the renderSize-sized video composition output to fit inside the videoLayer's bounds, leaving a black gap. To position the video within a larger canvas, set `videoLayer.frame == parentLayer.frame == renderSize` and use the layer instruction's transform to place the source frame in the top region of renderSize. Opaque sibling sublayers (panel `CALayer`s, added AFTER `videoLayer`) cover the empty bottom of the video render.
2. **`UIGraphicsImageRendererFormat.scale` defaults to device scale (3× on iPhone).** For offline export rendering, this allocates `3× × 3×` pixels — a 1080×3200 canvas becomes a 31 MP bitmap. Set `format.scale = 1` for any export-only render to keep it at native pixel dimensions.
3. **Custom CALayer animating non-standard property:** subclass `CALayer`, declare `@NSManaged var prop: CGFloat`, override `needsDisplay(forKey:)` to return `true` for that key, override `display()` to rasterise contents based on `presentation().prop`. Then attach a `CAKeyframeAnimation(keyPath: "prop")`. This is how `LiveValueLayer` re-renders text every frame against the video clock without thousands of pre-baked CGImages.

Progress is polled from `session.progress` on a background `Task` every 100 ms — `AVAssetExportSession` exposes progress as a property rather than a callback.

After export, a **"Play composite video"** button presents `AVPlayerViewController` in a `.fullScreenCover` for the just-written file URL. This deliberately avoids deep-linking into the Photos app — iOS has no public scheme to open a specific `PHAsset` by `localIdentifier` (`photos-redirect://` only opens Photos's main view, and anything that takes an asset ID is private API). In-app playback gives the same UI Photos uses internally (transport controls, AirPlay, PiP) and skips the app switch.

### Merge tab — stitch clips into one film

`Export/MergeExporter.swift` merges N clips (chronological order) into one
film: `[intro 3 s] [title 2.5 s][clip, full][last-frame freeze fades out 3 s]…
[logo outro 5 s]`. `UI/MergeScreen.swift` + `UI/MergeViewModel.swift` drive the
picker and clip list. Clips are inserted with their **full** `[0, duration]`
range — never a sub-range (hard product rule: "never cut a video"). Same
`AVMutableComposition` + `AVMutableVideoComposition` + `AVAssetExportSession`
pipeline as the composite export; when sensor `panelKinds` are supplied each
clip also carries the Replay panel stack below it (reused `CompositeExporter`
helpers, opacity-gated per segment).

- **All overlay cards are MEDIA, not CALayers — and that is load-bearing.**
  The offline CoreAnimation renderer keeps every layer's `contents` resident
  for the whole export, so a long film with N title/freeze/intro/outro layers
  exhausts the media server and iOS kills the export with **-11847 ← -16101
  ("Operation Interrupted")**. Bisected on device with the `MERGE_SELFTEST`
  harness over a 30-clip / 441 s film: the full layer tree died at 25 %,
  dropping the freeze layers reached 80 %, and both `noca` (no animation tool)
  and `nogaps` (empty tree) exported cleanly. So the intro, per-clip title
  cards, post-clip freeze frames and the logo outro are each rendered into a
  short **two-frame H.264 still** (`makeStillAsset`) inserted into the
  composition, and a plain merge ends up with an **empty CALayer tree** — the
  animation tool is attached only when sensor panels exist
  (`parentLayer.sublayers?.count > 1`). This is the config proven to survive
  any length. The freeze fade is a native `setOpacityRamp` on the layer
  instruction, not a fading layer.
- **The orientation trigger for the original failure.** The render canvas is
  the union of all clips' *displayed* sizes (max W × max H). Mixing 3 landscape
  clips (1920×1080) with portrait (1080×1920) yields a 1920×1920 **square** —
  78 % more pixels/frame than portrait — which is what tipped the CA renderer
  over on a long film (50 all-portrait clips the day before merged fine).
  Hence the Merge tab **only accepts portrait clips**: `Clip.isLandscape`
  (`meta.displayedSize.width > .height` — displayed size, NOT raw stream dims,
  since a portrait iPhone clip reports 1920×1080 with the rotation in its
  transform) routes landscape picks into a separate red "Not merged" section
  in `MergeScreen`; only portrait clips reach `clips` and the exporter.
- **Intro over the first frame (v1.0.43).** The film opens on a 3 s freeze of
  the **first clip's first frame** (`firstFrameImage`) with the gradient
  "MovementLogger" lettering composited semi-transparently (0.85 α + soft
  shadow) over it, as a media still (empty-layer-tree property preserved). The
  background frame is aspect-fit into the exact video region (same fit as when
  the clip plays), so the frozen frame lines up with the first playing frame.
- **Pumping-foil outro (v1.0.44).** The film closes with the foil icon
  PUMPING — rocking about its wings + a synced vertical bob + squash, over a
  sky→sea gradient — mapped from Ayano's `IMG_5266.MOV` pumping footage (~1.05 s
  cadence ≈ 3 pumps / 3 s, ±11° pitch, ±2.1 % heave). It fades IN from black
  (which bridges the last clip's own fade-to-black seamlessly) and back OUT to
  black. Rendered by `pumpFrameImage(i,n,size:)` in a native y-up `CGContext`
  (same transforms verified in `scratchpad`'s macOS preview), then streamed
  frame-by-frame through `makeVideoAsset(...)` — a multi-frame sibling of
  `makeStillAsset` — into an H.264 media segment. So the outro is MEDIA, not a
  CALayer animation: the empty-layer-tree / no-animation-tool config survives.
  The old logo-on-black / logo-on-last-frame outro was replaced by this. The
  `clearLogo` background-knockout is reused to draw just the coloured foil.
- **The logo has no alpha — knock it out at runtime.** `RideLogo` is the
  opaque 1024² app-icon (foil on a flat near-white background); drawn over
  footage it's a light box. `clearLogo` (a cached one-shot ~1 MP pixel walk in
  `makeClearLogo`) knocks the neutral-light background out to transparency —
  keep pixels that are saturated (chroma) OR dark-neutral (the outline), clear
  neutral-light ones, feathered — so only the coloured foil composites over the
  last frame. `RideLogo` itself is left untouched (the Rides-PNG footer draws
  it on white, where the box is correct).
- **Creation-date metadata + idle-timer.** The merged `.mov` is stamped with
  the earliest clip's capture date (`CompositeExporter.creationDateMetadata`)
  so re-picking it doesn't fall into "no capture date — using file date". The
  export disables the idle timer (screen lock revokes the hardware encoder) and
  `MergeViewModel.sweepTmpVideos()` at cold launch deletes leaked PhotosPicker
  copies from tmp.
- **`MERGE_SELFTEST` harness.** Launch-env `MERGE_SELFTEST=1` (+
  `MERGE_SELFTEST_FILTER` name prefix, `MERGE_DEBUG` comma-separated knobs:
  `noaudio,noca,nogaps,nooutro,novc,nosdr,nofreeze`) runs a headless merge of
  `Documents/` clips and prints the result to stdout — driven over
  `devicectl … process launch --console --environment-variables`. This is how
  the -11847 failure was bisected.

### Rides tab — watch GPS on a map (v1.0.23+)

**Rides are re-sent until the phone confirms them (v1.0.46, 24.7.2026).** A
ride used to be handed to `transferFile` exactly once, from
`SessionController.stop()`, with nothing watching whether it arrived — so a
session that never reached Stop (app killed, battery died, watch rebooted)
never queued its CSV *at all*, and a queue entry lost before completion was
never retried. Measured cost on the real device: **8 of 28 rides had never
reached the phone**, including two full sessions (20.07, 206 KB; 23.07
afternoon, 248 KB) nobody had noticed were missing.

The watch never deletes a ride CSV, so all of it was recoverable. `WatchSync`
now keeps a `delivered` set (UserDefaults) fed from two sources: the
`didFinish fileTransfer:` callback (success only — a failed transfer stays
pending), and a `haveRides` manifest the phone publishes from
`WatchRideReceiver.pushRideManifest`. Anything on disk and not in that set is
re-queued by `resendPending()` on activation, on `sessionReachabilityDidChange`,
and from a manual **"Send N rides to iPhone"** button under Start Session.
Details that matter:

- **The phone's manifest is "ever received", not "currently present"** —
  a persistent `receivedNames` set, NOT the folder contents. Deleting a ride
  from the Rides list must not make the watch push it straight back.
- **The running session's CSV is excluded** (`WatchSync.activeRide`, set by
  `WatchGpsLogger.openCsv` / cleared by `closeCsv`) — it's incomplete, and
  `stop()` sends it when the ride ends.
- **The automatic pass is gated on having seen a manifest at least once.**
  Before the first one the watch can't tell which rides are genuinely missing,
  and would blast the entire back catalogue after an app update. The manual
  button is always live.
- **Both application-context writers MERGE.** `updateApplicationContext`
  replaces the dictionary wholesale and `RaceUplink.pushRelayFlag` already
  owned it — a bare write from either side silently wipes the other's keys
  (race config or ride manifest). Both now read
  `WCSession.default.applicationContext` and merge into it.
- `pendingCount` drives SwiftUI and every WCSession callback lands on a
  background queue, so its write hops to main.

There is exactly ONE `WCSessionDelegate` per side (`WatchSync` on the watch,
`WatchRideReceiver` on the phone) — `WCSession.default.delegate` is a single
slot, so a second one would silently steal `didFinish` and break this.

**Sort order (v1.0.46).** The list defaults to **ride date** — the ride's own
UTC start parsed out of the `WatchGps_yyyyMMdd_HHmmss` filename
(`RideStatsLoader.stampDate`), which is independent of when the file reached
the phone. The old behaviour (file mtime) is still available as **Last
synced** via the toolbar's ⇅ menu, persisted in UserDefaults. They only
diverge when a ride syncs late — and then mtime lies badly: the 8 recovered
rides all carried the same recovery-moment mtime, putting a 3 KB stub from
9 July above the previous day's real session. Rows gain a "Synced …" line in
that mode, since every other line on the row is about ride time.

**Row stats (11.7.2026+):** each ride row shows start–end time (local,
derived from the filename's UTC stamp + tick span), duration, outlier-hardened
top speed, and — on rides recorded by an Ultra with the new `WaterTemp [C]`
column — the median water temperature. Parsed once per (path, size) by the
`RideStatsLoader` actor; the mtime + size subtitle shows until the parse lands.
The watch logger (`WatchGpsLogger`) writes the temp column from
`WaterTempManager` (`CMWaterSubmersionManager`, submersion-gated, Ultra-only;
blank when dry or unsupported) via a provider closure set in
`SessionController.start()`. Row and PNG footer share one source of truth,
`RideMapRenderer.medianWaterTempC` — **median**, not mean: the sensor's first
reading after entry lags the real water (a real file opens 32.7 / 29.3 °C before
settling at 27.4), so a handful of warm outliers would drag an average.

**Wind (v1.0.36+, at-top-speed since 18.7.2026):** row + PNG footer show the
WeatherKit historical wind (`Data/RideWeather.swift` — hourly history back to
2022-08-01, cached per ride; nil offline just omits it and its attribution).
The value is the **wind at the moment of the ride's top speed**: `RideMapRenderer
.robustTop` also returns the winning sample's tick, `RideStats.topSpeedAt`
converts it to a Date, and `RideWeather.wind(… peakAt:)` picks the single hour
nearest that instant (the ride-median remains the fallback when no sample
qualified). Apple's terms require the " Weather" trademark + legal link
wherever the data shows — pinned under the Rides list and drawn in the PNG
footer only when wind actually rendered (App Review checks, Guideline 2.1).
The **watch shows the same thing live**: a WIND metric next to TOP/WATER with
the wind blowing when the current session TOP was set. The watch app has **no
WeatherKit entitlement** (a portal-only capability click that would re-roll the
pinned CI watch profile — see the asc-api memory), so `WindAtTop.swift` (watch)
asks the paired iPhone over WCSession (`windReq` → answered in
`WatchRideReceiver` from the phone's `RideWeather` cache), caches the answered
hour, retries ~1/min from the 1 Hz fix stream while unreachable, and shows "—"
until a value lands.

**Watch water temp: a dry spell must last `WaterTempManager.dryGraceSec` (60 s)
before the reading is dropped (16.7.2026).** The sensor never signals "this
value is stale" on its own, so an un-expired `temperatureC` holds for the rest of
the session and the walk back on land logs as wet — that's why the clearing
exists. But clearing on the *first* `.notSubmerged` (the 11.7 fix) was far too
trigger-happy: a swimmer's wrist breaks the surface every stroke and the sensor's
temperature pushes are too sparse to refill the gap, so the watch showed "—" for
most of a swim and the CSV lost the column. Measured on the 16.7 ride: **60 dry
gaps inside the submersion span, 40 of them ≤10 s, exactly one genuinely long**
(55 min, out of the water). The 60 s window bridges 59 of 60 — the swim window
goes from 15 % → 84 % of seconds carrying a temperature — while the tail still
clears 151 s before the ride ends, so the walk back stays dry. The phone-side
stale-run stripper in `RideActivity.confirmedWet` remains as the second belt.

**One continuous track, coloured by activity (v1.0.24+ — replaced the
blackout hole-splitting).** The old `cleanTrackSegments` broke the polyline
across every ≥2 s fix hole; on a real swim/foil session that produced *seven
disconnected segments* ("too many holes"). `RideMapRenderer.cleanTrack` now
draws **one continuous line**: `validPoints` (the `hdop ≤ 50` gate still drops
the WiFi-fallback fix 70 km away, honestly stamped accuracy 149 000 m — that
outlier is the *only* across-town risk, so once it's gone every gap is safe to
bridge) → `dedupFixes` (collapse the watch's rewritten last-known-location
stall rows) → `despike` (drop a lone fix reached+left by two >45 m hops within
2.5 s while its neighbours sit <45 m apart — 1-sample GPS glitches of
100–380 km/h that draw a zig-zag spur) → `smoothPositions`. Only a genuine
>200 m teleport breaks the line (`CleanTrack.breaks`; never happens in practice
after the accuracy gate). Verified against the 11.7.2026 ride: 7 segments →
1 line, no hops >150 m.

**`smoothPositions` — `smoothHalfWindow` is 12, and DON'T get clever
(16.7.2026).** A submerged wrist wrecks the fix: CoreLocation honestly stamps
**±13 m median / ±30 m p90 while swimming versus ±4 m on the board** (the HDOP
column is `horizontalAccuracy` in metres — see `WatchGpsLogger`), while a swimmer
covers only 0.55 m/s. So metres-per-second hops in random directions on the swim
back are pure noise — "I can't swim in a zig-zag like that". `despike` can't
touch it (lone 45 m+ spurs only), and the 1/accuracy² weight can't either: the
**board's accuracy is no better than the swim's**, so it has nothing to
discriminate with. The fix is just a wider window (±6 → ±12 samples ≈ seconds at
1 Hz), which halves the noise it can't tell from motion. **±20 is the ceiling:**
it rounds the sharp U-turn of a jibe into a loop (verified at idx 4225 of the
13.7 ride, a trusted ±7 m fix at 11.7 km/h).

Two smarter filters were tried and **both rendered visibly worse** despite every
numeric metric improving — hop-p90, worst-hop and reversal-count all said "big
win" while the map drew long straight spurs across the bay:
- a **median** filter — medianing lat and lon *independently* is not a geometric
  median and can emit a point that never existed; its piecewise-constant output
  draws straight jumps (and scores beautifully on hop metrics, being mostly zero);
- a **bilateral** filter (confidence × time × range kernels) — edge-preserving
  means **outlier-preserving**: when a noisy fix sits beyond the range kernel from
  its neighbours every weight collapses and it keeps its raw position. Exactly
  backwards here.

Lesson: **render the PNG and look at it** — the numeric metrics actively reward
these artifacts. `scripts/ride_map_png.swift` is the fast way (no device needed).

**The gate is `maxPlausibleHdop` (50) AND `staleFixAccM` (30) — and lowering the
accuracy gate is NOT the fix (16.7.2026).** The 13.7 ride's 408 m / 367 km/h
snap-back comes from a *drift run*: fixes whose accuracy climbs monotonically
38.9 → 49.5 while the position slides ~30 km/h for a 4.6 km/h rider, then the
receiver re-acquires 408 m away. `despike` can't see it (lone spikes only).

The tempting fix — drop accuracy > 35 — is **wrong**, and the data says so:
legitimate *swim* fixes reach **p90 46 m / p99 94 m** (submerged wrist), so a
35 m gate deletes **16 %** of a real swim to remove a handful of drifters. The
swim's honest noise looks like garbage to every accuracy-based test.

What identifies the drift is that CoreLocation **disclaims it**: `CLLocation
.speed < 0` ("speed invalid"), which `WatchGpsLogger` writes as a blank Speed.
So `validPoints` drops a fix only when it has **no valid speed AND accuracy
> 30 m** — both, since either alone hits honest fixes. Costs ≤18 fixes on any
ride measured (5 on 13.7 — exactly the drift), and the 12.7 walk-back still
classifies as land.

Also tempting and also wrong: dropping fixes whose position outruns their own
speedometer. A swimmer's noise has exactly that signature (position implies
5–7 km/h while the speedometer says 2), so it eats the swim too.

Residual, accepted: hops of ~60–70 m right after a long dropout, where the
receiver re-acquires and takes a second or two to settle (e.g. 15.7 after an
88 s gap). Small, and indistinguishable from real motion across the gap. Note a
big hop is NOT automatically garbage — the 13.7 ride's 254 m hop is a genuine
95 s dropout the rider really rode across (16.6 km/h). Judge by implied speed
against the **UTC** column, not by distance and not by the tick counter.

**Activity classification (`RideActivity`).** Colour = inferred activity, not
raw speed, when the ride carries the Ultra's `WaterTemp [C]` submersion column.
`RideActivity.modes(for:)` decides per point, in this order:

1. **Speed vetoes land** — median-smoothed (window 5) `speed ≥ boardKmh` (6)
   → **on board** (crimson). Nobody walks or swims at 16 km/h.
2. **Terminal walk back** — dry, moving points after the last real submersion,
   when that tail travels >60 m, are **on land** (amber). **A terminal SWIM
   back is NOT a walk (v1.0.47, 26.7.2026).** During a swim the wrist stays
   submerged stroke to stroke but `CMWaterSubmersionManager` pushes fresh
   temperatures only rarely, so the reading sits at a constant value — which
   `confirmedWet`'s stale-temp stripper read as "the sensor holding its last
   value on the walk ashore" and stripped, after which this rule painted the
   whole swim "on land" (the 26.7 Ermioni ride: the final 195 s swim to the
   launch, at 0.4–2.5 km/h, all inside the water region, showed amber). Fix: a
   stripped trailing point that is still **inside the water region on a ride
   that ENDS over water** (`water.last == true`) is a submerged swim — restore
   its wetness so it reads **in water**, not land. Geography is the arbiter: a
   real walk ends *outside* the region (ashore) and is untouched (verified: the
   25.7 ride's 11-min walk up into town still reads land). The region is seeded
   from the *stripped* array, so the restore can't pull an inland walk's cells
   back in.
3. **WHERE** — `waterRegion`, a ~70 m grid dilated by ±2 cells (~140 m) around
   every *proven-water* fix: the confirmed-wet fixes **plus every fix crossed at
   board speed between the first and last submersion** (you cannot foil across a
   car park). Outside it → **on land**.
4. **WET** — `stickyWet` (a submersion reading within ±45 s) → **in water /
   swim** (cyan); dry and slow but on the water → **on board** (a drift or a
   wait between runs).

Runs shorter than `minRunSec` (20 s) are absorbed into their longer neighbour
(`smoothKeys`) so the track shows sustained bands, not per-fix flicker.

**Mode colours flip with the map appearance** (`RideMode.color(dark:)`): on light
tiles **dark blue** (in water) / **dark green** (on board), on dark tiles **light
blue** / **crimson**; **amber** (on land) reads on both. The original fixed
blue/green/orange was picked for meaning, not legibility — green sat on the light
map's pale-blue sea at barely any contrast, and blue "in water" was near-invisible
on the water it named. Because the colour depends on the appearance, `mapRuns` is
rebuilt on `\.colorScheme` change (`RideMapView.recolor()`), and the PNG must be
TOLD the appearance: an `MKMapSnapshotter` rendered off the main actor does NOT
inherit the app's trait collection, so the view passes it into
`RideMapRenderer.render(rows:title:dark:)` — without that a dark-mode user gets a
light-mapped PNG. (`scripts/ride_map_png.swift` mirrors both palettes;
`MLDARK=1` renders the dark pair.)

**Speed only ever rules land and swim OUT; it never tells them apart** — at
swim/foil speeds GPS noise spikes cross any threshold, so board-vs-swim stays
the submersion sensor's job. That asymmetry is the 13.7.2026 fix: seeding the
water region on the wet fixes ALONE is far too tight. On a 125-min sea session
the sensor fired on only 2.1 % of fixes (159 of 7492, 20 grid cells), so every
stretch more than 140 m from one of them fell outside the region and was called
"on land" — 22 % of the ride, at a median 16.5 km/h, on a rider who never once
went ashore. The fast track now seeds the region too, and a moving fix can no
longer be land at all. Genuine walks (2–3 km/h, off the water) are unaffected —
verified against the 12.7 rides, whose walk up into the town still reads land.

**Submersion is the only reliable wet/dry signal** — proven necessary: on the
temp-less 10.7/11.7 files, speed+altitude mislabels ~80 % as "swim" and flickers
false "land" mid-ride (GPS altitude is ±several m of noise at sea level), so
**rides with no submersion column degrade to a speed gradient** (blue slow → red
fast) with a "no submersion data" note rather than guessing land vs water.
`RideActivity.hasSubmersion` (≥1 finite `waterTempC`) picks the path. The
`WaterTemp [C]` column is already in the watch source (`WatchGpsLogger.swift`) —
a watch that recorded before that build was installed produces temp-less rides,
so existing rides show the speed fallback until a fresh ride is recorded with
the updated watch app.

`RidesScreen` lists the ride CSVs `WatchRideReceiver` finds: the Apple-Watch rides mirrored into `Documents/WatchRides/` **and** iPhone-recorded tracks in `Documents/` (`GpsPhone_*` from the phone-logger card, plus legacy `iPhoneGps_*` — the GPS tab's standalone recorder was removed v1.0.59; v1.0.57+, so a watch-less iPhone ride still shows). Everything downstream (row stats, `RideMapView`, delete) keys off the file URL, so the mixed list needs no other change; box downloads (`Gps001.csv`) and the IMU `SensPhone_*` sibling are deliberately excluded. Each row is a `Button` presenting **`RideMapView`** (`UI/RideMap.swift`) as a `.fullScreenCover`; the raw CSV `ShareLink` stays on the row (with `.borderless` so the tap doesn't also fire the nav).

- **Interactive view** — `RideMapView` parses the CSV with `CsvParsers.parseGpsFile` (which also accepts the watch logger's bracketed `Lat [deg]` / `Lon [deg]` / `SpeedKMh` headers — see the CSV-schema note), builds the coloured runs via `RideMapRenderer.mapRuns(clean:)` and draws **one `MapPolyline` per colour run** (adjacent runs share their boundary point so the line stays continuous across a colour change), with green **Start** / red **End** annotations and a translucent **legend card** (`.overlay(.bottomLeading)`) — mode swatches when submersion data exists, a speed-gradient bar otherwise. The speed fallback approximates the gradient with 6 smoothed speed bands. Camera frames the track via `.rect(RideMapRenderer.boundingRect(trackPoints))`.
- **Shareable PNG** — the toolbar Share button calls `RideMapRenderer.render(rows:title:)`, which uses **`MKMapSnapshotter`** (NOT `ImageRenderer` — SwiftUI's `Map` snapshots blank because tiles render out-of-process) to grab real Apple Maps tiles, then draws over the snapshot with CoreGraphics: a white casing (one continuous sub-path per non-broken run), then the track **edge-by-edge** in the activity-mode colour (or the speed gradient `speedColor`, `robustMaxSpeed` = 95th-pct), start/end dots, and a branded footer. The footer is a **horizontal legend strip along the top** (activity swatches left→right, or a speed-gradient scale — deliberately its own band so the long source-URL line can never collide with it), a divider, then the **app logo** (`RideLogo` imageset — a copy of the app icon, since `UIImage(named:)` can't reliably load an `AppIcon` set), ride **stats** (top speed via `RideMapRenderer.robustTopSpeed` — hard 60 km/h clip + blackout adjacency + ±1 s chord consistency; distance via `trackDistanceKm` over the continuous track skipping breaks + `trackMaxHopM` glitch hops; duration; and **median water temp** via `medianWaterTempC`, omitted on a ride with no submersion column — the four-item line auto-shrinks via `fitted(_:maxWidth:…)` rather than running under the right edge), and the **GitHub source link** (`RideMapRenderer.sourceURL`). The PNG lands in `Documents/RideMaps/<name>_map.png` and is handed to a `UIActivityViewController` share sheet. `snapshot.point(for:)` returns points in the snapshot image's own space, so the track aligns to the tiles with no manual flip on iOS.
- **Export must always complete — never hang, never silently fail (v1.0.60, 1.8.2026).** Lionel's phone-recorded ride wouldn't export (*"dauert zu lange, Export klappt nicht"*). Three unbounded costs in `share()` were the cause, all now bounded: (1) **`MKMapSnapshotter` has a 12 s timeout** (`snapshotTimeoutSec`) and, on timeout/failure, `render` falls back to a **tile-less** draw — the track + branded footer on a plain sea-tone background (light/dark) instead of returning `nil`, which the old code did → the share sheet just never appeared, indistinguishable from "broken". The fallback projects each `MKMapPoint` through `aspectFitRect(rect, size:)` (the rect the snapshot *would* have shown: the bounding rect expanded about its centre to the map-size aspect) — MKMapPoint y is south-down like image y, so **no flip**, same as `snapshot.point(for:)`. The online path is byte-identical to before (with a snapshot, `mapPoint` is `snap.point(for:)` and `fmt.scale` is `snap.image.scale`). So an offline share at the beach still yields a track card. (2) **WeatherKit `addWind` has a 6 s timeout** (`RideMapRenderer.withTimeout`) — wind is optional in the footer, usually a cache hit from the row's fetch; the cap only bites when that fetch failed. (3) See the `accBins` byte-parser note below — the big-`SensPhone` read the export serialised behind.
- **Top-speed hardening (30.7.2026, Android-parity port).** The 29.7.2026
  SUP paddle (phone in a pocket, avg 3.3 km/h) fabricated 30.35 km/h via a
  2-row GPS multipath kick WITH a matching ~5 m position kick — the old
  three gates (clip / blackout / chord) all passed it. `robustTop` gained
  two gates: (a) **row quality** — a speed row with `hdop >
  maxSpeedRowHdop` (15) never sets the headline (the phone/watch loggers
  stamp an honest accuracy proxy; `validPoints`' `maxPlausibleHdop` stays
  50 — tightening it punched visible holes through honest degraded
  mid-paddle rows on Android); (b) **acceleration envelope** — a candidate
  must be reachable from EVERY finite speed row within ±5 s under
  8 km/h/s, or under the per-second allowance measured by the paired
  `Sens*` file's accelerometer (`CsvParsers.accBins(fromSensorFile:)` —
  memory-mapped **raw-byte** walk that parses the four needed fields
  straight from the bytes via `parseAsciiDouble` (**no `String`/`trimming`
  per field**): 90 MB / 1.1 M rows in ~0.065 s release, ~1 s debug — the
  old `String(decoding:)`+`trimmingCharacters` path was ~0.6 s / ~2 s, and
  the PNG export **serialised behind it** (the `RideStatsLoader` actor), so
  a big-`SensPhone` phone ride's export stalled multiple seconds on device
  (v1.0.60 fix; output byte-identical, verified on the 29.7 SUP file). Never
  a full `[SensorRow]`
  parse; `RideMapRenderer.accelProfile(bins:)` — |mean − rolling-median
  gravity ref| per 1 s bin, orientation-free so pocket carry works,
  veto-only so IMU noise can't reject a real sprint). Threaded through
  `RideStatsLoader` (`accelProfile(forGps:)`, (path, size)-cached; sens
  sibling = first "Gps" → "Sens" in the name, so `iPhoneGps_*`/watch rides
  get nil and keep the flat cap) and `RideMapRenderer.render(accel:)`.
  Strict-minimum envelope on purpose: at 1 Hz each side has exactly one
  meaningful neighbour — a median or percentile discards the only real
  constraint (both failed on the real session). Android
  `RideMapRenderer.robustTopSpeed` is the reference implementation
  (v0.0.68); results on the session: 30.35 → 12.28 km/h. Desktop not yet
  ported.
- **`scripts/ride_map_png.swift`** is the standalone macOS twin of `RideMapRenderer` (AppKit/`NSImage` instead of UIKit): `swift scripts/ride_map_png.swift <in.csv> <out.png> [logo.png]`, `MLDEBUG=1` to print the classified runs. It ports the same continuous-track cleaning + `RideActivity` classifier + legend, and is how the v1.0.24 rendering was verified on the Mac (incl. a synthesised `WaterTemp` column to exercise the 3-mode path). **It does NOT flip `point(for:)`** — that was a bug (fixed 13.7.2026): on AppKit `snapshot.point(for:)` already comes back in the same y-up space the snapshot image is drawn in, so the old `y = footerH + (mapH - p.y)` mirrored the whole track against the tiles. It silently invalidates any visual check made with this script — a due-north synthetic track drew its start at the top, and the 12.7 walk into town appeared out at sea. iOS is y-down and likewise needs no flip.

### Watch live board angles (v1.0.48+) — watch strapped to the board

The wrist can't measure board attitude, but the watch **strapped to the board**
can: `deviceMotion` then gives fused, gravity-referenced **pitch / roll / yaw**,
so `WatchImuLogger` doubles as the live source for a **board-angles card on the
watch main screen** (`ContentView.boardAnglesCard`) — the watch analogue of the
box's Live-tab `BoardAnglesCard`. **"Zero here"** tares the mounted pose
(`WatchImuLogger.zero()`/`clearZero()`); since the strap orientation is
arbitrary, the tare defines level/forward, exactly like the box's `nosePlusY`.
The angle is `CMAttitude` relative to the saved reference
(`multiply(byInverseOf:)`); at the modest angles a foil sees, Euler pitch/roll/
yaw are unambiguous (no gimbal lock), so this stays simple.

- **One `CMMotionManager`, two clients.** `WatchImuLogger` is `@Observable` and
  owns the single motion manager (Apple's rule — a second one starves the
  first). `startLive()`/`stopLive()` (driven by `ContentView.onAppear`/
  `onDisappear`) and `start(stamp:)`/`stop()` (the ride logger) are independent
  clients; `ensureRunning()` runs `deviceMotion` while EITHER is active and
  stops it when both are done. The handler publishes throttled pitch/roll/yaw to
  the UI (~8 Hz) AND writes the raw CSV row when a ride is logging. Tare capture
  is done inside the handler (`zeroPending`/`clearPending` flags) so the
  reference `CMAttitude` is only touched on the delivery queue and is a distinct
  object from the frame being displayed (`multiply` mutates its receiver).
- **The recorded gravity already carries the angles.** The CSV schema is
  unchanged — `gx/gy/gz` is the gravity vector, which yields board pitch/roll
  post-hoc — so a board-mounted ride on **1.0.47** already captures the angle
  data; the live card (1.0.48) is the real-time convenience on top. Running the
  box AND a board-mounted watch on the same ride gives a free box-vs-watch angle
  cross-check.

### Watch → phone live view (v1.0.50+)

A card at the top of the phone's **Live tab** (`LiveScreen.WatchLiveCard`, shown
regardless of any box connection) mirrors the board-mounted watch's live data —
**pitch / roll / yaw + speed + water temp + height + battery** — streamed from
the watch over WatchConnectivity. Built on the same `sendMessage` relay as the
race fixes.

- **Two transports, auto-selected.** (1) `WCSession.sendMessage` — Bluetooth up
  close, WiFi at range on the same network, low latency, NEVER cellular. (2) The
  **public race relay** (`ml.ywesee.com:47777`, the desktop's `race-relay` UDP
  service) — works over **any internet incl. cellular/GSM**. The watch sends via
  WCSession when the phone is directly reachable and falls back to the relay
  (`WatchLiveRelay.sendSnapshot`, a `typ:"board"` rider datagram, ~3 Hz, only
  during a session to bound cellular use) when it isn't; the phone's card is
  always a relay **viewer** (`WatchLive.startViewer` — subscribe every 8 s +
  receive), so it shows whichever path delivers. Rider/token reuse the race
  config (`race.rider`/`race.token`); a token only matters to isolate your stream
  on the shared relay. **The relay endpoint is user-configurable (v1.0.51):** an
  editable "Relay: host:port" row on the live card (`WatchLive.relayHost/
  relayPort`, persisted `live.relayHost`/`live.relayPort`, default
  `ml.ywesee.com:47777`) — run your own `race-relay` and point both ends at it.
  The phone pushes `liveRelayHost`/`liveRelayPort` via the (merged) application
  context; the watch's `WatchLiveRelay.configure` applies it. **Caveat:** the relay is one-way rider→viewer, so the
  phone can't send `wantLive`/`zeroAngles` to a far watch — the relay send isn't
  gated on `wantLive` (streams whenever a session runs + phone unreachable), and
  the remote tare only works over WCSession (up close). Cellular also needs an
  active plan on the watch, and the watch only uses cellular when the phone
  isn't nearby (else it routes through the phone). File sync is unaffected —
  rides always sync over BT when back near the phone.
- **Pull model, phone-driven.** The card `requestStream(true)` while on screen
  (re-sent every 2 s so it catches the watch coming into range), `false` on
  disappear. The watch (`WatchSync.didReceiveMessage`) sets `liveStreaming` and
  calls `imu.startStream()` — a THIRD `WatchImuLogger` client (alongside the
  watch-UI card and the ride logger) so a board-mounted, screen-off watch keeps
  feeding the stream during a ride. `SessionController` wires `imu.onAngles` to
  assemble the full snapshot (angles from the IMU + speed/water/baro from the
  GPS logger + battery) and `WatchSync.sendLiveSnapshot` sends it, throttled
  ~10 Hz, gated on `liveStreaming && isReachable`.
- **Remote tare.** The card's "Zero here"/"Clear zero" sends `zeroAngles`/
  `clearZero` back to the watch (`imu.zero()`), so you tare the board-mounted
  watch from the phone in your hand. The button label tracks the watch's `hasZero`
  (streamed as `z`).
- **Phone state** is `WatchLive.shared` (`@Observable`), fed by
  `WatchRideReceiver.didReceiveMessage` (the single phone-side `WCSessionDelegate`
  — the `live` message is handled alongside `raceFix`, no early-return). `isFresh`
  (≤2.5 s since last snapshot) drives the "waiting / stale" state; speed/water/
  height are only live while a session runs on the watch (`running`).

### Race map (iPhone) — live multi-rider (v1.0.52+)

A **Race** tab (`UI/RaceMapScreen.swift`, `MainNav` tag 7) — the iOS port of the
desktop Race tab (`race.rs`): a live `Map` (`.hybrid` satellite + labels) with a
heading-rotated marker per rider, a per-rider trail, and a bottom **data panel**
showing everything the selected rider streams — speed + board **pitch/roll/yaw** +
water temp + height + accuracy + battery. Fed by **`Sync/RaceViewer.swift`**, a
relay *viewer* (`@Observable`, one `RaceRider` per `rider` name) that subscribes
to the **same user-configurable relay** as the live view (`WatchLive.relayHost/
relayPort` + `RaceUplink.token`) and merges two datagram kinds by rider name:
position-only race fixes AND `typ:"board"` snapshots (position + angles). Trail
shaping mirrors `race.rs` — 1500 points (~5 min @ 5 Hz), 3 m dead-band, fixes
worse than 20 m accuracy show the dot but don't enter the trail; a rider idle
>12 s greys out but stays put (a capsized rider's last position).

- **The board snapshot now carries position (v1.0.52).** `WatchLiveRelay
  .sendSnapshot` gained `lat/lon/deg/acc` (from `WatchGpsLogger.latestLat/…`),
  so a single board datagram is a complete map datagram — the rider plots WITH
  angles. A rider running only race mode (position, no angles) still plots from
  race fixes; `RaceRider.hasBoard` picks whether the panel shows pitch/roll/yaw
  or just heading.
- **Same relay-viewer plumbing as the live card**, so the configurable relay
  endpoint (own `race-relay`) drives both. Only shows riders while the tab is
  open (`start()`/`stop()` on appear/disappear).
- **Phone as a rider (v1.0.53) — carry the phone instead of a watch.**
  `Location/PhoneRider.swift`: a "Track this phone" toggle (Race-tab settings
  sheet) streams the phone's own GPS to the **same relay** the map reads
  (`WatchLive.relayHost` + `RaceUplink.token`) as a rider, hooked into
  `GpsCore.didUpdateLocations` (~5 Hz), so this phone appears on its own map and
  every viewer's. **Rider name defaults to the device's own name**
  (`UIDevice.current.name`, editable — iOS 16+ may return a generic "iPhone"
  without the user-assigned-device-name entitlement); the watch rider defaults
  to `WKInterfaceDevice.current().name`. The settings sheet also edits the relay
  host/port + race token, shared across the map, live view and watch.
- **Phone board-mounted mode (v1.0.54) — full board tracker.** The iPhone has
  the IMU + barometer (lacking only the Ultra's water-temp sensor), so a
  "Board-mounted" toggle streams **pitch/roll/yaw + height** too via
  `Location/PhoneMotion.swift` (the phone twin of `WatchImuLogger`'s live-angle
  side: `CMMotionManager.deviceMotion` tared attitude + `CMAltimeter`), folded
  into `PhoneRider`'s `typ:"board"` datagram — so a board-mounted phone plots
  WITH angles like a watch rider. "Zero here" tares the mount. Off by default
  (a carried phone can't sense the board; and IP68 ≠ made for continuous
  surf/salt). Needs `NSMotionUsageDescription` (added to the phone Info.plist).

### Watch IMU logging — a separate motion CSV (v1.0.47+, Phase 1)

To tell a **belly-paddle** from a **foil-pump** from **gliding/waiting** —
which GPS speed + water-submersion alone cannot (all three are "slow, on the
board, over water"; the propulsion is invisible to those sensors) — the watch
logs its **fused inertial motion** during a watch-GPS ride. `WatchImuLogger`
(`MovementLoggerWatch/WatchImuLogger.swift`) runs `CMMotionManager.deviceMotion`
at **25 Hz** into a **separate** `WatchImu_<stamp>.csv` — same stamp as the ride
so the phone pairs them (`WatchGps_<s>` ↔ `WatchImu_<s>`).

- **Why separate + raw, not features on the GPS row.** The ride CSV is a clean
  1 Hz GPS grid the parsers already read; a 25 Hz stream would bloat it and
  break the schema. And the classifier is still being *developed*, so we log the
  raw fused samples (columns: `epoch_ms, ux/uy/uz` userAcceleration g,
  `gx/gy/gz` gravity, `rx/ry/rz` rotationRate rad/s) rather than pre-computed
  per-second features — so the phone-side classifier can be tuned against the
  real waveform. **Phase 2 (the classifier) can't be written until real rides
  carry this data** — ship the logging, record a paddle+foil session, then tune.
  `userAcceleration` (gravity already split off) is the cadence channel; a
  paddle is a big fore-aft arm swing, a pump a ~1 Hz vertical heave. 25 Hz is
  ≥16 samples/cycle for a ≤1.5 Hz stroke — the 800 Hz `CMBatchedSensorManager`
  firehose is for a golf swing. Updates keep flowing in the background off the
  same `WorkoutKeepAlive` session that keeps the GPS logger alive.
- **Wiring.** `SessionController` mints one stamp, sets `gps.pairStamp`, and
  starts both loggers in the watch-GPS branch (box sessions log on the box, not
  the watch — no IMU); `stop()`/`abort()` stop both and hand each file to
  `WatchSync`. Sync reuses the ride path: `WatchSync.pendingRides()` now matches
  `WatchImu_*` too (so the retry/manifest bookkeeping covers it), and the
  running ride's IMU sibling is excluded from a mid-ride resend (shares the
  active ride's stamp). Phone-side, `WatchRideReceiver` **stores and
  manifest-tracks** IMU files (so the watch stops re-sending them) but
  **excludes `WatchImu_*` from the Rides list** — they're not rides.
- **Cost / follow-up.** ~9 MB for an 87-min ride over WCSession (background,
  fine for the tuning phase). Once the classifier is validated, slim this to
  compact per-second features on the GPS row, or classify on-watch. Needs the
  watch on the v1.0.47+ build; rides recorded by an older watch have no
  `WatchImu_*` companion and just fall back to the existing GPS+submersion
  classifier.

### Phone logger — box-replacement CSV recording (`Location/PhoneLogger.swift`)

"Phone logger" card in the GPS tab (v1.0.55, port of Android's
`PhoneLoggerCore`): records the iPhone's GPS **plus raw accel/gyro/mag/baro**
into a box-schema CSV pair — `SensPhone_<stamp>.csv` + `GpsPhone_<stamp>.csv`
in `Documents/`. Names start with `Sens`/`Gps` so the Replay pickers list
them; **byte-compatible with the Android `SensPhone_*`/`GpsPhone_*` files**,
so recordings are interchangeable across the apps.

- **Timebase**: both files share one `Time [10ms]` tick clock from
  `ProcessInfo.systemUptime` (CoreMotion `CMLogItem.timestamp` is the same
  since-boot domain; GPS rows stamp uptime at arrival, like
  `GpsCore.monotonicMs`). A `# SYNC epoch_ms=… tick_ms=0` anchor after each
  header (Time-column unit, tickDiv=1) gives Replay drift-free "Phone-clock
  sync" alignment.
- **Apple raw-accel sign trap**: `CMAccelerometerData` is −(specific
  force)/g — flat on a table Apple reads z = −1 g where Android/the ST box
  read +1000 mg — so acc converts as **mg = −g × 1000**. Gyro (rad/s →
  mdps) and magnetometer (µT → mgauss, ×10) match conventions, no flip.
  Pressure kPa×10 = mB; `T ['C]` constant 20 °C.
- **No blank fields ever** — Android's `parseSensorStream` is strict (one
  blank field fails the whole file there) and these CSVs travel
  cross-platform, so sens rows are held until gyro + mag (+ baro when
  present) have each reported; no barometer → constant 1013.25 mB.
- IMU at ~100 Hz on one serial `OperationQueue` (all sensor callbacks +
  file IO — no locks); sens rows batched 25 per FileHandle write; row
  counters published to SwiftUI every 50 rows.
- **GPS + backgrounding**: fixes ride `GpsCore`'s CoreLocation stream via a
  `PhoneLogger.shared.onFix(loc)` hook in `didUpdateLocations` (same
  pattern as the RaceUplink/PhoneRider hooks). `start()` starts `GpsCore`
  if idle — its background-location delivery is what keeps the sensor
  stream alive with the screen locked; `stop()` tears the reader down only
  if the logger started it (the GPS tab's old built-in `iPhoneGps_*` CSV
  recorder that also drove `GpsCore` was removed in v1.0.59 — the Phone
  logger is its superset).
- Mount guidance (shown in the card): phone flat on the board, top edge
  toward the nose — device axes then match the box's Y-nose convention.

### Analyze tab — on-device ride analysis (v1.0.56+)

The realization of the Phase-2 classifier deferred in the *Watch IMU logging*
section — but computed **on the phone**, fully offline. `Data/ImuAnalysis.swift`
(engine) + `UI/ImuAnalysisScreen.swift` (UI); built for **both** iOS and
Android (the Android peer is `data/ImuAnalysis.kt` + `ui/ImuAnalysisScreen.kt`,
numerically identical — validated byte-for-byte against the same file).

- **Inputs.** `ImuAnalysis.fromPhoneLogger(sensURL:gpsURL:)` reads a phone-logger
  `SensPhone_*`/`GpsPhone_*` pair; `fromWatch(imuURL:gpsURL:)` reads an
  Apple-Watch `WatchImu_*` motion stream + its ride GPS. `ImuRecording.scan()`
  lists both from `Documents/` + `Documents/WatchRides/`.
- **Pipeline (`core`).** Signed per-axis `userAcceleration` (NOT magnitude —
  rectifying doubles a single-axis stroke's fundamental) → decimate to ~25 Hz →
  **STFT** (radix-2 Cooley-Tukey FFT, Hann, 10 s window / 1 s hop) → per-second
  rhythmicity (band concentration 0.35–1.3 Hz vs 0.1–4 Hz), prominence, cadence;
  a time-domain **band-pass RMS** (difference-of-moving-averages) gives stroke
  energy that decays to ~0 on a dead tail. **Otsu** thresholds split the axes;
  classify per second into **GLIDE** (speed ≥ 12 km/h), **PADDLE/PUMP**
  (energetic AND rhythmic), or **WAIT**, then median-filter + absorb sub-20 s
  runs into neighbours. Board **pitch/roll** come from a pseudo-tared gravity
  vector (Rodrigues rotation).
- **UI.** A per-second **mode strip** + cadence + board-angle + GPS-speed line
  charts (SwiftUI `Canvas`), on one shared timeline. **Pinch-to-zoom**
  (`MagnificationGesture`, iOS; `transformable`, Android) widens the panels
  inside a horizontal `ScrollView` so a long session is inspectable. Detail is
  presented via `.fullScreenCover(item:)`, NOT a `NavigationLink` — the tab
  lives in the system tab bar's **"More"** overflow (>5 tabs), and `@State`
  works there (proven by the Race tab's sheets) while a nested `NavigationStack`
  produced a double back button.
- **Android "More" nav parity.** iOS gets the system More overflow for free;
  Android's `MainNav.kt` was rewritten to match — 4 primary tabs + a **More**
  `NavigationBarItem` opening a `ModalBottomSheet` of the overflow tabs
  (Merge/Race/Analyze/GpsDebug).
- **Big-file cost (Android).** A 127 MB / 1.6 M-row `SensPhone` parsed as
  `List<SensorRow>` OOMs Android's ~268 MB heap — the Kotlin port streams a
  two-pass `DoubleArray` parse + in-place userAccel + sliding-sum moving average
  instead. iOS has no such limit but uses the same streaming shape.

### GPS Debug tab — u-blox UBX survey over BLE

Live u-blox diagnostics for antenna selection/mounting, bridged over the box's
BLE link (no cable). Port of the desktop `gps-debug` survey. Files:
`BLE/GpsDebugModel.swift` (UBX parser + NAV/MON decoders + poll scheduler + CSV
writer), `UI/GpsDebugScreen.swift` (the tab). Wiring notes:

- **Protocol.** Two firmware opcodes on the same FileCmd char: `0x0D`
  GPS_BRIDGE `<u8 on>` and `0x0E` GPS_TX `<raw UBX>`. While the bridge is on the
  box relays raw UBX reply frames back as **FileData notifies**. `BleClient`
  holds a `bridgeActive` flag; when set, `onNotification` diverts FileData bytes
  to a new `.ubxFrame(Data)` event **before** the `op` state machine — the survey
  and a FileSync READ can't share the FileData channel, so the survey refuses to
  start unless the worker is idle, and `FileSyncViewModel` gates keep-synced /
  the manual queue on `gpsSurveyActive`.
- **Survey loop.** `GpsDebugModel` runs a 1 Hz `Timer` on `RunLoop.main`: each
  tick flushes the epoch collected over the last second (writes CSV rows +
  a live-summary line) then re-sends the five poll frames (NAV-PVT/DOP/SAT/SIG,
  MON-RF). `feed(_:)` is called from `onEvent` (@MainActor) so parsing, epoch
  accumulation, and file IO all run single-threaded on main — no locks.
- **Output.** `<label>_gnss_epoch.csv` + `<label>_gnss_signals.csv` in
  `Documents/`, byte-identical schema to the desktop tool.
- **Non-destructive.** Only zero-length polls are sent; the box enables UBX
  output in the receiver's RAM layer only (reverts on power-cycle). Needs box
  firmware ≥ v0.0.18 (bridge opcode + MAX-M10S UBX-output fix); older firmware
  ignores 0x0D and the survey shows "no NAV-PVT reply".

## Race mode — live position uplink (`Location/RaceUplink.swift`)

Race-day streaming to the desktop app's **Race** tab (`race.rs`, which
owns the wire doc): a card at the bottom of the GPS tab (rider name +
desktop `ip:port` + source picker, persisted in `UserDefaults
race.*`) toggles an `NWConnection` UDP uplink firing one JSON datagram
per fix, throttled to 5 Hz — `{"v":1,"rider":..,"src":"phone|watch",
"lat":..,"lon":..,"kmh":..,"deg":..,"ts":<epoch ms>,"batt":0-100}`,
default port 47777 (shared with Android `RaceUplink.kt`).

- **iPhone GPS source**: hooked in `GpsCore.didUpdateLocations`;
  enabling race mode auto-`start()`s `GpsCore` so there's no separate
  Start tap to forget.
- **Apple Watch source**: the phone pushes `raceRelay` + the full
  target config (`raceRider`/`raceHost`/`racePort`) via application
  context; `WatchSync` (watch) then streams each 1 Hz
  `WatchGpsLogger.writeRow` fix while a recording runs — via
  `sendMessage(["raceFix": …])` → `WatchRideReceiver` → phone
  `RaceUplink` when the phone is reachable, or **directly over the
  watch's own WiFi** (`WatchRaceUplink.swift`, NWConnection UDP, same
  wire format, watch battery %) when it isn't — watch-only riders
  work on venue WiFi after one setup moment near the phone. Config
  persists in watch UserDefaults. A cellular watch can't reach a
  private LAN address; phone-free-over-LTE needs the future relay.
  Off by default so ordinary rides don't spend battery.
- `sendFix` is gated on the *configured* source so a running iPhone
  GPS can't inject fixes into a watch-sourced race.
- New files must be registered in `project.pbxproj` by hand (explicit
  file references, no synchronized folders) — `RaceUplink.swift` is
  IDs `A1…0404`/`A1…0414`.

## iOS BLE specifics that differ from Android

- iOS doesn't expose stable MAC addresses; `CBPeripheral.identifier` is a `UUID` scoped to this app installation. The view-model uses that UUID instead of an address. To connect, the client must hold the `CBPeripheral` reference from the scan — we keep a `[UUID: CBPeripheral]` map populated during `centralManager(_:didDiscover:advertisementData:rssi:)`.
- iOS hides the CCCD write — `setNotifyValue(true, for:)` does it for you. We use the `peripheral(_:didUpdateNotificationStateFor:error:)` callback as the "we're subscribed, emit `.connected`" signal (same role as the Android port's `onDescriptorWrite`).
- `writeValue(_:for:type: .withoutResponse)` is fire-and-forget on iOS — no completion callback (in contrast to write-with-response). The 500 ms post-START_LOG sleep is preserved because the write-without-response on the underlying L2CAP socket can return before the bytes are actually transmitted, same race as Android/Rust.
- iOS BLE scanning with `withServices: nil` requires the app to be in the foreground. That's fine for this app. We filter by `CBAdvertisementDataLocalNameKey == "PumpTsueri"` in the discover callback, mirroring the Android/desktop clients.

## Box-sourced board-orientation calibration (v1.0.17+) — `Calibration.swift`

The four calibration fields (`nosePlusY`, `magOffsetMg`, `angleZeroRef`
+ `angleZeroAtEpoch`, `headingBiasDeg`) live on the BOX in `CAL.CFG`
(firmware v0.0.37+) — the app still mirrors them into `UserDefaults`
via `AgentConfig`, but the BOX is now the source of truth. That means
a "Zero here" or nose toggle done on the iPhone is visible to the
Desktop and Android on their next connect (and vice versa).

- **Wire format** (32-byte blob, per-field `validMask`, tenths-of-degree
  fixed point, LE `UInt64` epoch ms): `MovementLogger/BLE/Calibration.swift`
  — `encode(_:)` / `decode(_:)`. 1:1 port of desktop
  `stbox-viz-gui/src/calibration.rs`; byte-compatible.
- **On connect**: `FileSyncViewModel.queryCalibration(attempt:)` chains
  a `CAL_GET (0x13)` after the GPS-power reply lands, same
  self-guarded slot pattern as `GET_MODE` / `GET_VERSION`. Reply →
  `BleEvent.calibration(Data?)` → `onCalibrationBlob` merges each
  non-nil field into the VM's `@Published` props + `AgentConfig`;
  fields the box hasn't set yet leave the local value alone. Legacy
  firmware (< v0.0.37) times out silently (`.calibration(nil)`) — the
  app keeps its UserDefaults as before.
- **On any user tap**: `pushCalToBox(_:)` fires `CAL_SET (0x14)` with
  ONLY the touched field's bit set — the box's per-field merge leaves
  the other fields alone. Call sites: `zeroBoardAngles`,
  `clearBoardAngleZero`, `setDirectionSouth`, `setDirectionFromPhone`,
  `resetMagCalibration`, and the new `confirmNoseUp(_:)` (which pushes
  nose + nudged bias atomically in one blob — the strict single-op
  BLE slot rejects a second write while the first is in flight, so
  the two-field combined send matters).
- **Deliberately not synced**: continuous mag-offset auto-cal. Would
  churn `CAL.CFG` on every convergence step. Only the explicit
  `resetMagCalibration` tap pushes zeros. Desktop + Android make the
  same tradeoff.

## BLE protocol gotchas (carried over from the Rust/Kotlin clients)

- Subscribe to FileData notifications **once per connection**, not per op. Subscribing per op risks losing the first packet if the box notifies before we're ready.
- READ's first packet may be a 1-byte status error OR file content. Disambiguate: first packet, exactly 1 byte, AND byte ∈ {0xB0, 0xE1, 0xE2, 0xE3} → treat as error. Otherwise treat as content. CSV/log files start with ASCII text (well below 0x80) so the test is unambiguous in practice.
- LIST may not deliver its terminator `\n` on flaky links. Inactivity fallback: ≥1 row seen and 500 ms with no new bytes → treat as `listDone`. Without this fallback the next op trips the "another op is in flight" guard for 20 s.
- The ~500 ms settle after START_LOG is kept (write-without-response returns when bytes are queued, not transmitted), but `startSession()` no longer queues a Disconnect — current firmware (v0.0.7+) opens a fixed-duration session and stays connected instead of rebooting. The same 500 ms guard still matters before any *other* follow-up command.

## CSV-schema gotchas

- **Two firmware schemas, accepted side-by-side.** Pre-22.4.2026 firmware writes `Time [10ms]`, `AccX [mg]`, `GyroX [mdps]`, `MagX [mgauss]`, `P [mB]`, `T ['C]`, `UTC`, `Lat`, `Lon`, `Alt [m]`, `Speed [km/h]`, `Course [deg]`, `Fix`, `NumSat`, `HDOP`, `Voltage [mV]`, `SOC [0.1%]`, `Current [100uA]`. Post-22.4.2026 firmware switched to compact names: `ms`, `ax_mg`, `gx_mdps`, `mx_mg`, `p_hPa`, `t_C`, `utc`, `lat`, `lon`, `alt_m`, `speed_kmh`, `course_deg`, `fix_q`, `nsat`, `hdop`, `v_mV`, `soc_x10`, `i_x100uA`. `CsvParsers` accepts BOTH via `HeaderMap.idxAny(...)` taking variadic candidates. The compact `ms` column is in raw milliseconds, so the parser divides by 10 (`tickDiv = 10.0`) to keep `ticks` in the 10ms-unit the interpolator + fusion code expect. Units are otherwise numerically identical (mg ≡ mgauss, mbar ≡ hPa).
- **Tolerate corrupted rows.** Real SD-card recordings sometimes contain empty fields or jammed values like `-30-123` when the firmware is interrupted mid-write. The earlier parser bailed on the first bad row (throwing "not a float"); this would discard an entire otherwise-good session of ~6000 rows because ~30 were corrupt. Per-row parse errors now `continue` silently instead of throwing. The file loads with the bad rows dropped.
- **Apple-Watch GPS header (v1.0.23).** The watch's own `WatchGpsLogger` writes bracketed column names — `Lat [deg]`, `Lon [deg]`, `SpeedKMh` — which the box-firmware exact-match `idxAny("Lat","lat")` / `idxAny(…,"speed_kmh")` did NOT recognise, so `parseGpsFile` would throw on a watch ride CSV. `parseGpsText` now also accepts `"Lat [deg]"` / `"Lon [deg]"` / `"SpeedKMh"`, so the Rides map (and Replay) read watch rides unchanged. The comment in `WatchGpsLogger.swift` claiming the parsers "read it unchanged" is only true since this fix.
- **Watch barometer columns (v1.0.49).** The watch GPS header gained two trailing columns — `Pressure [hPa]`, `BaroAlt [m]` — from the watch's `CMAltimeter` (a *separate* sensor from the IMU's `CMMotionManager`), stamped onto each 1 Hz row. Appending is safe: the field split is `omittingEmptySubsequences: false` and the parser is header-name indexed, so old 11-column watch files and the box schemas are unaffected, and a blank water-temp (dry) doesn't shift the new columns. This is Phase-1 *capture* — the pressure feeds a future watch height-above-water computation (the box's `Baro.heightAboveWaterM` + `FusionHeight` fused with the IMU accel from `WatchImu_*.csv`); nothing reads the columns yet. `pressure` is `kPa × 10` → hPa/mbar to match the box's `p_hPa`.

## Numerics gotchas

- `GpsMath.rollingMedianSimple` allocates a buffer of `w + 1` (not `w`) because a centred window at the array's middle covers `2·half + 1` elements — odd windows fit `w`, even windows need one more slot. Tests cover both parities in the Android repo.
- `Fusion.noseAngleSeriesDeg` uses a 60 s rolling median for drift baseline. At 100 Hz that's a 6000-sample window — the simple O(n·w·log w) impl is unusable on long sessions. `GpsMath.rollingMedian` auto-dispatches to the sorted-array fast path for windows ≥ 32 and inputs ≥ 64.
- Madgwick output is sensitive to mount orientation. The desktop GUI has a `--mount mast|deck` flag in `animate_cmd.rs`; the Replay tab currently assumes the same mount as `animate_cmd.rs`'s default (Y axis along the board nose). If a future user reports inverted pitch, surface this as a UI toggle.
- **ThreadX HSI clock drift**: the SensorTile.box's ThreadX runs on the internal RC oscillator (±1 % accuracy) so its 10 ms tick drifts ~7 s over a 21-min session. Sensor-side absolute UTC MUST be built by piecewise-linear interpolation across GPS row `hhmmss.ss` strings (see `ReplayViewModel.interpolateSensorAbsTimes`), not by single-anchor extrapolation. Same trick the Rust `animate_cmd.rs::resolve_at_window` uses.

- **Phone-clock `# SYNC` anchors (primary alignment, firmware v0.0.10+)**: the firmware's `SET_TIME` handler appends `# SYNC epoch_ms=<u64> tick_ms=<u32>` comment lines into the open `Sens*/Gps*.csv` on every connect (`tick_ms` = the box's raw `HAL_GetTick()` ms — the SAME clock as the `ms` column). `CsvParsers.parseSyncAnchors` pulls these into `[SyncAnchor]` (tick in 10 ms units via the same `÷tickDiv` as rows; sorted + deduped). When a sensor/GPS CSV carries anchors, `ReplayViewModel.applyVideoAndSlice` builds abs-times via `absTimesFromSyncAnchors` (piecewise-linear across anchors, constant 10 ms/tick outside) **in preference to** the GPS `hhmmss.ss` path. Why this is better: the anchors are the phone's wall clock — the SAME clock domain as the replay video's `creation_time` — so they remove the cross-clock skew between the box GPS clock and the iPhone video clock, are drift-free across a session (one anchor per connect), need NO GPS fix, and make the alignment date / midnight-rollover handling irrelevant (the anchor carries absolute epoch directly). The GPS-`hhmmss.ss` interpolation remains the fallback for legacy / never-connected files; `vm.alignmentSource` surfaces which path is active ("Phone-clock sync — exact" vs "GPS-derived time" vs "Approximate …"). The data-row parsers skip the `#` line naturally (it fails the float parse and `continue`s), so anchor parsing is a cheap separate pass that never disturbs row parsing.

- **Auto-pick by recorded time**: `autoPickMatchingCsvs` now has three tiers — (1) **wall-clock coverage**: `wallClockCoverage` maps a candidate file's first/last row tick → epoch via its `# SYNC` anchors; the file whose recording span contains the video's `creation_time` IS the session, no filename guessing; (2) **numeric-suffix companion**: `SENS002 ↔ GPS002` (the desktop's canonical pairing) pulls the partner of a coverage-matched file across; (3) the legacy **filename-token overlap + ±7-day mod-date** heuristic as fallback. The summary line shows "(by recorded time)" when tier 1 hit.

## Memory and references

The full BLE wire spec, the source-Rust-project map, and the Phase-2 architecture deferral live in the Android project's memory under `~/.claude/projects/-Users-zdavatz-Documents-software-movement-logger-android/memory/`. Check `MEMORY.md` there for the index before re-deriving any of it.
