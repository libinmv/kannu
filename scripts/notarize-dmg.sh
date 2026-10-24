#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <path-to-dmg>" >&2
  exit 1
fi

DMG_PATH="$1"

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

for var in APPLE_ID APPLE_NOTARIZATION_PASSWORD APPLE_TEAM_ID; do
  if [ -z "${!var:-}" ]; then
    echo "Required environment variable $var is not set." >&2
    exit 1
  fi
done

echo "Submitting $DMG_PATH for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_NOTARIZATION_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

# Stapling fetches the ticket from Apple's CloudKit service. On 2026-10-22 a dropped connection
# there ("The network connection was lost", stapler error 68) failed the 1.4.0 beta 2 release
# after Apple had already accepted the DMG; a re-run of the whole job went through. So the staple
# is retried, with a growing wait, before the release gives up.
echo "Stapling notarization ticket..."
staple_attempts=5
staple_delay="${STAPLE_RETRY_DELAY:-15}"
for attempt in $(seq 1 "$staple_attempts"); do
  if xcrun stapler staple "$DMG_PATH"; then
    break
  fi
  if [ "$attempt" -eq "$staple_attempts" ]; then
    echo "Stapling failed after $staple_attempts attempts." >&2
    exit 1
  fi
  delay=$((attempt * staple_delay))
  echo "Stapling failed (attempt $attempt of $staple_attempts); retrying in ${delay}s..."
  sleep "$delay"
done
xcrun stapler validate "$DMG_PATH"

echo "Notarization complete for $DMG_PATH"
