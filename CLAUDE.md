# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

iOS port of `~/Documents/software/movement_logger_android` (Jetpack Compose + Kotlin), which is itself an Android port of the Movement Logger desktop app at `~/Documents/software/fp-sns-stbox1/Utilities/rust`. Talks to the PumpTsueri SensorTile.box over BLE, downloads CSV recordings, and replays them time-synced against a phone-recorded video. SwiftUI + CoreBluetooth + AVKit, no external dependencies.

Two tabs:

- **Sync** — scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG. Downloaded files land in the app's `Documents/` (exposed in the Files app via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
- **Replay** — pick a video (Photos picker OR a `.mov`/`.mp4`/`.m4v` already in `Documents/`) + a `Sens*.csv` + a `Gps*.csv` from the Sync tab's downloads, watch the four overlay panels (speed, pitch / Nasenwinkel, height above water, GPS track) update against the video playhead, then optionally export a V-stack composite MOV (source video on top, panels below with animated cursors) — the iOS equivalent of the desktop's `combined_*.mov`. The composite is saved to `Documents/combined_<basename>.mov` AND added to the Photos library.

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

## Signing

`DEVELOPMENT_TEAM = 4B37356EGR` (ywesee GmbH) is set as a build setting on both Debug and Release. `CODE_SIGN_STYLE = Automatic`, so Xcode/`xcodebuild -allowProvisioningUpdates` fetches the right provisioning profile from the App Store Connect / developer portal using the developer certificate in the macOS keychain (`Apple Development: Zeno Davatz` or `Apple Distribution: ywesee GmbH`). Apple API credentials for the team live at `~/.apple/credentials.json` + `~/.apple/AuthKey_*.p8`.

## Icon

`MovementLogger/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` is the iOS app icon: a 1024×1024 composite of the Android adaptive icon's foreground (orange/cyan/purple hydrofoil) over the adaptive icon's background color `#F8FAFC`. Regenerate from the Android source:

```sh
python3 -c "
from PIL import Image
fg = Image.open('../movement_logger_android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png').convert('RGBA')
bg = Image.new('RGBA', (1024, 1024), (0xF8, 0xFA, 0xFC, 0xFF))
bg.alpha_composite(fg.resize((1024, 1024), Image.LANCZOS))
bg.convert('RGB').save('MovementLogger/Assets.xcassets/AppIcon.appiconset/Icon-1024.png', 'PNG', optimize=True)
"
```

## Architecture

