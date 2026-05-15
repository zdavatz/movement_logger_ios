# movement_logger_ios

Movement Logger GUI for iOS — SwiftUI + CoreBluetooth + AVKit. Talks to the PumpTsueri SensorTile.box over BLE to download sensor recordings, then replays them time-synced with a phone-recorded video. Four overlay panels (speed, pitch / Nasenwinkel, height-above-water, GPS track) track the video playhead, and the app can export a V-stack composite MOV (source video on top, panels animated below) directly into your Photos library — the iOS equivalent of the desktop's `combined_*.mov`. Ported from [movement_logger_android](https://github.com/zdavatz/movement_logger_android).

## Features

- **Sync tab** — BLE scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG against the PumpTsueri SensorTile.box. CSVs land in the app's `Documents/`, accessible from the Files app. Long READs continue in the background — switch to another app while a session downloads and the bytes keep flowing (`UIBackgroundModes = bluetooth-central` + per-session `beginBackgroundTask` assertion).
- **Sync now** — distinct from per-file Download: pulls every session file (`Sens*/Gps*/Bat*.csv` + `Mic*.wav`) on the box not already mirrored locally, tracked in a local SQLite DB (`Application Support/sqlite/sync.db`) keyed per box. Manual downloads register too, so a later Sync skips them. Purely additive — never deletes anything on the box. Port of the desktop's SQLite-tracked sync.
- **Replay tab** — pick a video (Photos or `Documents/`) + a `Sens*.csv` + a `Gps*.csv`. Data is sliced to the ride window (the section of the session overlapping the video clip). Pipeline: Madgwick 6DOF IMU AHRS → drift-corrected nose angle, GPS-anchored TC-compensated baro height, α-β complementary fused height, smoothed GPS-derived speed.
- **Composite export** — single tap produces an H.264 `.mov` with the source video on top and the four panels stacked below. Cursor sweeps, GPS dot, and live "now X.X" / "fused +X.XX m" value labels animate against the video clock. Saves to `Documents/combined_<basename>.mov` and adds to Photos. A "Play composite video" button opens the result full-screen in the native iOS player.

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

Tag-driven CI release. Bump the patch by `+0.0.1`, push the tag, and the workflow at `.github/workflows/release.yml` runs on `macos-15`:

```sh
git tag v0.0.6
git push origin v0.0.6
```

The workflow parses the tag, patches `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the pbxproj at build time, archives Release, exports an App Store IPA, uploads it to App Store Connect via `xcrun altool`, and finally creates a GitHub release with the IPA attached.

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
