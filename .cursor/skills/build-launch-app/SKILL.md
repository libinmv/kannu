---
name: build-launch-app
description: Build the latest Kannu app and launch it locally. Use when the user asks to run locally, launch the app, or skip DMG packaging.
disable-model-invocation: true
---

# Build And Launch App

## Purpose
Run the local workflow to build `Kannu.app` and launch it directly, without creating a DMG.

## Steps
1. Run from repo root:
   - `./scripts/build-launch-app.sh`
2. This script:
   - builds Release,
   - writes `build/Build/Products/Release/Kannu.app`,
   - opens the app by default.

## Options
- `./scripts/build-launch-app.sh --skip-build` launches an existing app build.
- `./scripts/build-launch-app.sh --no-open` builds only, no launch.
