---
name: release
description: Sign, tag, and ship MovementLogger (iOS + embedded Watch app) to TestFlight and the App Store — the manual-signing CI setup, the required GitHub Actions secrets, the tag-driven release workflow, and the versioning policy. Use when cutting a release, debugging an Archive/Export/upload failure, or re-rolling signing certificates or provisioning profiles.
---

# Releasing MovementLogger

Credential *locations* (the Apple API key, the `.p12` backup) are deliberately
NOT in this file — it is checked into a public repo. They live in this project's
Claude memory (`~/.claude/projects/-Users-zdavatz-software-movement-logger-ios/memory/`,
see `ios-signing-credential-locations`).

## Signing

`DEVELOPMENT_TEAM = 4B37356EGR` (ywesee GmbH). Local Xcode dev still uses `CODE_SIGN_STYLE = Automatic`. **CI signs MANUALLY** (overridden on the `xcodebuild` command line): the old automatic flow used `-allowProvisioningUpdates` + the App Store Connect API key, which makes Xcode mint a *new managed certificate on every clean runner*. Apple caps certificates per account, so after enough releases the cap is hit and Archive fails with "Your account has reached the maximum number of certificates" (this is what broke iOS v0.0.15 — not a code issue). Manual signing pins the one fixed `APPLE_CERT_P12_BASE64` distribution cert + a fixed App Store provisioning profile (`APPLE_PROVISIONING_PROFILE_BASE64`), and drops `-allowProvisioningUpdates`, so CI never creates certificates. The Apple API credentials are still used, but only for the `altool` upload, which does not create certs.

**Duplicate Apple Distribution certs gotcha.** The keychain has three `Apple Distribution: ywesee GmbH (4B37356EGR)` entries (expired 2022, expired 2024, current expires 2027). Xcode auto-picks the latest, but anything that exports by CN alone (e.g. `security export -t identities`, a naive PEM-split script) may grab the FIRST match — which is the expired 2022 one. The CI cert-bundle in `APPLE_CERT_P12_BASE64` was rebuilt to disambiguate by `notAfter` and pick the latest. If you ever need to re-roll the cert secret, use the same disambiguation (sort candidates by `notAfter`, take the last).

## Release (tag-driven CI)

**Versioning policy — REVISED 11.7.2026: the 0.0.x TestFlight train is dead.**
Apple rejects ANY upload (TestFlight included) whose
`CFBundleShortVersionString` is lower than the last APPROVED store version
(error 90062, hit when v0.0.31 tried to upload against approved 1.0.23).
Everything now rides the `1.x.x` train: every tag uploads to TestFlight
(usable by internal testers as soon as processing finishes, independent of
review) and auto-submits to the App Store. The historical split below is
kept for context only — do NOT tag 0.0.x anymore.

**Historical policy (obsolete, pre-11.7.2026):**
- **`0.0.x` = binary / TestFlight builds** — bumped per dev iteration, installed to the phone over USB (`devicectl`) and/or uploaded to App Store Connect for TestFlight, but **never auto-submitted** to the public App Store. These are what I bump+install while iterating (currently 0.0.30).
- **`1.x.x+` = public App Store releases** — the only tags that auto-submit for review. Recent store/TestFlight builds run on the 1.0.x train (last tagged **1.0.17**; Watch water-temp work bumped source through 1.0.22 untagged). This release (Rides-tab watch-GPS map + shareable PNG) is **1.0.23** (the App Store version string must be > the live one, and a build's `CFBundleShortVersionString` must match the store version it's submitted under, so a store build is literally built as `1.0.x`, not `0.0.x`).
- The workflow gates the submit-for-review step on `MAJOR >= 1` (`steps.ver.outputs.store`), so a `0.0.x` tag builds + uploads but stops before publishing, and only a `v1.x.x` tag actually goes to the store. The auto-submit (`scripts/submit_for_review.py`) sets `releaseType=AFTER_APPROVAL` (auto-publish on Apple's approval — the iOS analogue of Android's `--track production --release-status completed`) and answers export-compliance via `ITSAppUsesNonExemptEncryption=false` in Info.plist. Apple still requires human review (~1 day); no API skips it.

