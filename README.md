# movement_logger_ios

Movement Logger GUI for iOS — SwiftUI + CoreBluetooth + AVKit. Talks to the PumpTsueri SensorTile.box over BLE to download sensor recordings, then replays them time-synced with a phone-recorded video. Four overlay panels (speed, pitch / Nasenwinkel, height-above-water, GPS track) track the video playhead, and the app can export a V-stack composite MOV (source video on top, panels animated below) directly into your Photos library — the iOS equivalent of the desktop's `combined_*.mov`. Ported from [movement_logger_android](https://github.com/zdavatz/movement_logger_android).

## Features

- **Live tab** — when connected to a PumpLogger-firmware box, shows the 0.5 Hz sensor snapshot (accel / gyro / mag / baro / GPS + two sparklines) topped by a **Board angles** card that reads the box attitude in degrees — **Pitch** (nose up/down, uphill vs downhill), **Roll** (lean onto the left/right side), **Yaw** (heading) — computed from the drift-free gyro+accel orientation filter about the board's physical axes (the box nose is the Y axis). A **Zero here** button tares all three to the current pose so the calibrated readout shows deviation from a mounted reference; the zero persists across reconnect and app restart **and — with box firmware ≥ v0.0.37 — is stored on the box itself** (`CAL.CFG` on the SD), so a calibration set on the iPhone is visible to the Desktop / Android on their next connect without a re-tap.
- **Sync tab** — BLE scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG against the PumpTsueri SensorTile.box. CSVs land in the app's `Documents/`, accessible from the Files app. Long READs continue in the background — switch to another app while a session downloads and the bytes keep flowing (`UIBackgroundModes = bluetooth-central` + a renewed per-session `beginBackgroundTask` assertion), and the screen can lock without dropping the link. A mid-transfer link drop auto-reconnects and resumes from the local mirror offset rather than freezing the queue. **For stable large-file sync the box should run firmware ≥ v0.0.17** — older firmware lacks the connection-stability fixes (45 s stall tolerance, no aggressive 4 s supervision timeout) and a working `GET_MODE`, so big files drop after a few minutes; flash the latest firmware over BLE from the desktop app if needed. A **GPS On/Off** control (next to the box log-mode selector) turns the box's u-blox receiver off to save battery when GPS is faulty or unused — logging (IMU + baro) keeps running and Replay still time-aligns via the phone-clock sync anchor, you just lose the speed + GPS-track panels while keeping pitch / roll / height. **Needs box firmware ≥ v0.0.35**; on older firmware the toggle stays "unknown".
- **Sync now** — distinct from per-file Download: pulls every session file (`Sens*/Gps*/Bat*.csv` + `Mic*.wav`) on the box not already mirrored locally, tracked in a local SQLite DB (`Application Support/sqlite/sync.db`) keyed per box. Manual downloads register too, so a later Sync skips them. Purely additive — never deletes anything on the box. Port of the desktop's SQLite-tracked sync. While a pass runs the Sync tab shows a cumulative byte-progress card (overall `X MB / Y MB`, %, files N/M + per-file bar) so you can tell it's actually pulling data even though the file list is intentionally cleared during the diff. The PumpTsueri BLE link delivers ~2 KB/s (single-op protocol — parallel transfers aren't possible), so the *first* sync of an old session can take minutes per MB; subsequent syncs only fetch the new tail.
- **Background sync agent** — once "Keep synced" is on with the box in AUTO mode, mirroring continues even when the app is closed (port of Android `sync/` + desktop `--agent`). Two layered iOS mechanisms:
    - **CoreBluetooth State Restoration** wakes the app when the known box comes into range, even after a phone reboot.
    - **`BGAppRefreshTask`** lets iOS opportunistically fire short sync slots — cadence is iOS's call (no Android-style 15-min guarantee).
    Gating mirrors Android/desktop exactly (`keepSynced && boxId != nil && logModeManual != true`). GUI wins: if the foreground app is using BLE, the background task yields.
- **Replay tab** — pick a video (Photos or `Documents/`) + a `Sens*.csv` + a `Gps*.csv`. Data is sliced to the ride window (the section of the session overlapping the video clip). Pipeline: Madgwick 6DOF IMU AHRS → drift-corrected nose angle, GPS-anchored TC-compensated baro height, α-β complementary fused height, smoothed GPS-derived speed. File list is sorted newest-first by mod date (each row shows `HH.mm.ss-dd.MM.yyyy`), and a Refresh button re-lists after a Sync without re-launching. An at-a-glance **LoadedStatusBar** under the picker shows green ticks for Sensor / GPS / Video so you can tell at a glance whether a Load tap actually wired data through. Picking a video **auto-loads matching CSVs** — filename token overlap (e.g. video `Ayano_Pump_25.4.2026_Ermioni.MOV` ↔ `Sens_ayano_25.4.2026.csv` share `ayano`, `25`, `4`, `2026`), falling back to mod-date proximity within ±7 days. Renders with **partial data**: sensor-only (pitch + height from IMU + session-max-pressure baro fallback) or GPS-only (speed + track) both produce useful panels. The red cursor sweeps even when the video's wall-clock doesn't overlap the sensor session — sensor abs-times get linearly stretched across the video duration so the needle still tracks 0 → 100 % of the panel as the video plays. Parser accepts both the pre-22.4.2026 column names (`Time [10ms]`, `AccX [mg]`, …) AND the post-22.4.2026 compact names (`ms`, `ax_mg`, `p_hPa`, `utc`, `fix_q`, …), with the `ms` column converted from 1ms → 10ms ticks at parse time. Corrupted rows (empty fields, jammed values like `-30-123` from interrupted SD writes) are silently skipped instead of bailing on the whole file.
- **Composite export** — single tap produces an H.264 `.mov` with the source video on top and the active panels stacked below. Panel count is dynamic: sensor-only sessions get a 2-panel composite (Pitch + Height), GPS-only sessions get a 2-panel composite (Speed + GPS track), full sessions get all 4. Cursor sweeps, GPS dot, and live "now X.X" / "fused +X.XX m" value labels animate against the video clock. Saves to `Documents/combined_<basename>.mov` and adds to Photos. A "Play composite video" button opens the result full-screen in the native iOS player.
- **GPS tab** — built-in iPhone GNSS via `CoreLocation` writes a `Sens`/`Gps`-schema CSV directly into `Documents/` so Replay can pick it up. **Share** + **Copy** buttons on the log card let you push the CSV out via the system share sheet or paste its content into another app.
- **Rides tab** — the Apple-Watch ride list. Each row is one watch session's 1 Hz GPS track (synced from the watch app over WatchConnectivity). Tap a ride to **plot it on a map**: an interactive Apple Maps view of the recorded track, plus a one-tap **shareable PNG** — real map tiles under a speed-coloured track (blue slow → red fast), green start / red end markers, and a footer with the app logo, ride stats (top speed · distance · duration), and the GitHub source link. The raw CSV is still shareable straight from the row. (A standalone `scripts/ride_map_png.swift` renders the same PNG on macOS from any GPS CSV.)
- **GPS Debug tab** — live u-blox UBX diagnostics tunnelled over the box's BLE link (no cable), for antenna selection + mounting. Connect the box on the Sync tab, then Start: the app bridges the receiver over BLE (firmware opcodes `0x0D`/`0x0E`), polls it once a second (NAV-PVT / NAV-DOP / NAV-SAT / NAV-SIG / MON-RF) and writes two CSVs into `Documents/` — `<label>_gnss_epoch.csv` (fix quality: fixType, numSV, hAcc, DOP) and `<label>_gnss_signals.csv` (per-signal C/N0, elevation, azimuth, prRes) — same schema as the desktop `gps-debug` tool, plus antenna/RF health (antStatus, AGC, jamming). Polling is non-destructive; the receiver is never persistently reconfigured. **Needs box firmware ≥ v0.0.18** (the GPS-bridge opcode + the MAX-M10S UBX-output fix); on older firmware it just shows "no NAV-PVT reply". Each CSV output file has **View** + **Share** buttons — View opens the same inline previewer the Sync tab's sensor files use, Share sends it out via the system share sheet (both work mid-survey against the partial file).
- **Firmware update (OTA over BLE)** — the Sync tab checks the box's firmware against the latest [`movement_logger_firmware`](https://github.com/zdavatz/movement_logger_firmware) release on connect and shows a "🔄 New box firmware available" banner when the box is behind. One tap **downloads the `.bin` and installs it over Bluetooth** (staged into the box's spare flash bank, then a bank-swap reboot) — no cable, no manual file handling. A live progress bar tracks the transfer; keep the box close and powered until it reboots. (There's also a manual "Upload firmware (.bin)" picker for a local `.bin`.) The transfer is resend-tuned to recover dropped BLE ACKs quickly (~3–4 min for a ~106 KB image).

## Build & run

Open `MovementLogger.xcodeproj` in Xcode 15+ and run on a physical iOS 17+ device (BLE doesn't work in the Simulator). Signing is preconfigured for ywesee GmbH (team `4B37356EGR`); change `DEVELOPMENT_TEAM` in the target's build settings if you're using a different Apple Developer account.

CLI install + launch on a connected, **unlocked** iPhone:

```sh
xcodebuild -scheme MovementLogger -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates build
xcrun devicectl list devices                                 # grab the device UUID
xcrun devicectl device install app --device <UUID> \
    ~/Library/Developer/Xcode/DerivedData/MovementLogger-*/Build/Products/Debug-iphoneos/MovementLogger.app
xcrun devicectl device process launch --device <UUID> ch.pumptsueri.movementlogger
```

Push sample data straight into the app's sandbox (skips Photos sync and the Sync tab — useful for testing Replay with desktop-side CSVs):

```sh
xcrun devicectl device copy to --device <UUID> --source ./local-files \
    --destination Documents --domain-type appDataContainer \
    --domain-identifier ch.pumptsueri.movementlogger
```

Screenshots in `screenshots/`. See `CLAUDE.md` for architecture details, AVFoundation gotchas, and protocol notes.

## Release

Tag-driven CI. Two separate version trains (see `CLAUDE.md`):

- **`0.0.x` = binary / TestFlight builds** — bumped per dev iteration, installed over USB (`devicectl`) and/or uploaded for TestFlight. **Never** auto-submitted to the public App Store.
- **`1.x.x` = public App Store releases** — the only tags that auto-submit for review. The current store version is **1.0.23** (Rides-tab watch-GPS map + shareable PNG).

```sh
git tag v1.0.17          # store release (1.x = auto-submit)
git push origin v1.0.17
# …or a binary-only build:
git tag v0.0.32           # 0.0.x = build + upload, no store submit
git push origin v0.0.32
```

The workflow at `.github/workflows/release.yml` (runs on `macos-26`) parses the tag, patches `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the pbxproj at build time, archives Release, exports an App Store IPA, uploads it to App Store Connect via `xcrun altool`, and creates a GitHub release with the IPA attached. For `1.x.x` tags it then runs `scripts/submit_for_review.py`, which attaches the processed build, sets "What's New" from the tag message, and submits for review with `releaseType=AFTER_APPROVAL` (auto-publish once Apple approves — the iOS analogue of the Android `--track production --release-status completed` flow). Export compliance is answered by `ITSAppUsesNonExemptEncryption=false` in `Info.plist`. The submit step is gated on the tag's major version (`steps.ver.outputs.store`), so a `0.0.x` tag stops after the upload.

Required GitHub Actions secrets (set once at `Settings → Secrets and variables → Actions`):

- `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` — App Store Connect API key identifiers
- `APPLE_API_KEY_P8_BASE64` — base64 of `~/.apple/AuthKey_<id>.p8`
- `APPLE_CERT_P12_BASE64` — base64 of a slim single-identity `.p12` containing just `Apple Distribution: ywesee GmbH (4B37356EGR)` (a full keychain export is too large for a GitHub secret)
- `APPLE_CERT_PASSWORD` — `.p12` password
- `APPLE_KEYCHAIN_PASSWORD` — throwaway password for the runner's temp keychain

A canonical backup of the slim Apple Distribution `.p12` and its password live in `~/Library/Mobile Documents/com~apple~CloudDocs/ywesee/p12/` (see the README in that folder).

## App Store screenshots

`screenshots/store/iphone_67/` (1290 × 2796), `screenshots/store/iphone_65/` (1242 × 2688), and `screenshots/store/ipad_13/` (2064 × 2752 — native iPad Pro 13" M4) hold the screenshots App Store Connect requires for the 6.7" iPhone, 6.5" iPhone, and 13" iPad display slots respectively. The two iPhone sets come from `scripts/resize_screenshots.py` (PIL/LANCZOS over the 1320 × 2868 sources). The iPad set was captured live on the iPad Pro 13-inch (M4) simulator and is committed as-is (no resize step).

```sh
python3 -m venv .venv && .venv/bin/pip install Pillow PyJWT cryptography requests
.venv/bin/python scripts/resize_screenshots.py
```

Push them to the current "Prepare for Submission" App Store version via the App Store Connect API (reads `~/.apple/credentials.json` for the key path + issuer + key ID):

```sh
.venv/bin/python scripts/upload_store_screenshots.py
```

The uploader is idempotent — re-running deletes whatever is in each `AppScreenshotSet` and re-uploads the local PNGs, so iterating on screenshots is just edit-and-rerun.

To capture more iPad screenshots, launch the app on the iPad simulator with `SIMCTL_CHILD_INITIAL_TAB=replay` to land directly on the Replay tab (otherwise SwiftUI's iPadOS 18 segmented TabView is hard to drive from the command line):

```sh
xcrun simctl boot "iPad Pro 13-inch (M4)"
xcrun simctl install <udid> ~/Library/Developer/Xcode/DerivedData/MovementLogger-*/Build/Products/Debug-iphonesimulator/MovementLogger.app
SIMCTL_CHILD_INITIAL_TAB=replay xcrun simctl launch <udid> ch.pumptsueri.movementlogger
xcrun simctl io <udid> screenshot screenshots/store/ipad_13/03_xyz.png
```

## App Previews (videos)

`screenshots/store/previews/*.mp4` hold the 15–30 s clips that play on the App Store listing. Both iPhone slots (`IPHONE_67`, `IPHONE_65`) accept the same `1080 × 1920` portrait at 30 fps, so one set of files covers both. Push them to App Store Connect via:

```sh
.venv/bin/python scripts/upload_store_previews.py
```

The source clips are composite-MOV exports straight out of the app's own Replay tab (`Documents/combined_<basename>.mov`), but the app emits `1080 × 3200` (source video on top + 4 panels below) which Apple rejects. The committed files were transcoded with `ffmpeg`:

```sh
# Trim to ≤30 s and pillarbox to 1080×1920 (preserves all 4 panels):
ffmpeg -ss 0 -t 30 -i combined.mov \
    -vf "scale=648:1920,pad=1080:1920:216:0:black" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -b:v 10M -movflags +faststart \
    -c:a aac -b:a 192k -ar 48000 \
    screenshots/store/previews/01_ride.mp4

# For clips <15 s, slow them with setpts/atempo:
ffmpeg -i short.mov \
    -filter_complex "[0:v]setpts=1.4*PTS,scale=648:1920,pad=1080:1920:216:0:black[v];[0:a]atempo=0.7143[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -r 30 -b:v 10M -movflags +faststart \
    -c:a aac -b:a 192k -ar 48000 \
    screenshots/store/previews/02_short.mp4
```
