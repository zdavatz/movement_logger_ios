# movement_logger_ios

Movement Logger GUI for iOS — SwiftUI + CoreBluetooth + AVKit. Talks to the PumpTsueri SensorTile.box over BLE to download sensor recordings, then replays them time-synced with a phone-recorded video. Four overlay panels (speed, pitch / Nasenwinkel, height-above-water, GPS track) track the video playhead, and the app can export a V-stack composite MOV (source video on top, panels animated below) directly into your Photos library — the iOS equivalent of the desktop's `combined_*.mov`. Ported from [movement_logger_android](https://github.com/zdavatz/movement_logger_android).

## Features

- **Sync tab** — BLE scan / connect / LIST / READ / DELETE / STOP_LOG / START_LOG against the PumpTsueri SensorTile.box. CSVs land in the app's `Documents/`, accessible from the Files app.
- **Replay tab** — pick a video (Photos or `Documents/`) + a `Sens*.csv` + a `Gps*.csv`. Data is sliced to the ride window (the section of the session overlapping the video clip). Pipeline: Madgwick 6DOF IMU AHRS → drift-corrected nose angle, GPS-anchored TC-compensated baro height, α-β complementary fused height, smoothed GPS-derived speed.
- **Composite export** — single tap produces an H.264 `.mov` with the source video on top and the four panels stacked below. Cursor sweeps, GPS dot, and live "now X.X" / "fused +X.XX m" value labels animate against the video clock. Saves to `Documents/combined_<basename>.mov` and adds to Photos.

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
