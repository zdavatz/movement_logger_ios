#!/usr/bin/env python3
"""Delete the stuck IPHONE_67/01_ermioni.mp4 preview and re-upload it."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import (  # type: ignore
    Client,
    SOURCE_DIR,
    make_jwt,
    upload_preview,
)

STUCK_PREVIEW_ID = "5b08c782-0d87-4a33-8eaf-826e44410e22"
IPHONE_67_SET_ID = "f1034657-f9ae-45a2-94c3-275895e3ceb3"
FILE = SOURCE_DIR / "01_ermioni.mp4"


def main() -> None:
    if not FILE.exists():
        sys.exit(f"missing {FILE}")
    c = Client(make_jwt())
    print(f"deleting stuck preview {STUCK_PREVIEW_ID}")
    c.delete(f"/appPreviews/{STUCK_PREVIEW_ID}")
    print(f"uploading {FILE.name} to IPHONE_67 set {IPHONE_67_SET_ID}")
    upload_preview(c, IPHONE_67_SET_ID, FILE)
    print("done.")


if __name__ == "__main__":
    main()