Push `vX.Y.Z` → CI builds, signs, uploads to App Store Connect, and cuts a GitHub release with the IPA attached. Workflow lives at `.github/workflows/release.yml`. Trigger:

```sh
git tag v0.0.6
git push origin v0.0.6
```

The workflow parses the tag (`v0.0.6` → version `0.0.6`, build `6` from the patch component), sed-patches `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` into the pbxproj at build time (so the source on the tagged commit doesn't need to be re-bumped), then runs `xcodebuild archive` → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → `gh release create`. **Manual signing**: the imported `.p12` identity is discovered from the keychain (`SIGN_IDENTITY`), the App Store profile is decoded + installed and its `Name` read with PlistBuddy (`PROFILE_NAME`), both passed explicitly to `xcodebuild` (`CODE_SIGN_STYLE=Manual`) and into `ExportOptions.plist` (`signingStyle=manual`). No `-allowProvisioningUpdates`.

Required GitHub Actions secrets (set once via `gh secret set --repo zdavatz/movement_logger_ios`):

- `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8_BASE64` — base64 of the App Store Connect API `.p8` key (upload only)
- `APPLE_CERT_P12_BASE64` — base64 of slim single-identity `.p12` for `Apple Distribution: ywesee GmbH (4B37356EGR)` (NOT a full keychain export — those exceed GitHub's secret size limit)
- `APPLE_CERT_PASSWORD`, `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64` — **(manual signing)** base64 of the App Store **distribution** `.mobileprovision` for `ch.pumptsueri.movementlogger` (Apple Developer portal → Profiles → create an App Store profile bound to the `APPLE_CERT_P12_BASE64` cert, download, `base64 -i profile.mobileprovision`). Re-roll whenever the distribution cert is re-rolled.
- `APPLE_WATCH_PROVISIONING_PROFILE_BASE64` — **(added v1.0.23, for the embedded Watch app)** base64 of the App Store distribution `.mobileprovision` for `ch.pumptsueri.movementlogger.watchkitapp`, bound to the **same** distribution cert. The build embeds the Apple Watch app, so its bundle id needs its OWN profile — the main-app profile can't sign it (Archive fails: *"app ID … does not match bundle ID …watchkitapp"* + missing HealthKit / Shallow-Depth entitlements). Generate with `scripts/create_watch_profile.py create` (reads the cert from the main-app CI profile so both match) and `gh secret set APPLE_WATCH_PROVISIONING_PROFILE_BASE64`. Re-roll whenever the distribution cert is re-rolled. **Per-target signing: `xcodebuild archive` accepts only ONE `PROVISIONING_PROFILE_SPECIFIER` on the CLI, and manual signing does NOT auto-select installed profiles — so a CI-only step (`scripts/ci_manual_signing.py`, via the `pbxproj` lib) writes `CODE_SIGN_STYLE = Manual` + each target's own `PROVISIONING_PROFILE_SPECIFIER` into the app and Watch targets' Release build settings before Archive.** That edit is never committed (local dev keeps Automatic); the Archive step then passes no signing overrides, and Export pins both bundle ids in `ExportOptions.plist`. Verified end-to-end on a throwaway `v0.0.99` tag (Archive + Export succeeded). (Store submission of a Watch-containing build ALSO needs an `APP_WATCH_SERIES_4` 368×448 screenshot — see the screenshots section / `scripts/upload_store_screenshots.py`.)

A canonical backup of the slim Apple Distribution `.p12` + its password exists (re-encrypted with modern AES-256 instead of the RC2-40 default that `security export` produces; OpenSSL 3 refuses to read the latter without `-legacy`). Its location is in project memory, not here.
