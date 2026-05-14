#!/usr/bin/env python3
"""One-shot: upload 02_img2173.mp4 to both iPhone preview sets without
deleting existing previews. Reuses helpers from upload_store_previews.py."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import (  # type: ignore
    Client,
    SOURCE_DIR,
    find_app,
    find_editable_version,
    find_localization,
    get_or_create_preview_set,
    make_jwt,
    upload_preview,
)

TARGETS = ["IPHONE_67", "IPHONE_65"]
FILE = SOURCE_DIR / "02_img2173.mp4"


def main() -> None:
    if not FILE.exists():
        sys.exit(f"missing {FILE}")
    c = Client(make_jwt())
    app = find_app(c)
    print(f"App: {app['attributes']['name']} ({app['id']})")
    version = find_editable_version(c, app["id"])
    print(
        f"AppStoreVersion: {version['attributes']['versionString']} "
        f"({version['attributes']['appStoreState']})"
    )
    loc = find_localization(c, version["id"])
    print(f"Localization: {loc['attributes']['locale']}")
    for preview_type in TARGETS:
        preview_set = get_or_create_preview_set(c, loc["id"], preview_type)
        print(f"[{preview_type}] adding {FILE.name} to set {preview_set['id']}")
        upload_preview(c, preview_set["id"], FILE)
    print("done.")


if __name__ == "__main__":
    main()
