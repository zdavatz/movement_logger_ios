#!/usr/bin/env python3
"""CI-only: rewrite the pbxproj for MANUAL, per-target code signing before the
release `xcodebuild archive`.

Local Xcode dev keeps `CODE_SIGN_STYLE = Automatic` (see CLAUDE.md) — this
script runs ONLY on the CI runner and its edits are never committed. It sets,
on each target's **Release** configuration, manual signing with that target's
own App Store provisioning profile, because `xcodebuild archive` accepts only
ONE `PROVISIONING_PROFILE_SPECIFIER` on the command line and the app +
embedded Watch app need different profiles.

Usage:
  ci_manual_signing.py "<main profile name>" "<watch profile name>" "<identity>"
"""
import sys
from pbxproj import XcodeProject

PBX = "MovementLogger.xcodeproj/project.pbxproj"
TARGET_PROFILE = {
    "MovementLogger": 0,             # main app  → argv[1]
    "MovementLogger Watch App": 1,   # watch app → argv[2]
}


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main_profile, watch_profile, identity = sys.argv[1], sys.argv[2], sys.argv[3]
    profiles = [main_profile, watch_profile]
    p = XcodeProject.load(PBX)
    for target, idx in TARGET_PROFILE.items():
        p.set_flags("CODE_SIGN_STYLE", "Manual",
                    target_name=target, configuration_name="Release")
        p.set_flags("PROVISIONING_PROFILE_SPECIFIER", profiles[idx],
                    target_name=target, configuration_name="Release")
        p.set_flags("CODE_SIGN_IDENTITY", identity,
                    target_name=target, configuration_name="Release")
        # A leftover automatic-signing PROVISIONING_PROFILE_SPECIFIER of "" or a
        # DEVELOPMENT_TEAM mismatch is harmless; the three above are what
        # xcodebuild needs to resolve manual signing per target.
        print(f"  {target}: Manual, profile='{profiles[idx]}'")
    p.save()
    print("patched Release signing for both targets")


if __name__ == "__main__":
    main()
