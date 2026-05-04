#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
PROFILE="${GSDE_NOTARY_PROFILE:-}"
APPLE_ID="${GSDE_NOTARY_APPLE_ID:-}"
TEAM_ID="${GSDE_NOTARY_TEAM_ID:-}"
PASSWORD="${GSDE_NOTARY_PASSWORD:-}"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 path/to/GSDE.zip" >&2
  exit 2
fi

if [[ -n "$PROFILE" ]]; then
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
elif [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$PASSWORD" ]]; then
  xcrun notarytool submit "$ARCHIVE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD" --wait
else
  echo "Set GSDE_NOTARY_PROFILE or GSDE_NOTARY_APPLE_ID/GSDE_NOTARY_TEAM_ID/GSDE_NOTARY_PASSWORD" >&2
  exit 2
fi

echo "Notarization complete: $ARCHIVE"
