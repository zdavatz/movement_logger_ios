# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

iOS port of `~/Documents/software/movement_logger_android` (Jetpack Compose + Kotlin), which is itself an Android port of the Movement Logger desktop app at `~/Documents/software/fp-sns-stbox1/Utilities/rust`. Talks to the PumpTsueri SensorTile.box over BLE, downloads CSV recordings, and replays them time-synced against a phone-recorded video. SwiftUI + CoreBluetooth + AVKit, no external dependencies.

Three tabs (matches the desktop and Android tab order):

- **Live** — when connected to a PumpLogger-firmware box (advertises as `STBoxFs`), renders the 0.5 Hz SensorStream snapshot: accel / gyro / mag / baro / GPS readouts + two `Canvas` sparklines (acc magnitude, pressure). Subscription is automatic on Connect. Legacy PumpTsueri firmware doesn't expose the SensorStream characteristic — the tab stays empty with a status-line log entry.
- **Sync** — scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG. Downloaded files land in the app's `Documents/` (exposed in the Files app via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
- **Replay** — pick a video (Photos picker OR a `.mov`/`.mp4`/`.m4v` already in `Documents/`) + a `Sens*.csv` + a `Gps*.csv` from the Sync tab's downloads, watch the four overlay panels (speed, pitch / Nasenwinkel, height above water, GPS track) update against the video playhead, then optionally export a V-stack composite MOV (source video on top, panels below with animated cursors) — the iOS equivalent of the desktop's `combined_*.mov`. The composite is saved to `Documents/combined_<basename>.mov` AND added to the Photos library.

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

## Signing

`DEVELOPMENT_TEAM = 4B37356EGR` (ywesee GmbH) is set as a build setting on both Debug and Release. `CODE_SIGN_STYLE = Automatic`, so Xcode/`xcodebuild -allowProvisioningUpdates` fetches the right provisioning profile from the App Store Connect / developer portal using the developer certificate in the macOS keychain (`Apple Development: Zeno Davatz` or `Apple Distribution: ywesee GmbH`). Apple API credentials for the team live at `~/.apple/credentials.json` + `~/.apple/AuthKey_*.p8`.

**Duplicate Apple Distribution certs gotcha.** The keychain has three `Apple Distribution: ywesee GmbH (4B37356EGR)` entries (expired 2022, expired 2024, current expires 2027). Xcode auto-picks the latest, but anything that exports by CN alone (e.g. `security export -t identities`, a naive PEM-split script) may grab the FIRST match — which is the expired 2022 one. The CI cert-bundle in `APPLE_CERT_P12_BASE64` was rebuilt to disambiguate by `notAfter` and pick the latest. If you ever need to re-roll the cert secret, use the same disambiguation (sort candidates by `notAfter`, take the last).

## Release (tag-driven CI)

Push `vX.Y.Z` → CI builds, signs, uploads to App Store Connect, and cuts a GitHub release with the IPA attached. Workflow lives at `.github/workflows/release.yml`. Trigger:

```sh
git tag v0.0.6
git push origin v0.0.6
```

