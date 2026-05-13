# movement_logger_ios

Movement Logger GUI for iOS — SwiftUI + CoreBluetooth + AVKit. Talks to the PumpTsueri SensorTile.box over BLE to download sensor recordings, then replays them time-synced with a phone-recorded video. Four overlay panels (speed, pitch / Nasenwinkel, height-above-water, GPS track) track the video playhead, and the app can export a V-stack composite MOV (source video on top, panels animated below) directly into your Photos library — the iOS equivalent of the desktop's `combined_*.mov`. Ported from [movement_logger_android](https://github.com/zdavatz/movement_logger_android).

## Features

- **Sync tab** — BLE scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG against the PumpTsueri SensorTile.box. CSVs land in the app's `Documents/`, accessible from the Files app. Long READs continue in the background — switch to another app while a session downloads and the bytes keep flowing (`UIBackgroundModes = bluetooth-central` + per-session `beginBackgroundTask` assertion).
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

`screenshots/store/iphone_67/` (1290 × 2796) and `screenshots/store/iphone_65/` (1242 × 2688) hold the resized screenshots that App Store Connect requires for the 6.7" and 6.5" iPhone display slots. Regenerate from the 1320 × 2868 sources:

```sh
python3 -m venv .venv && .venv/bin/pip install Pillow PyJWT cryptography requests
.venv/bin/python scripts/resize_screenshots.py
```

Push them to the current "Prepare for Submission" App Store version via the App Store Connect API (reads `~/.apple/credentials.json` for the key path + issuer + key ID):

```sh
.venv/bin/python scripts/upload_store_screenshots.py
```

The uploader is idempotent — re-running deletes whatever is in each `AppScreenshotSet` and re-uploads the local PNGs, so iterating on screenshots is just edit-and-rerun.
