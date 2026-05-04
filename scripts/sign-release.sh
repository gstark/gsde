#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-build/GSDE.app}"
IDENTITY="${GSDE_CODESIGN_IDENTITY:-}"
ENTITLEMENTS="${GSDE_ENTITLEMENTS:-}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 2
fi

if [[ -z "$IDENTITY" ]]; then
  echo "Set GSDE_CODESIGN_IDENTITY to a Developer ID Application identity" >&2
  exit 2
fi

args=(--force --deep --options runtime --timestamp --sign "$IDENTITY")
if [[ -n "$ENTITLEMENTS" ]]; then
  args+=(--entitlements "$ENTITLEMENTS")
fi
args+=("$APP_BUNDLE")

codesign "${args[@]}"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "Signed and verified: $APP_BUNDLE"
