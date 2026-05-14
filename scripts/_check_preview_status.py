#!/usr/bin/env python3
"""Print assetDeliveryState for the two uploaded previews."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import Client, make_jwt  # type: ignore

IDS = [
    "b51a2d93-3e94-4a75-81a2-ac34e31a20f0",  # IPHONE_67
    "7b9d2a6c-5630-4517-a5b8-fd74bf07d262",  # IPHONE_65
]


def main() -> None:
    c = Client(make_jwt())
    for pid in IDS:
        data = c.get(f"/appPreviews/{pid}")["data"]
        attrs = data["attributes"]
        print(f"{pid}")
        print(f"  fileName            : {attrs.get('fileName')}")
        print(f"  assetDeliveryState  : {json.dumps(attrs.get('assetDeliveryState'))}")
        print(f"  previewFrameTimeCode: {attrs.get('previewFrameTimeCode')}")


if __name__ == "__main__":
    main()
