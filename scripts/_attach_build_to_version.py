#!/usr/bin/env python3
"""Attach the currently-live build to the 1.0.1 AppStoreVersion, so 1.0.1
is treated as a metadata-only update (no new binary)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from upload_store_previews import (  # type: ignore
    Client,
    find_app,
    find_editable_version,
    make_jwt,
)


def list_builds(c: Client, app_id: str) -> list[dict]:
    return c.get(
        f"/builds",
        params={
            "filter[app]": app_id,
            "limit": 20,
            "sort": "-uploadedDate",
            "fields[builds]": "version,uploadedDate,processingState,expired",
        },
    )["data"]


def attach_build(c: Client, version_id: str, build_id: str) -> None:
    r = c.session.patch(
        f"{c.session.headers.get('Authorization') and ''}"  # placeholder, unused
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}/relationships/build",
        json={"data": {"type": "builds", "id": build_id}},
    )
    if r.status_code >= 300:
        raise RuntimeError(f"PATCH relationships/build -> {r.status_code}\n{r.text[:500]}")
    print(f"  PATCH relationships/build -> {r.status_code}")


def main() -> None:
    c = Client(make_jwt())
    app = find_app(c)
    app_id = app["id"]
    print(f"App: {app['attributes']['name']} ({app_id})")

    version = find_editable_version(c, app_id)
    v_id = version["id"]
    v_str = version["attributes"]["versionString"]
    print(f"Editable version: {v_str} ({version['attributes']['appStoreState']}) — {v_id}")

    builds = list_builds(c, app_id)
    if not builds:
        sys.exit("No builds found for this app")
    print("Recent builds:")
    for b in builds:
        a = b["attributes"]
        print(
            f"  id={b['id']}  v={a.get('version')}  "
            f"state={a.get('processingState')}  expired={a.get('expired')}  "
            f"uploaded={a.get('uploadedDate')}"
        )

    # Pick the newest non-expired VALID build (processingState == VALID).
    candidates = [
        b for b in builds
        if b["attributes"].get("processingState") == "VALID"
        and not b["attributes"].get("expired")
    ]
    if not candidates:
        sys.exit("No VALID non-expired build available")
    chosen = candidates[0]
    print(f"Chosen build: id={chosen['id']} v={chosen['attributes']['version']}")

    attach_build(c, v_id, chosen["id"])
    print("done.")


if __name__ == "__main__":
    main()
