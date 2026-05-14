#!/usr/bin/env python3
"""Poll the new IPHONE_67/01_ermioni preview until assetDeliveryState=COMPLETE
(or FAILED). Re-issues the JWT each iteration since they expire in 20 min."""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import Client, make_jwt  # type: ignore

PID = "07743c78-973d-45a4-bfff-daab144d176b"
INTERVAL = 60  # seconds
TIMEOUT = 30 * 60  # 30 min max


def main() -> None:
    start = time.time()
    while True:
        c = Client(make_jwt())
        data = c.get(f"/appPreviews/{PID}")["data"]
        state = data["attributes"]["assetDeliveryState"]
        s = state.get("state")
        ts = time.strftime("%H:%M:%S")
        print(f"{ts}  state={s}  errors={state.get('errors')}")
        if s == "COMPLETE":
            print("DONE — preview is ready.")
            return
        if s == "FAILED":
            print(f"FAILED: {json.dumps(state)}")
            sys.exit(1)
        if time.time() - start > TIMEOUT:
            print("TIMEOUT after 30 min — bailing out")
            sys.exit(2)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
