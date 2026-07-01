#!/usr/bin/env python3
"""Attach the freshly-uploaded build to an App Store version and submit it
for App Store review — the automation of the three manual clicks in App
Store Connect (attach build → write "What's New" → Submit for Review).

Runs after the IPA is uploaded (`altool --upload-app`). The flow:

  1. find the app by bundleId
  2. poll /builds until the build matching (versionString, build-number)
     finishes Apple's server-side processing (PROCESSING → VALID)
  3. find-or-create the editable AppStoreVersion for `--version`, and set
     its release type (default AFTER_APPROVAL = auto-publish once approved)
  4. set "What's New" on the English (or first) localization — skipped for
     a brand-new app's very first version, where Apple forbids whatsNew
  5. attach the build to the version
  6. create + submit a reviewSubmission (the modern unified-submission API;
     `appStoreVersionSubmissions` is deprecated)

Apple ALWAYS routes this through human review (~1 day). "Auto-release"
here means auto-submit + auto-publish on approval — there is no API to
skip review. Use `--no-submit` to prepare everything (build attached,
notes set, release type set) but stop short of flipping the submission to
`submitted=true`, so a human can do the final click.

Credentials: env first (APPLE_API_KEY_ID / APPLE_API_ISSUER_ID +
APPLE_API_PRIVATE_KEY_PATH or APPLE_API_KEY_P8), falling back to
~/.apple/credentials.json for local runs (same block the screenshot
uploader reads).

Usage:
  ./scripts/submit_for_review.py --version 0.0.27 --build 27 \
      --notes-file notes.txt
  ./scripts/submit_for_review.py --version 0.0.27 --build 27 \
      --notes "Bug fixes." --no-submit
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import jwt          # PyJWT
import requests

CREDENTIALS = Path.home() / ".apple" / "credentials.json"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "ch.pumptsueri.movementlogger")
API_BASE = "https://api.appstoreconnect.apple.com/v1"
PLATFORM = "IOS"

# AppStoreVersion states we can still edit + (re)submit into.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
    "METADATA_REJECTED", "INVALID_BINARY",
}
# A live/queued version we must NOT touch — surfaces a clear error instead.
LOCKED_STATES = {
    "READY_FOR_SALE", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
    "PROCESSING_FOR_APP_STORE", "IN_REVIEW", "WAITING_FOR_REVIEW",
    "REPLACED_WITH_NEW_VERSION",
}


# ---------------------------------------------------------------- auth

def _creds_from_env() -> dict | None:
    kid = os.environ.get("APPLE_API_KEY_ID")
    iss = os.environ.get("APPLE_API_ISSUER_ID")
    if not (kid and iss):
        return None
    key = os.environ.get("APPLE_API_KEY_P8")
    if not key:
        # Either an explicit path, or the CI staging dir used by release.yml.
        path = os.environ.get("APPLE_API_PRIVATE_KEY_PATH")
        if not path:
            staged = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{kid}.p8"
            if staged.exists():
                path = str(staged)
        if not path:
            sys.exit("APPLE_API_KEY_ID/ISSUER set but no key (APPLE_API_KEY_P8 "
                     "or APPLE_API_PRIVATE_KEY_PATH or staged AuthKey file)")
        key = Path(os.path.expanduser(path)).read_text()
    return {"api_key_id": kid, "api_issuer_id": iss, "key": key}


def make_jwt() -> str:
    creds = _creds_from_env()
    if creds is None:
        if not CREDENTIALS.exists():
            sys.exit(f"no API creds in env and missing {CREDENTIALS}")
        c = json.loads(CREDENTIALS.read_text())["apple"]
        creds = {
            "api_key_id": c["api_key_id"],
            "api_issuer_id": c["api_issuer_id"],
            "key": Path(os.path.expanduser(c["api_key_path"])).read_text(),
        }
    now = int(time.time())
    token = jwt.encode(
        {"iss": creds["api_issuer_id"], "iat": now, "exp": now + 20 * 60,
         "aud": "appstoreconnect-v1"},
        creds["key"], algorithm="ES256",
        headers={"kid": creds["api_key_id"], "typ": "JWT"},
    )
    return token if isinstance(token, str) else token.decode()


class Client:
    def __init__(self, token: str):
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token}"
        self.s.headers["Accept"] = "application/json"

    def get(self, path, **kw):
        r = self.s.get(f"{API_BASE}{path}", **kw); self._raise(r); return r.json()

    def post(self, path, body):
        r = self.s.post(f"{API_BASE}{path}", json=body); self._raise(r)
        return r.json() if r.text else {}

    def patch(self, path, body):
        r = self.s.patch(f"{API_BASE}{path}", json=body); self._raise(r)
        return r.json() if r.text else {}

    @staticmethod
    def _raise(r):
        if r.status_code >= 300:
            raise RuntimeError(f"{r.request.method} {r.url} -> {r.status_code}\n{r.text[:1200]}")


# ------------------------------------------------------------- helpers

def find_app(c: Client) -> dict:
    apps = c.get("/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"No app with bundleId {BUNDLE_ID}")
    return apps[0]


def wait_for_build(c: Client, app_id: str, version: str, build: str,
                   timeout_s: int, poll_s: int) -> dict:
    """Poll until the build for (version, build) reports VALID, or time out."""
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        builds = c.get("/builds", params={
            "filter[app]": app_id,
            "filter[version]": build,            # CFBundleVersion (build number)
            "filter[preReleaseVersion.version]": version,  # CFBundleShortVersionString
            "include": "preReleaseVersion",
            "limit": 10,
        })["data"]
        if builds:
            b = builds[0]
            state = b["attributes"]["processingState"]
            if state != last:
                print(f"  build {version} ({build}): processingState={state}")
                last = state
            if state == "VALID":
                return b
            if state in ("FAILED", "INVALID"):
                sys.exit(f"build processing ended in {state}")
        else:
            if last != "PENDING":
                print(f"  build {version} ({build}) not visible yet — waiting…")
                last = "PENDING"
        time.sleep(poll_s)
    sys.exit(f"timed out after {timeout_s}s waiting for build {version} ({build}) to process")


def find_or_create_version(c: Client, app_id: str, version: str,
                           release_type: str) -> dict:
    existing = c.get(f"/apps/{app_id}/appStoreVersions", params={
        "filter[versionString]": version, "limit": 5,
    })["data"]
    for v in existing:
        state = v["attributes"]["appStoreState"]
        if state in EDITABLE_STATES:
            print(f"  reusing AppStoreVersion {version} (state={state})")
            return c.patch(f"/appStoreVersions/{v['id']}", {
                "data": {"type": "appStoreVersions", "id": v["id"],
                         "attributes": {"releaseType": release_type}},
            })["data"]
        if state in LOCKED_STATES:
            sys.exit(f"AppStoreVersion {version} is {state} — cannot edit/submit it")
    print(f"  creating AppStoreVersion {version} (releaseType={release_type})")
    return c.post("/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": PLATFORM, "versionString": version,
                           "releaseType": release_type},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    })["data"]


def set_whats_new(c: Client, version_id: str, notes: str) -> None:
    locs = c.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    if not locs:
        print("  no localizations to set whatsNew on — skipping")
        return
    target = next((l for l in locs if l["attributes"]["locale"].startswith("en")), locs[0])
    loc_id = target["id"]
    locale = target["attributes"]["locale"]
    try:
        c.patch(f"/appStoreVersionLocalizations/{loc_id}", {
            "data": {"type": "appStoreVersionLocalizations", "id": loc_id,
                     "attributes": {"whatsNew": notes}},
        })
        print(f"  set whatsNew on {locale} ({len(notes)} chars)")
    except RuntimeError as e:
        # First-ever version forbids whatsNew (nothing to be "new" over).
        print(f"  WARN: could not set whatsNew on {locale} (first version?) — {e}")


def ensure_encryption_answer(c: Client, build_id: str) -> None:
    """Set usesNonExemptEncryption=false on the build if it's unset.

    A build whose Info.plist lacks ITSAppUsesNonExemptEncryption uploads with
    a null encryption answer, and the review submission 409s with
    ENTITY_ERROR.ATTRIBUTE.REQUIRED on usesNonExemptEncryption. New builds
    carry the plist key (so this is a no-op); this covers older uploads.
    """
    b = c.get(f"/builds/{build_id}")["data"]
    if b["attributes"].get("usesNonExemptEncryption") is not None:
        return
    c.patch(f"/builds/{build_id}", {
        "data": {"type": "builds", "id": build_id,
                 "attributes": {"usesNonExemptEncryption": False}},
    })
    print(f"  set usesNonExemptEncryption=false on build {build_id}")


def attach_build(c: Client, version_id: str, build_id: str) -> None:
    c.patch(f"/appStoreVersions/{version_id}/relationships/build", {
        "data": {"type": "builds", "id": build_id},
    })
    print(f"  attached build {build_id} to version {version_id}")


def submit_for_review(c: Client, app_id: str, version_id: str, do_submit: bool) -> None:
    # Reuse an open, not-yet-submitted submission if one exists; otherwise a
    # new one. A submission already WAITING/IN review can't take new items.
    subs = c.get("/reviewSubmissions", params={
        "filter[app]": app_id, "filter[platform]": PLATFORM, "limit": 10,
    })["data"]
    open_sub = next((s for s in subs
                     if s["attributes"]["state"] in ("READY_FOR_REVIEW",)), None)
    in_flight = next((s for s in subs
                      if s["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW")), None)
    if in_flight and not open_sub:
        sys.exit(f"a review submission is already {in_flight['attributes']['state']} "
                 "— cancel it in App Store Connect before resubmitting")
    if open_sub:
        sub_id = open_sub["id"]
        print(f"  reusing open reviewSubmission {sub_id}")
    else:
        sub = c.post("/reviewSubmissions", {
            "data": {"type": "reviewSubmissions",
                     "attributes": {"platform": PLATFORM},
                     "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}},
        })["data"]
        sub_id = sub["id"]
        print(f"  created reviewSubmission {sub_id}")

    # Add this version as an item (idempotent: skip if already present).
    items = c.get(f"/reviewSubmissions/{sub_id}/items")["data"]
    have = any(
        (it.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == version_id
        for it in items
    )
    if not have:
        c.post("/reviewSubmissionItems", {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                },
            }
        })
        print(f"  added version {version_id} to submission {sub_id}")
    else:
        print(f"  version {version_id} already an item of submission {sub_id}")

    if not do_submit:
        print("  --no-submit: prepared but NOT submitting (flip submitted=true to send)")
        return
    c.patch(f"/reviewSubmissions/{sub_id}", {
        "data": {"type": "reviewSubmissions", "id": sub_id,
                 "attributes": {"submitted": True}},
    })
    print(f"  SUBMITTED reviewSubmission {sub_id} for App Store review")


# ---------------------------------------------------------------- main

def clean_notes(raw: str) -> str:
    """Drop commit trailers / the 🤖 line so they don't leak into whatsNew, and
    strip anything Apple treats as markup. App Store Connect rejects a whatsNew
    that contains `<...>` (it reads angle-bracketed tokens like `<label>` or
    `<u8>` — common in commit messages — as HTML tags, error
    ENTITY_ERROR.ATTRIBUTE.INVALID.INVALID_CHARACTERS), which then leaves the
    required field empty and blocks the review submission. Neutralise the
    brackets rather than deleting the words so the notes stay readable."""
    out = []
    for line in raw.splitlines():
        s = line.strip()
        if s.startswith("Co-Authored-By:") or s.startswith("Claude-Session:") or s.startswith("🤖"):
            continue
        out.append(line)
    text = "\n".join(out).strip()
    # Comparison operators first, so `>= v0.0.18` doesn't become `)= v0.0.18`.
    text = text.replace(">=", "≥").replace("<=", "≤")
    # `<label>` -> `(label)`; any bare `<` / `>` -> a paren so nothing reads as a tag.
    text = re.sub(r"<([^>]*)>", r"(\1)", text)
    text = text.replace("<", "(").replace(">", ")")
    return text.strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="marketing version, e.g. 0.0.27")
    ap.add_argument("--build", required=True, help="build number (CFBundleVersion), e.g. 27")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--notes", help="What's New text")
    g.add_argument("--notes-file", help="file containing What's New text")
    ap.add_argument("--release-type", default="AFTER_APPROVAL",
                    choices=["AFTER_APPROVAL", "MANUAL"],
                    help="AFTER_APPROVAL = auto-publish once Apple approves (default)")
    ap.add_argument("--no-submit", action="store_true",
                    help="prepare everything but do not send to review")
    ap.add_argument("--build-timeout", type=int, default=1800,
                    help="seconds to wait for build processing (default 1800)")
    ap.add_argument("--poll", type=int, default=30, help="poll interval seconds")
    args = ap.parse_args()

    notes = ""
    if args.notes_file:
        notes = clean_notes(Path(args.notes_file).read_text())
    elif args.notes:
        notes = clean_notes(args.notes)

    c = Client(make_jwt())
    app = find_app(c)
    app_id = app["id"]
    print(f"App: {app['attributes']['name']} ({app_id}) — {BUNDLE_ID}")

    print(f"Waiting for build {args.version} ({args.build}) to finish processing…")
    build = wait_for_build(c, app_id, args.version, args.build,
                           args.build_timeout, args.poll)
    build_id = build["id"]
    print(f"Build VALID: {build_id}")

    version = find_or_create_version(c, app_id, args.version, args.release_type)
    version_id = version["id"]
    print(f"AppStoreVersion: {args.version} ({version_id})")

    if notes:
        set_whats_new(c, version_id, notes)
    else:
        print("  no notes provided — leaving whatsNew unchanged")

    ensure_encryption_answer(c, build_id)
    attach_build(c, version_id, build_id)
    submit_for_review(c, app_id, version_id, do_submit=not args.no_submit)
    print("done.")


if __name__ == "__main__":
    main()
