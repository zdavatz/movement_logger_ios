#!/usr/bin/env python3
"""Resize the source iPhone 17 Pro Max screenshots (1320×2868) to the two
App Store Connect required pixel sizes:

  - iPhone 6.7" display:  1284 × 2778
  - iPhone 6.5" display:  1242 × 2688

Outputs land under screenshots/store/<class>/.
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
    ("iphone_67", (1284, 2778)),  # 6.7" iPhone (Pro Max class)
    ("iphone_65", (1242, 2688)),  # 6.5" iPhone (Xs Max / 11 Pro Max)
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
