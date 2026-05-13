#!/usr/bin/env python3
"""Resize the source iPhone 17 Pro Max screenshots (1320×2868) to the two
App Store Connect required pixel sizes:

  - iPhone 6.7" display (APP_IPHONE_67):  1290 × 2796  (iPhone 14/15/16/17 Pro Max)
  - iPhone 6.5" display (APP_IPHONE_65):  1242 × 2688  (iPhone Xs Max / 11 Pro Max,
                                                        also accepts 1284 × 2778)

Outputs land under screenshots/store/<class>/.

Note on sizes: the App Store Connect upload UI lists 1284 × 2778 under the
6.5" Display slot — that's a legitimate 6.5"-class size — but it is REJECTED
by the APP_IPHONE_67 slot (returns IMAGE_INCORRECT_DIMENSIONS). For 6.7"
you must produce 1290 × 2796 exactly.
"""
import os
from PIL import Image

SOURCE_DIR = "screenshots"
SOURCES = [
    "01_sync_disconnected.png",
    "02_replay_empty.png",
    "03_replay_loaded.png",
    "04_replay_panels.png",
]
TARGETS = [
    ("iphone_67", (1290, 2796)),  # APP_IPHONE_67 — modern Pro Max gen (14+)
    ("iphone_65", (1242, 2688)),  # APP_IPHONE_65 — Xs Max / 11 Pro Max
]

def main() -> None:
    for label, size in TARGETS:
        out_dir = os.path.join(SOURCE_DIR, "store", label)
        os.makedirs(out_dir, exist_ok=True)
        for name in SOURCES:
            src_path = os.path.join(SOURCE_DIR, name)
            im = Image.open(src_path).convert("RGB")
            resized = im.resize(size, Image.LANCZOS)
            out_path = os.path.join(out_dir, name)
            resized.save(out_path, "PNG", optimize=True)
            print(f"{label}: {name} {im.size} -> {size}")

if __name__ == "__main__":
    main()
