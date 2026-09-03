---
name: build-dmg-open
description: Build the latest Kannu app and create/open the DMG artifact. Use when the user asks to build DMG, package a release DMG, or rebuild and open build/Kannu.dmg.
disable-model-invocation: true
---

# Build DMG And Open

## Purpose
Run the repo build wrapper to produce `build/Kannu.dmg` from current code and open it in Finder.

## Steps
1. Run from repo root:
   - `./scripts/build-dmg.sh`
2. This script already:
   - builds Release,
   - packages `build/Kannu.dmg`,
   - opens the DMG by default.

## Notes
- For headless runs, use `./scripts/build-dmg.sh --no-open`.
- If sandboxed execution blocks SwiftPM/Xcode cache writes, rerun with elevated permissions.
