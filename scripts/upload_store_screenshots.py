#!/usr/bin/env python3
"""Upload screenshots to App Store Connect via the public REST API.

Reads the App Store Connect API key from ~/.apple/credentials.json (the
team_id / api_key_id / api_key_path / api_issuer_id block), then walks the
App → AppStoreVersion → AppStoreVersionLocalization → AppScreenshotSet →
AppScreenshot chain to attach the local screenshots to the "Prepare for
Submission" version of the app.

For each target display type the script:
  - finds (or creates) the AppScreenshotSet
  - deletes any screenshots already in that set, so re-runs are idempotent
  - reserves an upload via POST /appScreenshots
  - PUTs each upload operation chunk
  - PATCHes the screenshot with uploaded=true and the md5 checksum

Usage:
  ./scripts/upload_store_screenshots.py
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from pathlib import Path

import jwt          # PyJWT
import requests

ROOT = Path(__file__).resolve().parents[1]
CREDENTIALS = Path.home() / ".apple" / "credentials.json"
BUNDLE_ID = "ch.pumptsueri.movementlogger"
API_BASE = "https://api.appstoreconnect.apple.com/v1"

# (display_type, source_dir) — order in source_dir == order on the store page
TARGETS = [
    ("APP_IPHONE_67",        ROOT / "screenshots" / "store" / "iphone_67"),
    ("APP_IPHONE_65",        ROOT / "screenshots" / "store" / "iphone_65"),
    ("APP_IPAD_PRO_3GEN_129", ROOT / "screenshots" / "store" / "ipad_13"),
]


def make_jwt() -> str:
    creds = json.loads(CREDENTIALS.read_text())["apple"]
    key_path = Path(os.path.expanduser(creds["api_key_path"]))
    key = key_path.read_text()
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": creds["api_issuer_id"],
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1",
        },
        key,
        algorithm="ES256",
        headers={"kid": creds["api_key_id"], "typ": "JWT"},
    )
    return token if isinstance(token, str) else token.decode()


class Client:
    def __init__(self, token: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"
        self.session.headers["Accept"] = "application/json"

    def get(self, path: str, **kw):
        r = self.session.get(f"{API_BASE}{path}", **kw)
        self._raise(r)
        return r.json()

    def post(self, path: str, body: dict):
        r = self.session.post(f"{API_BASE}{path}", json=body)
        self._raise(r)
        return r.json()

    def patch(self, path: str, body: dict):
        r = self.session.patch(f"{API_BASE}{path}", json=body)
        self._raise(r)
        return r.json() if r.text else {}

    def delete(self, path: str):
        r = self.session.delete(f"{API_BASE}{path}")
        self._raise(r)

    def put_upload(self, url: str, headers: dict, data: bytes):
        r = requests.put(url, headers={h["name"]: h["value"] for h in headers}, data=data)
        if r.status_code >= 300:
            raise RuntimeError(f"upload PUT failed {r.status_code}: {r.text[:400]}")

    @staticmethod
    def _raise(r):
        if r.status_code >= 300:
            raise RuntimeError(f"{r.request.method} {r.url} -> {r.status_code}\n{r.text[:1000]}")


def find_app(c: Client) -> dict:
    apps = c.get("/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        raise SystemExit(f"No app with bundleId {BUNDLE_ID} found")
    return apps[0]


def find_editable_version(c: Client, app_id: str) -> dict:
    versions = c.get(f"/apps/{app_id}/appStoreVersions", params={"limit": 20})["data"]
    editable_states = {
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY",
    }
    for v in versions:
        state = v["attributes"]["appStoreState"]
        if state in editable_states:
            return v
    raise SystemExit(
        "No editable App Store Version found. States seen: "
        + ", ".join(v["attributes"]["appStoreState"] for v in versions)
    )


def find_localization(c: Client, version_id: str) -> dict:
    locs = c.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    if not locs:
        raise SystemExit("No localization found for the version")
    # Prefer English locales, fall back to whatever the first localization is.
    for l in locs:
        if l["attributes"]["locale"].startswith("en"):
            return l
    return locs[0]


def get_or_create_screenshot_set(c: Client, loc_id: str, display_type: str) -> dict:
    sets = c.get(f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s
    return c.post(
        "/appScreenshotSets",
        {
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": loc_id}
                    }
                },
            }
        },
    )["data"]


def delete_existing_screenshots(c: Client, set_id: str) -> None:
    shots = c.get(f"/appScreenshotSets/{set_id}/appScreenshots")["data"]
    for s in shots:
        print(f"  deleting existing screenshot {s['id']}")
        c.delete(f"/appScreenshots/{s['id']}")


def upload_screenshot(c: Client, set_id: str, file_path: Path) -> None:
    data = file_path.read_bytes()
    size = len(data)
    print(f"  uploading {file_path.name} ({size:,} bytes)")
    create = c.post(
        "/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {
                    "fileName": file_path.name,
                    "fileSize": size,
                },
                "relationships": {
                    "appScreenshotSet": {
                        "data": {"type": "appScreenshotSets", "id": set_id}
                    }
                },
            }
        },
    )["data"]
    shot_id = create["id"]
    ops = create["attributes"]["uploadOperations"]
    for op in ops:
        offset = op["offset"]
        length = op["length"]
        c.put_upload(op["url"], op["requestHeaders"], data[offset : offset + length])
    md5 = hashlib.md5(data).hexdigest()
    c.patch(
        f"/appScreenshots/{shot_id}",
        {
            "data": {
                "type": "appScreenshots",
                "id": shot_id,
                "attributes": {"uploaded": True, "sourceFileChecksum": md5},
            }
        },
    )
    print(f"    committed (id={shot_id}, md5={md5})")


def main() -> None:
    if not CREDENTIALS.exists():
        sys.exit(f"missing {CREDENTIALS}")
    c = Client(make_jwt())

    app = find_app(c)
    app_id = app["id"]
    print(f"App: {app['attributes']['name']} ({app_id}) — bundleId {BUNDLE_ID}")

    version = find_editable_version(c, app_id)
    version_id = version["id"]
    print(
        f"AppStoreVersion: {version['attributes']['versionString']} "
        f"({version['attributes']['appStoreState']}) — {version_id}"
    )

    loc = find_localization(c, version_id)
    loc_id = loc["id"]
    locale = loc["attributes"]["locale"]
    print(f"Localization: {locale} — {loc_id}")

    for display_type, src_dir in TARGETS:
        files = sorted(src_dir.glob("*.png"))
        if not files:
            print(f"[{display_type}] no files in {src_dir}, skipping")
            continue
        print(f"[{display_type}] {len(files)} screenshot(s) from {src_dir}")
        screenshot_set = get_or_create_screenshot_set(c, loc_id, display_type)
        set_id = screenshot_set["id"]
        delete_existing_screenshots(c, set_id)
        for f in files:
            upload_screenshot(c, set_id, f)

    print("done.")


if __name__ == "__main__":
    main()