The workflow parses the tag (`v0.0.6` → version `0.0.6`, build `6` from the patch component), sed-patches `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` into the pbxproj at build time (so the source on the tagged commit doesn't need to be re-bumped), then runs `xcodebuild archive` → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → `gh release create`. macos-15 runner, automatic signing authenticated with the App Store Connect API key.

Required GitHub Actions secrets (set once via `gh secret set --repo zdavatz/movement_logger_ios`):

- `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8_BASE64` — base64 of `~/.apple/AuthKey_<id>.p8`
- `APPLE_CERT_P12_BASE64` — base64 of slim single-identity `.p12` for `Apple Distribution: ywesee GmbH (4B37356EGR)` (NOT a full keychain export — those exceed GitHub's secret size limit)
- `APPLE_CERT_PASSWORD`, `APPLE_KEYCHAIN_PASSWORD`

Canonical backup of the slim Apple Distribution `.p12` + its password sits in `~/Library/Mobile Documents/com~apple~CloudDocs/ywesee/p12/apple_distribution_ios.{p12,password.txt}` (re-encrypted with modern AES-256 instead of the RC2-40 default that `security export` produces; OpenSSL 3 refuses to read the latter without `-legacy`).

## App Store screenshots

`scripts/resize_screenshots.py` (PIL/LANCZOS) downsizes the four 1320×2868 source screenshots in `screenshots/` to App Store Connect's required sizes: **1290 × 2796** (6.7" iPhone — APP_IPHONE_67, output to `screenshots/store/iphone_67/`) and **1242 × 2688** (6.5" iPhone — APP_IPHONE_65, `screenshots/store/iphone_65/`). The downscale aspect is essentially identical to the source (~0.4%), imperceptible.

**6.5" vs 6.7" gotcha.** The App Store Connect upload UI lists `1284 × 2778` under the 6.5" Display slot — that's a legitimate 6.5"-class size (iPhone 13 Pro Max era). But it is REJECTED by the `APP_IPHONE_67` slot (returns `IMAGE_INCORRECT_DIMENSIONS` and `assetDeliveryState = FAILED`). For 6.7" (modern Pro Max gen 14+) you MUST produce exactly 1290 × 2796. The earlier version of this script targeted 1284 × 2778 for the 6.7" slot and the uploads got stuck in "still uploading" state until re-uploaded at 1290 × 2796.

`scripts/upload_store_screenshots.py` walks the App Store Connect API: App → AppStoreVersion (the one in `PREPARE_FOR_SUBMISSION` etc.) → AppStoreVersionLocalization (prefers English, falls back to whatever is first) → AppScreenshotSet (one per `screenshotDisplayType`, e.g. `APP_IPHONE_67`) → AppScreenshot. JWT signed with the `.p8` API key from `~/.apple/credentials.json`. Idempotent: deletes any screenshots already in each set before re-uploading, so the local PNGs are always the source of truth. Requires the local venv (`python3 -m venv .venv && .venv/bin/pip install Pillow PyJWT cryptography requests`).

**iPad screenshots** live under `screenshots/store/ipad_13/` (2064 × 2752, `APP_IPAD_PRO_3GEN_129`) and are captured directly on the iPad Pro 13-inch (M4) simulator — no resize step. Required because the build is universal (`TARGETED_DEVICE_FAMILY = "1,2"`); without iPad screenshots App Store Connect blocks submission with "Lade einen Screenshot für 13-Zoll-Displays (iPad) hoch".

To capture more iPad screenshots without fighting UI automation: `MainNav.swift` reads `SIMCTL_CHILD_INITIAL_TAB` from the launch env and starts on the named tab. Values: `live` / `sync` / `replay`. Run the simulator with that variable set and the segmented TabView opens straight onto the chosen tab — much more reliable than `cliclick` against the new iPadOS 18 top-of-screen TabView (whose hit area didn't take taps when I tried). Live is the default if the variable is missing, so shipping this behavior costs nothing at runtime.

```sh
xcrun simctl boot "iPad Pro 13-inch (M4)"
SIMCTL_CHILD_INITIAL_TAB=replay xcrun simctl launch <udid> ch.pumptsueri.movementlogger
xcrun simctl io <udid> screenshot screenshots/store/ipad_13/02_replay_empty.png
```

Note: the iPad simulator's Sync screen logs `ERROR: BLE unsupported on this device` because the simulator has no Bluetooth radio — looks slightly ugly but acceptable. On a physical iPad the line wouldn't appear.

## App Previews (videos)

`scripts/upload_store_previews.py` walks `App → AppStoreVersion → AppStoreVersionLocalization → AppPreviewSet → AppPreview`. Mirrors `upload_store_screenshots.py` one-for-one but uses the `/appPreviews` + `/appPreviewSets` endpoints. Idempotent — deletes existing previews per slot before re-uploading.

**Different prefix scheme from screenshots.** `AppScreenshotSet.screenshotDisplayType` uses values like `APP_IPHONE_67`. `AppPreviewSet.previewType` uses the SAME slot identifier but WITHOUT the `APP_` prefix: `IPHONE_67`, `IPHONE_65`, `IPAD_PRO_3GEN_129`. Apple's API quirk; easy to miss when adapting one script from the other.

**Strict spec for App Preview files** (Apple silently sets `assetDeliveryState=FAILED` if any of these don't line up — same failure mode as wrong-dimension screenshots):

- Duration **15–30 s** (inclusive on both ends)
- 30 / 25 / 24 fps (NOT 60)
- H.264 video + AAC audio (or no audio)
- Resolution must exactly match the slot:
  - `IPHONE_67` / `IPHONE_65`: 1080×1920, 886×1920, 1920×1080, 1920×886
  - `IPAD_PRO_3GEN_129`: 1200×1600, 1600×1200

**Source-of-truth files live in `screenshots/store/previews/`.** The same MP4 goes to both iPhone slots (the iPad slot is currently skipped because the composite layout doesn't fit 1200×1600 nicely). The committed clips came from the app's own composite-MOV export (1080×3200 native), then `ffmpeg`-transcoded:

- Pillarboxed to 1080×1920 — keeps all 4 data panels visible at the cost of 216 px black bars left+right. Cropping the source to fit 1080×1920 would cut out the panels, which defeats the entire point of the App Preview for this app.
- Trimmed (>30 s sources) or slowed via `setpts` + `atempo` (<15 s sources) into the 15-30 s window.

```sh
# Trim+pillarbox a long composite to 30 s:
ffmpeg -ss 0 -t 30 -i combined.mov \
    -vf "scale=648:1920,pad=1080:1920:216:0:black" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -b:v 10M -movflags +faststart \
    -c:a aac -b:a 192k -ar 48000 \
    screenshots/store/previews/01_ride.mp4

# Slow a <15 s composite (1.4× → ~15-16 s):
ffmpeg -i short.mov \
    -filter_complex "[0:v]setpts=1.4*PTS,scale=648:1920,pad=1080:1920:216:0:black[v];[0:a]atempo=0.7143[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -b:v 10M -movflags +faststart \
    -c:a aac -b:a 192k -ar 48000 \
    screenshots/store/previews/02_short.mp4
```

After upload, Apple takes 5–15 min to process each video asynchronously. Poll `/v1/appPreviews/<id>` and watch `assetDeliveryState` go through `UPLOAD_COMPLETE → PROCESSING → COMPLETE` (or `FAILED` with error codes).

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
│   ├── FileSyncProtocol.swift       UUIDs (FileCmd / FileData / SensorStream), opcodes, status bytes
│   ├── LiveSample.swift             46-byte SensorStream wire-layout decoder
│   └── BleClient.swift              single-worker CoreBluetooth state machine (FileSync + SensorStream)
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
│   ├── MainNav.swift                TabView scaffold (Live / Sync / Replay), owns FileSyncViewModel
│   ├── LiveScreen.swift             Live tab UI: readout grid + 2 SwiftUI Canvas sparklines
│   ├── FileSyncViewModel.swift      Sync + Live state machine (@Observable, single shared instance)
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

**Sync vs. transfer (SQLite-tracked).** The Sync tab has two distinct operations, mirroring `movement_logger_desktop` (issues #3/#4): per-file **Download** (manual one-off transfer, unchanged) and **Sync now** (pull every session file on the SD card not already mirrored locally, and remember what was pulled). `BLE/SyncDb.swift` is the iOS port of the desktop's `stbox-viz-gui/src/sync_db.rs` — same `synced_files` schema, primary key `(box_id, name, size)` (`size` in the key on purpose: a regrown file with the same name re-pulls). `box_id` = `CBPeripheral.identifier.uuidString`, captured on `.connected`. DB lives at `<Application Support>/sqlite/sync.db` — anchored there, *not* `Documents/` (which is user-deletable via the Files app; the desktop's analogue is "anchored to $HOME, not the download folder"), in its own `sqlite/` subdir per desktop issue #4. Uses the system `SQLite3` module (no external dependency, no Frameworks-build-phase change — autolinked). **Live-mirror model (desktop v0.0.14):** `Documents/<name>` *is* the running mirror — downloads append straight into it (no `.part`/rename). `READ` carries a u32-LE byte offset (`0x02 + name + 0x00 + offset`); `mirrorOffset` decides per file by **local size vs box size** (local<box → fetch only the tail from `offset=local`; local==box → up to date; local>box → rotated, drop & refetch), so a continuously-growing log only pulls its delta and no big file starves GPS/BAT in the serial queue. The SQLite DB is now an **audit log only** (`isSynced` removed), not the fetch decision. **"Keep synced"** toggle: while connected + idle, re-runs a sync pass every 30 s (`syncPollTask`). Flow: `syncNow()`/keep-synced → `startSyncPass` sets a pending flag → fresh LIST → `.listDone` runs the diff *only* when the flag is set (so the auto-LIST never syncs) → `isSensorData` files behind their mirror drain serially through the single-op `download()` path (drained from `.readDone`, which `appendMirror`s the segment at `base` and `markSynced`s for the audit log). **Policy (locked, user decision): sync is purely additive — it never issues DELETE.** Only `Sens*/Gps*/Bat*.csv` + `Mic*.wav` are auto-synced; FW_INFO / CHK / error logs stay manual-only. Android (`ble/SyncDb.kt`, `SQLiteDatabase` direct, `filesDir/sqlite/sync.db`, box_id = BLE MAC) is the exact peer.

**Background BLE.** `UIBackgroundModes = bluetooth-central` (set via `INFOPLIST_KEY_UIBackgroundModes` in the pbxproj) lets CoreBluetooth callbacks continue firing when the app is backgrounded — so a long READ keeps streaming bytes while the user switches to another app. To survive the quiet moments between BLE notifications (post-START_LOG 500 ms wait, LIST inactivity terminator, gaps between READ chunks), `BleClient` also holds a `UIApplication.beginBackgroundTask` assertion across the whole connected session — begins on `.connected`, ends on `disconnectInner` / `close`. Without that assertion, the `Task.sleep` calls inside the worker (watchdog tick, post-START_LOG delay) would freeze when iOS suspends the runloop. With it, ongoing BLE traffic keeps re-extending the assertion and the session stays alive in the background indefinitely. Scanning is intentionally NOT supported in the background — `centralManager.scanForPeripherals(withServices: nil)` requires the foreground, and the user is always tapping Scan in the UI anyway.

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

**Live value labels** in each panel (mirroring the Android Replay screen's "now X.X" / "fused +X.XX m" top-left stack) come from a `LiveValueLayer: CALayer` subclass. Its `@NSManaged var frameIndex: CGFloat` is animated 0 → numFrames−1 across the video duration via a `CAKeyframeAnimation`; CA's render pass calls `display()` once per output frame, which reads `presentation().frameIndex`, indexes into a precomputed per-frame `[Double]` series (one per dynamic label), and rasterises the text into the layer's `contents`. Pre-computation maps each video frame to the nearest data-array index using the same `nearestIndexByTime(gpsAbsTimesMs, target: videoCreation + t*1000)` that drives the cursor sweep — so labels and cursor stay in lock-step. Static labels (`max`, `±X°`, `range`) are baked once into the panel CGImage; only the dynamic lines re-render per frame.

Two gotchas worth remembering — both were the source of multiple bad first attempts:

1. **`videoLayer.frame` MUST equal `parentLayer.frame` MUST equal `videoComp.renderSize`.** When the videoLayer is a smaller sub-region of parent, the CA tool letterboxes the renderSize-sized video composition output to fit inside the videoLayer's bounds, leaving a black gap. To position the video within a larger canvas, set `videoLayer.frame == parentLayer.frame == renderSize` and use the layer instruction's transform to place the source frame in the top region of renderSize. Opaque sibling sublayers (panel `CALayer`s, added AFTER `videoLayer`) cover the empty bottom of the video render.
2. **`UIGraphicsImageRendererFormat.scale` defaults to device scale (3× on iPhone).** For offline export rendering, this allocates `3× × 3×` pixels — a 1080×3200 canvas becomes a 31 MP bitmap. Set `format.scale = 1` for any export-only render to keep it at native pixel dimensions.
3. **Custom CALayer animating non-standard property:** subclass `CALayer`, declare `@NSManaged var prop: CGFloat`, override `needsDisplay(forKey:)` to return `true` for that key, override `display()` to rasterise contents based on `presentation().prop`. Then attach a `CAKeyframeAnimation(keyPath: "prop")`. This is how `LiveValueLayer` re-renders text every frame against the video clock without thousands of pre-baked CGImages.

Progress is polled from `session.progress` on a background `Task` every 100 ms — `AVAssetExportSession` exposes progress as a property rather than a callback.

After export, a **"Play composite video"** button presents `AVPlayerViewController` in a `.fullScreenCover` for the just-written file URL. This deliberately avoids deep-linking into the Photos app — iOS has no public scheme to open a specific `PHAsset` by `localIdentifier` (`photos-redirect://` only opens Photos's main view, and anything that takes an asset ID is private API). In-app playback gives the same UI Photos uses internally (transport controls, AirPlay, PiP) and skips the app switch.

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
