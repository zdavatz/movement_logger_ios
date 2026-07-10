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
