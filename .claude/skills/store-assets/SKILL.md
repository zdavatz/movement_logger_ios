---
name: store-assets
description: Prepare App Store Connect assets for MovementLogger (iOS) — resize + upload iPhone/iPad screenshots, transcode 15–30 s app-preview videos, and regenerate the app icon. Use when preparing an App Store submission's screenshots, preview videos, or icon.
---

# MovementLogger — App Store assets

Migrated out of the root `CLAUDE.md` (was always-loaded) so these details load
only when doing store-asset work.

## App Store screenshots

`scripts/resize_screenshots.py` (PIL/LANCZOS) downsizes the four 1320×2868 source screenshots in `screenshots/` to App Store Connect's required sizes: **1290 × 2796** (6.7" iPhone — APP_IPHONE_67, output to `screenshots/store/iphone_67/`) and **1242 × 2688** (6.5" iPhone — APP_IPHONE_65, `screenshots/store/iphone_65/`). The downscale aspect is essentially identical to the source (~0.4%), imperceptible.

**6.5" vs 6.7" gotcha.** The App Store Connect upload UI lists `1284 × 2778` under the 6.5" Display slot — that's a legitimate 6.5"-class size (iPhone 13 Pro Max era). But it is REJECTED by the `APP_IPHONE_67` slot (returns `IMAGE_INCORRECT_DIMENSIONS` and `assetDeliveryState = FAILED`). For 6.7" (modern Pro Max gen 14+) you MUST produce exactly 1290 × 2796. The earlier version of this script targeted 1284 × 2778 for the 6.7" slot and the uploads got stuck in "still uploading" state until re-uploaded at 1290 × 2796.

`scripts/upload_store_screenshots.py` walks the App Store Connect API: App → AppStoreVersion (the one in `PREPARE_FOR_SUBMISSION` etc.) → AppStoreVersionLocalization (prefers English, falls back to whatever is first) → AppScreenshotSet (one per `screenshotDisplayType`, e.g. `APP_IPHONE_67`) → AppScreenshot. JWT signed with the `.p8` API key from `~/.apple/credentials.json`. Idempotent: deletes any screenshots already in each set before re-uploading, so the local PNGs are always the source of truth. Requires the local venv (`python3 -m venv .venv && .venv/bin/pip install Pillow PyJWT cryptography requests`). It also carries an `APP_WATCH_SERIES_4` → `screenshots/store/watch/` target (368×448) — required now that the build embeds the Apple Watch app.

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

**NEVER pad/pillarbox a preview. It WILL be rejected (Guideline 2.3.4).**

App previews must be **full-bleed screen captures of the app's UI**. Anything else
around the app — black bars, a device bezel, a mockup frame — is read by App Review
as "framing around the video screen capture of the app" and rejected.

This is not hypothetical: **v1.0.31 was rejected exactly this way** (Jul 2026). The
previews were the app's own *composite export* scaled into 1080×1920, leaving 216 px
of black each side (`cropdetect` → `crop=640:1920:220:0`). The app's exported
composite is app *output*, not the app — it is not a valid preview source, and no
amount of re-cropping makes it one.

**Pre-flight check — run before every upload.** The detected crop must equal the
full frame; anything smaller means there's a border:

```sh
ffmpeg -hide_banner -i preview.mp4 -vf cropdetect -frames:v 30 -f null - 2>&1 | grep -o "crop=[0-9:]*" | tail -1
```

**How to produce a valid preview: record the app's screen.** The Simulator route is
fully scriptable and needs no phone:

- Use an **iPhone 15 Pro Max** simulator (1290×2796). Its aspect ratio (0.46137)
  matches the **886×1920** preview slot (0.46146) to within 0.02 %, so it scales with
  **no crop and no padding**. (A 6.9"/iPhone 17 sim does NOT match as cleanly.)
- Seed real data into the app container so the screens have content:
  `xcrun simctl get_app_container <sim> ch.pumptsueri.movementlogger data` → drop
  CSVs / videos into `Documents/`.
- Clean status bar: `xcrun simctl status_bar <sim> override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`
- Record: `xcrun simctl io <sim> recordVideo --codec h264 --force out.mov`.
  **Start the recorder FIRST, then re-`activate` the Simulator** — the recorder steals
  focus, and synthetic clicks sent while it isn't frontmost are silently dropped
  (symptom: a recording containing exactly 1 frame).
- Drive the UI with `cliclick` against the Simulator window (there is no `simctl tap`).
  Map device px → screen points; a slow multi-step `dd`/`dm`/`du` drag is required for
  scrolling — a single fast drag does not register as a swipe.
- A **video seeded for the Replay tab must carry an Apple-native creation date**, or
  the app shows "Video has no creation_time — cursor hidden" and the panels can't
  align. `ffmpeg -metadata creation_time=…` is NOT enough (AVFoundation doesn't
  surface the mvhd timestamp as `commonKeyCreationDate`). Re-mux passthrough through
  `AVAssetExportSession` with a `.commonIdentifierCreationDate` metadata item, and set
  the date **inside the GPS coverage window** of the paired `Gps*.csv`.

**A preview MUST carry a stereo audio track — `-an` fails.** A Simulator recording
has no audio, and uploading it silent makes Apple's processing set
`assetDeliveryState=FAILED` with `MOV_RESAVE_STEREO`. Mux in a silent **stereo** AAC
track (48 kHz). Then transcode to the slot size (no `pad`, ever):

```sh
ffmpeg -ss 2 -t 26 -i rec.mov \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 -shortest \
    -vf "scale=886:1920:flags=lanczos,fps=30" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -b:v 10M -movflags +faststart \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    screenshots/store/previews/01_rides_map.mp4
```

**Source-of-truth files live in `screenshots/store/previews/`.** The same MP4 goes to
both iPhone slots (the iPad slot is skipped). Current clips are Simulator screen
recordings: `01_rides_map.mp4` (Rides list → activity-coloured ride map → zoom) and
`02_replay_panels.mp4` (Replay: video playing, four data panels drawing live with the
cursor sweeping).

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
