# movement_logger_ios

Movement Logger GUI for iOS — SwiftUI + CoreBluetooth + AVKit. Talks to the PumpTsueri SensorTile.box over BLE to download sensor recordings, then replays them time-synced with a phone-recorded video (speed, pitch / Nasenwinkel, height-above-water, GPS track panels overlaid against the video playhead). Ported from [movement_logger_android](https://github.com/zdavatz/movement_logger_android).

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

See `CLAUDE.md` for architecture details and protocol gotchas.
