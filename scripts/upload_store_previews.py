#!/usr/bin/env python3
"""Upload App Previews (videos) to App Store Connect.

Mirrors upload_store_screenshots.py one-for-one, but walks the
AppPreviewSet → AppPreview chain instead of AppScreenshotSet →
AppScreenshot. Same JWT auth, same reserve-upload / PUT-chunks /
PATCH-with-checksum flow.

Source files live under screenshots/store/previews/ and are uploaded to
BOTH the IPHONE_67 and IPHONE_65 preview sets — Apple accepts 1080x1920
for both. The iPad preview slot (IPAD_PRO_3GEN_129) is skipped because
it wants 1200x1600 (different aspect entirely from the composite layout).

Apple's strict spec for App Previews:
  - Duration 15-30 s
  - 1080x1920 or 886x1920 portrait (or landscape variants) for iPhone
  - H.264 video + AAC audio (or no audio)
  - 24 / 25 / 30 fps (not 60)

If a video fails these, this script gets `assetDeliveryState=FAILED`
back on the AppPreview record after Apple's async processing — same
failure mode as wrong-dimension screenshots.
"""
from __future__ import annotations

import hashlib
import json
import mimetypes
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

SOURCE_DIR = ROOT / "screenshots" / "store" / "previews"
# (preview_type, source_dir) — same files go to both iPhone sets.
TARGETS = [
    ("IPHONE_67", SOURCE_DIR),
    ("IPHONE_65", SOURCE_DIR),
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

    def put_upload(self, url: str, headers: list, data: bytes):
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
    for l in locs:
        if l["attributes"]["locale"].startswith("en"):
            return l
    return locs[0]


def get_or_create_preview_set(c: Client, loc_id: str, preview_type: str) -> dict:
    sets = c.get(f"/appStoreVersionLocalizations/{loc_id}/appPreviewSets")["data"]
    for s in sets:
        if s["attributes"]["previewType"] == preview_type:
            return s
    return c.post(
        "/appPreviewSets",
        {
            "data": {
                "type": "appPreviewSets",
                "attributes": {"previewType": preview_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": loc_id}
                    }
                },
            }
        },
    )["data"]


def delete_existing_previews(c: Client, set_id: str) -> None:
    items = c.get(f"/appPreviewSets/{set_id}/appPreviews")["data"]
    for it in items:
        print(f"  deleting existing preview {it['id']}")
        c.delete(f"/appPreviews/{it['id']}")


def upload_preview(c: Client, set_id: str, file_path: Path) -> None:
    data = file_path.read_bytes()
    size = len(data)
    mime, _ = mimetypes.guess_type(file_path.name)
    mime = mime or "video/mp4"
    print(f"  uploading {file_path.name} ({size:,} bytes, {mime})")
    create = c.post(
        "/appPreviews",
        {
            "data": {
                "type": "appPreviews",
                "attributes": {
                    "fileName": file_path.name,
                    "fileSize": size,
                    "mimeType": mime,
                },
                "relationships": {
                    "appPreviewSet": {
                        "data": {"type": "appPreviewSets", "id": set_id}
                    }
                },
            }
        },
    )["data"]
    pid = create["id"]
    ops = create["attributes"]["uploadOperations"]
    for op in ops:
        offset = op["offset"]
        length = op["length"]
        c.put_upload(op["url"], op["requestHeaders"], data[offset : offset + length])
    md5 = hashlib.md5(data).hexdigest()
    c.patch(
        f"/appPreviews/{pid}",
        {
            "data": {
                "type": "appPreviews",
                "id": pid,
                "attributes": {"uploaded": True, "sourceFileChecksum": md5},
            }
        },
    )
    print(f"    committed (id={pid}, md5={md5})")


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

    for preview_type, src_dir in TARGETS:
        files = sorted(src_dir.glob("*.mp4")) + sorted(src_dir.glob("*.mov"))
        if not files:
            print(f"[{preview_type}] no files in {src_dir}, skipping")
            continue
        print(f"[{preview_type}] {len(files)} preview(s) from {src_dir}")
        preview_set = get_or_create_preview_set(c, loc_id, preview_type)
        set_id = preview_set["id"]
        delete_existing_previews(c, set_id)
        for f in files:
            upload_preview(c, set_id, f)

    print("done. Apple now needs ~5-15 min to process each video; check")
    print("`appPreviews/<id>` for `assetDeliveryState=COMPLETE` afterwards.")


if __name__ == "__main__":
    main()