```
MovementLogger/
├── MovementLoggerApp.swift          @main → MainNav (TabView)
├── BLE/
│   ├── FileSyncProtocol.swift       UUIDs, opcodes, status bytes
│   └── BleClient.swift              single-worker CoreBluetooth state machine
├── Data/                            Numerics, ported from Android `data/` (which is in turn from `stbox-viz/*.rs`)
│   ├── CsvParsers.swift             Sens / Gps / Bat CSV → typed rows
│   ├── GpsTime.swift                hhmmss.ss → absolute UTC ms
│   ├── VideoMetadata.swift          AVAsset creationDate / duration
│   ├── GpsMath.swift                haversine, position-derived speed, rolling-median (sorted-array fast path)
│   ├── Butterworth.swift            4th-order LP design + filtfilt
│   ├── EulerAngles.swift            quat → roll/pitch/yaw + gimbal-lock regions
│   ├── Madgwick.swift               6DOF IMU AHRS + nose-angle series
│   ├── Baro.swift                   GPS-anchored TC'd-pressure height
│   └── FusionHeight.swift           α-β baro + body-frame acc complementary
├── UI/
│   ├── MainNav.swift                TabView scaffold (Sync / Replay)
│   ├── FileSyncViewModel.swift      Sync state machine (@Observable)
│   ├── FileSyncScreen.swift         Sync tab UI
│   ├── ReplayViewModel.swift        CSV + fusion pipeline orchestration + ride-window slicing
│   └── ReplayScreen.swift           Replay tab UI + 4 SwiftUI Canvas panels + export button
└── Export/
    └── CompositeExporter.swift      V-stack composite MOV via AVAssetExportSession + CA tool
```

### Sync tab — BLE FileSync

- `BLE/FileSyncProtocol.swift` mirrors the Kotlin port one-for-one. Authoritative spec is the firmware's `ble_filesync.c`; the Rust client's `ble.rs` and the Kotlin `FileSyncProtocol.kt` are reference host implementations.
- `BLE/BleClient.swift` — single-worker state machine. CoreBluetooth delegate callbacks (on a dedicated serial `DispatchQueue`) marshal raw events into one `AsyncStream<WorkerEvent>`; a single `Task` consumes from that stream and holds `CurrentOp` (`.idle` / `.listing` / `.reading` / `.deleting`). Watchdog ticks every 200 ms are posted into the same stream so op-state mutation stays single-tasked without locks.
- `UI/FileSyncScreen.swift` — SwiftUI binds to an `@Observable` view-model that consumes `ble.events` (an `AsyncStream<BleEvent>`). Bluetooth permission is requested implicitly via the `NSBluetoothAlwaysUsageDescription` build setting — iOS prompts the first time `CBCentralManager` is instantiated. Downloaded files land in `Documents/` under the original filename; `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` surface them in the system Files app under "On My iPhone → MovementLogger".

### Replay tab — data on top of video

`ReplayViewModel` keeps the parsed sensor/GPS as `fullSensorRows`/`fullGpsRows` (`@ObservationIgnored` backing storage). On any pick (sensor, GPS, video), `applyVideoAndSlice()` runs and:

1. Picks the **alignment date** from the video's `creation_time` if loaded, else today. This replaces the v1 "today's date" assumption — without it, sensor data recorded on a different day from when the user opens the app would land 24h+ off and the cursor would never move.
2. Re-parses each GPS row's `hhmmss.ss` against that date → `fullGpsAbsTimesMs`.
3. Computes the **ride window** `[video.creation_time, video.creation_time + video.duration]`. Binary-searches GPS rows to find the slice that overlaps. Slices `gpsRows`, `gpsAbsTimesMs`, `speedSmoothedKmh` to the window.
4. Slices `sensorRows` by tick range bracketed by the GPS slice (ThreadX ticks are shared between streams, so this stays correct under HSI drift).
5. Builds `sensorAbsTimesMs` by **piecewise-linear interpolation across GPS (tick → utcMs) anchor pairs** (mirroring `animate_cmd.rs`'s GPS-anchored time-alignment). v1 extrapolated from a single anchor at a fixed 10 ms/tick and accumulated ~7 s of drift over a 21-min session — that's enough to desync the cursor on Pitch/Height panels visibly.

Once both sensor + GPS slices exist, `maybeComputeFusion()` runs the full pipeline on a detached `Task.userInitiated`:

1. `Fusion.detectDtSeconds` → sample rate
2. `Fusion.computeQuaternions` (β = 0.1, matches `animate_cmd.rs:78`)
3. `Fusion.noseAngleSeriesDeg` — 1 s + 60 s rolling-median drift correction. `GpsMath.rollingMedian` dispatches to a sorted-array fast path for windows ≥ 32 / inputs ≥ 64 (the 60 s × 100 Hz = 6000-sample baseline would be unusable on the simple O(n·w·log w) path).
4. `Baro.heightAboveWaterM` — GPS-anchored water reference, falls back to session-max pressure when no stationary anchors exist
5. `FusionHeight.fusedHeightM` — α-β complementary baro + body→world-rotated acc

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

Two gotchas worth remembering — both were the source of multiple bad first attempts:

1. **`videoLayer.frame` MUST equal `parentLayer.frame` MUST equal `videoComp.renderSize`.** When the videoLayer is a smaller sub-region of parent, the CA tool letterboxes the renderSize-sized video composition output to fit inside the videoLayer's bounds, leaving a black gap. To position the video within a larger canvas, set `videoLayer.frame == parentLayer.frame == renderSize` and use the layer instruction's transform to place the source frame in the top region of renderSize. Opaque sibling sublayers (panel `CALayer`s, added AFTER `videoLayer`) cover the empty bottom of the video render.
2. **`UIGraphicsImageRendererFormat.scale` defaults to device scale (3× on iPhone).** For offline export rendering, this allocates `3× × 3×` pixels — a 1080×3200 canvas becomes a 31 MP bitmap. Set `format.scale = 1` for any export-only render to keep it at native pixel dimensions.

Progress is polled from `session.progress` on a background `Task` every 100 ms — `AVAssetExportSession` exposes progress as a property rather than a callback.

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

## Numerics gotchas

- `GpsMath.rollingMedianSimple` allocates a buffer of `w + 1` (not `w`) because a centred window at the array's middle covers `2·half + 1` elements — odd windows fit `w`, even windows need one more slot. Tests cover both parities in the Android repo.
- `Fusion.noseAngleSeriesDeg` uses a 60 s rolling median for drift baseline. At 100 Hz that's a 6000-sample window — the simple O(n·w·log w) impl is unusable on long sessions. `GpsMath.rollingMedian` auto-dispatches to the sorted-array fast path for windows ≥ 32 and inputs ≥ 64.
- Madgwick output is sensitive to mount orientation. The desktop GUI has a `--mount mast|deck` flag in `animate_cmd.rs`; the Replay tab currently assumes the same mount as `animate_cmd.rs`'s default (Y axis along the board nose). If a future user reports inverted pitch, surface this as a UI toggle.
- **ThreadX HSI clock drift**: the SensorTile.box's ThreadX runs on the internal RC oscillator (±1 % accuracy) so its 10 ms tick drifts ~7 s over a 21-min session. Sensor-side absolute UTC MUST be built by piecewise-linear interpolation across GPS row `hhmmss.ss` strings (see `ReplayViewModel.interpolateSensorAbsTimes`), not by single-anchor extrapolation. Same trick the Rust `animate_cmd.rs::resolve_at_window` uses.

## Memory and references

The full BLE wire spec, the source-Rust-project map, and the Phase-2 architecture deferral live in the Android project's memory under `~/.claude/projects/-Users-zdavatz-Documents-software-movement-logger-android/memory/`. Check `MEMORY.md` there for the index before re-deriving any of it.
