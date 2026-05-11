# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

iOS port of `~/Documents/software/movement_logger_android` (Jetpack Compose + Kotlin), which is itself an Android port of the Movement Logger desktop app at `~/software/fp-sns-stbox1/Utilities/rust`. Talks to the PumpTsueri SensorTile.box over BLE and downloads its CSV recordings. SwiftUI + CoreBluetooth, no external dependencies.

Phase 1 (current): BLE FileSync only — scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG, save downloaded files to the app's `Documents/` directory (exposed in the Files app via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).

Phase 2+ (not started): the ~7.5 kLOC of Rust numerics from `stbox-viz/` (Madgwick fusion, baro height, GPS, butterworth, board-3D, plotly HTML, GIF animation). Architecture choice between Swift-rewrite and Rust-via-C-FFI is intentionally deferred until Phase 1 is verified on a real device.

## Build & run

```sh
xcodebuild -project MovementLogger.xcodeproj -scheme MovementLogger \
    -destination 'generic/platform=iOS' -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO          # CI-style compile check, no signing
```

For on-device runs: open `MovementLogger.xcodeproj` in Xcode, set a development team under the target's Signing & Capabilities pane (the project is created with `CODE_SIGN_STYLE = Automatic` and no team), then ⌘R. Simulator builds work too but BLE is non-functional in the simulator — pair a real device.

Targets: iOS 17.0+, universal (iPhone + iPad). Bundle id `ch.pumptsueri.movementlogger`. Marketing version is bumped in the target's Debug + Release `MARKETING_VERSION` settings.

## Architecture

Single screen, three layers — mirrors the Android port one-for-one:

- `MovementLogger/BLE/FileSyncProtocol.swift` — UUIDs, opcodes, status bytes, `BleCmd`/`BleEvent` enums. Authoritative spec is the firmware's `ble_filesync.c`; the Rust client's `ble.rs` and the Kotlin client's `FileSyncProtocol.kt` are the reference host implementations.
- `MovementLogger/BLE/BleClient.swift` — single-worker state machine. CoreBluetooth delegate callbacks (on a dedicated serial `DispatchQueue`) marshal raw events into one `AsyncStream<WorkerEvent>`; a single `Task` consumes from that stream and holds `CurrentOp` (`.idle` / `.listing` / `.reading` / `.deleting`). Watchdog ticks every 200 ms are posted into the same stream so op-state mutation stays single-tasked without locks. Design mirrors the Kotlin/Rust clients — read those before changing behaviour here.
- `MovementLogger/UI/FileSyncViewModel.swift` + `MovementLogger/UI/FileSyncScreen.swift` — SwiftUI binds to an `@Observable` view-model that consumes `ble.events` (an `AsyncStream<BleEvent>`). Bluetooth permission is requested implicitly via the `NSBluetoothAlwaysUsageDescription` Info.plist key (set as a build setting) — iOS prompts the first time `CBCentralManager` is instantiated.

Downloaded files are saved to the app's `Documents/` directory under the original filename from LIST. `UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES` (both build settings) surface them in the system Files app under "On My iPhone → MovementLogger" so the user can move/share them.

## iOS BLE specifics that differ from Android

- iOS doesn't expose stable MAC addresses; `CBPeripheral.identifier` is a `UUID` scoped to this app installation. The view-model uses that UUID instead of an address. To connect, the client must hold the `CBPeripheral` reference from the scan — we keep a `[UUID: CBPeripheral]` map populated during `centralManager(_:didDiscover:advertisementData:rssi:)`.
- iOS hides the CCCD write — `setNotifyValue(true, for:)` does it for you. We use the `peripheral(_:didUpdateNotificationStateFor:error:)` callback as the "we're subscribed, emit `.connected`" signal (same role as the Android port's `onDescriptorWrite`).
- `writeValue(_:for:type: .withoutResponse)` is fire-and-forget on iOS — no completion callback (in contrast to write-with-response). The 500 ms post-START_LOG sleep is preserved because the write-without-response on the underlying L2CAP socket can return before the bytes are actually transmitted, same race as Android/Rust.
- iOS BLE scanning with `withServices: nil` requires the app to be in the foreground. That's fine for this app. We filter by `CBAdvertisementDataLocalNameKey == "PumpTsueri"` in the discover callback, mirroring the Android/desktop clients.

## BLE protocol gotchas (carried over from the Rust/Kotlin clients)

- Subscribe to FileData notifications **once per connection**, not per op. Subscribing per op risks losing the first packet if the box notifies before we're ready.
- READ's first packet may be a 1-byte status error OR file content. Disambiguate: first packet, exactly 1 byte, AND byte ∈ {0xB0, 0xE1, 0xE2, 0xE3} → treat as error. Otherwise treat as content. CSV/log files start with ASCII text (well below 0x80) so the test is unambiguous in practice.
- LIST may not deliver its terminator `\n` on flaky links. Inactivity fallback: ≥1 row seen and 500 ms with no new bytes → treat as `listDone`. Without this fallback the next op trips the "another op is in flight" guard for 20 s.
- After START_LOG, sleep ~500 ms before any subsequent Disconnect — write-without-response returns when bytes are queued, not when transmitted; a fast Disconnect can tear the link down before the opcode hits the air.

## Memory and references

The full BLE wire spec, the source-Rust-project map, and the Phase-2 architecture deferral live in the Android project's memory under `~/.claude/projects/-Users-zdavatz-Documents-software-movement-logger-android/memory/`. Check `MEMORY.md` there for the index before re-deriving any of it.
