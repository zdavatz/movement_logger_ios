# Archived app previews (superseded)

These are the previews that shipped up to v1.0.27 and were **rejected** for
v1.0.31 under App Store Guideline 2.3.4 — they are the app's composite export
(`combined_*.mov`) scaled into 1080×1920, which leaves 216 px of black bars down
each side, and Apple reads that padding as "framing around the video screen
capture of the app".

Kept for reference only. They are NOT uploaded: `scripts/upload_store_previews.py`
globs `screenshots/store/previews/*.mp4` at the top level and does not recurse,
so anything in here is ignored.

Do not restore these as live previews. See `.claude/skills/store-assets/SKILL.md`.
