#!/usr/bin/env python3
"""List every AppPreview on the editable version and its assetDeliveryState."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import (  # type: ignore
    Client,
    find_app,
    find_editable_version,
    find_localization,
    make_jwt,
)


def main() -> None:
    c = Client(make_jwt())
    app = find_app(c)
    version = find_editable_version(c, app["id"])
    print(
        f"AppStoreVersion {version['attributes']['versionString']} "
        f"({version['attributes']['appStoreState']}) — {version['id']}"
    )
    loc = find_localization(c, version["id"])
    sets = c.get(f"/appStoreVersionLocalizations/{loc['id']}/appPreviewSets")["data"]
    if not sets:
        print("no preview sets")
        return
    for s in sets:
        ptype = s["attributes"]["previewType"]
        sid = s["id"]
        print(f"\n[{ptype}] set {sid}")
        previews = c.get(f"/appPreviewSets/{sid}/appPreviews")["data"]
        for p in previews:
            a = p["attributes"]
            print(f"  id={p['id']}")
            print(f"    fileName           : {a.get('fileName')}")
            print(f"    uploaded           : {a.get('uploaded')}")
            print(f"    assetDeliveryState : {json.dumps(a.get('assetDeliveryState'))}")
            print(f"    previewFrameTimeCode: {a.get('previewFrameTimeCode')}")


if __name__ == "__main__":
    main()
