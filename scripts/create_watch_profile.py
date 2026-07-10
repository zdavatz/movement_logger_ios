#!/usr/bin/env python3
"""Create (or reuse) an App Store provisioning profile for the Apple Watch app
bundle id, bound to the SAME distribution certificate the main-app CI profile
uses, and print its base64 .mobileprovision to stdout (for a GitHub secret).

Usage:
  ./create_watch_profile.py explore     # print certs / bundleIds / profiles
  ./create_watch_profile.py create      # create-or-reuse + print base64 profile
"""
from __future__ import annotations
import base64, json, sys, time
from pathlib import Path
import jwt, requests

CREDS = json.loads((Path.home() / ".apple" / "credentials.json").read_text())
A = CREDS.get("apple", CREDS)
KID, ISS = A["api_key_id"], A["api_issuer_id"]
KEY = Path(A["api_key_path"].replace("~", str(Path.home()))).read_text()
API = "https://api.appstoreconnect.apple.com/v1"
WATCH_BUNDLE = "ch.pumptsueri.movementlogger.watchkitapp"
MAIN_PROFILE_NAME = "Movement Logger App Store CI"
WATCH_PROFILE_NAME = "Movement Logger Watch App Store CI"


def tok() -> str:
    return jwt.encode({"iss": ISS, "iat": int(time.time()), "exp": int(time.time()) + 900,
                       "aud": "appstoreconnect-v1"}, KEY, algorithm="ES256",
                      headers={"kid": KID, "typ": "JWT"})


def api(method, path, **kw):
    h = {"Authorization": f"Bearer {tok()}", "Content-Type": "application/json"}
    r = requests.request(method, f"{API}{path}", headers=h, **kw)
    if r.status_code >= 300:
        raise SystemExit(f"{method} {path} -> {r.status_code}\n{r.text[:1500]}")
    return r.json() if r.text else {}


def main_profile_cert_id() -> str | None:
    """The certificate id the existing main-app CI profile is bound to."""
    profs = api("GET", "/profiles", params={"filter[name]": MAIN_PROFILE_NAME,
                                            "include": "certificates", "limit": 5})
    for p in profs.get("data", []):
        certs = p.get("relationships", {}).get("certificates", {}).get("data", [])
        if certs:
            return certs[0]["id"]
    return None


def explore():
    print("== distribution certificates ==")
    certs = api("GET", "/certificates", params={"limit": 50})
    for c in certs["data"]:
        at = c["attributes"]
        if "DISTRIBUTION" in at["certificateType"]:
            print(f"  {c['id']}  {at['certificateType']:24} {at.get('displayName','')}  "
                  f"exp={at.get('expirationDate')}  serial={at.get('serialNumber')}")
    print(f"\n== bundleId {WATCH_BUNDLE} ==")
    bids = api("GET", "/bundleIds", params={"filter[identifier]": WATCH_BUNDLE, "limit": 5})
    for b in bids["data"]:
        print(f"  {b['id']}  platform={b['attributes'].get('platform')}  "
              f"name={b['attributes'].get('name')}")
    print(f"\n== main-app CI profile cert ==")
    print(f"  {main_profile_cert_id()}")
    print(f"\n== existing profiles for watch / named '{WATCH_PROFILE_NAME}' ==")
    profs = api("GET", "/profiles", params={"include": "bundleId", "limit": 200})
    for p in profs["data"]:
        nm = p["attributes"]["name"]
        st = p["attributes"].get("profileState")
        ty = p["attributes"].get("profileType")
        if "atch" in nm or nm == WATCH_PROFILE_NAME:
            print(f"  {p['id']}  {nm!r}  {ty}  {st}")


def create():
    bids = api("GET", "/bundleIds", params={"filter[identifier]": WATCH_BUNDLE, "limit": 5})
    if not bids["data"]:
        raise SystemExit(f"bundleId {WATCH_BUNDLE} not registered — build once with "
                         "-allowProvisioningUpdates to auto-register it.")
    bundle_id = bids["data"][0]["id"]
    plat = bids["data"][0]["attributes"].get("platform")
    cert_id = main_profile_cert_id()
    if not cert_id:
        raise SystemExit(f"couldn't find cert on '{MAIN_PROFILE_NAME}'")
    ptype = "IOS_APP_STORE"  # watch app bundle id lives in the iOS/Universal family

    # Reuse if a valid profile with our name already exists.
    existing = api("GET", "/profiles", params={"filter[name]": WATCH_PROFILE_NAME, "limit": 5})
    for p in existing.get("data", []):
        if p["attributes"].get("profileState") == "ACTIVE":
            content = p["attributes"]["profileContent"]
            sys.stderr.write(f"reusing existing profile {p['id']} "
                             f"({p['attributes']['name']})\n")
            print(content)
            return
        else:  # stale/invalid — delete so we can recreate cleanly
            sys.stderr.write(f"deleting stale profile {p['id']} "
                             f"({p['attributes'].get('profileState')})\n")
            api("DELETE", f"/profiles/{p['id']}")

    body = {"data": {
        "type": "profiles",
        "attributes": {"name": WATCH_PROFILE_NAME, "profileType": ptype},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        }}}
    sys.stderr.write(f"creating '{WATCH_PROFILE_NAME}' type={ptype} "
                     f"bundle={bundle_id} (platform={plat}) cert={cert_id}\n")
    resp = api("POST", "/profiles", json=body)
    content = resp["data"]["attributes"]["profileContent"]
    print(content)   # already base64 of the .mobileprovision


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "explore"
    (explore if cmd == "explore" else create)()
