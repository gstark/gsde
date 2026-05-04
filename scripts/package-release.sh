#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-build/GSDE.app}"
if [[ -n "${GSDE_VERSION:-}" ]]; then
  VERSION="$GSDE_VERSION"
elif [[ -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
  short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
  build_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
  if [[ -n "$short_version" && -n "$build_version" ]]; then
    VERSION="${short_version}-${build_version}"
  else
    VERSION=""
  fi
else
  VERSION=""
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --always 2>/dev/null || date +%Y%m%d%H%M%S)"
fi

if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  VERSION="${VERSION}-dirty"
fi
DIST_DIR="${GSDE_DIST_DIR:-dist}"
ARCHIVE_NAME="GSDE-${VERSION}.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 2
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH"

if [[ "${GSDE_ADHOC_SIGN:-0}" == "1" ]]; then
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Failed to create $ARCHIVE_PATH" >&2
  exit 1
fi

size_bytes=$(stat -f%z "$ARCHIVE_PATH")
echo "Release archive created: $ARCHIVE_PATH ($size_bytes bytes)"
