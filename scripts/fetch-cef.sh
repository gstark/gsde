#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_VERSION="${CEF_VERSION:-147.0.10+gd58e84d+chromium-147.0.7727.118}"
CEF_PLATFORM="${CEF_PLATFORM:-macosarm64}"
CEF_DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
CEF_ARCHIVE="$CEF_DIST.tar.bz2"
CEF_URL="${CEF_URL:-https://cef-builds.spotifycdn.com/$CEF_ARCHIVE}"
DOWNLOAD_DIR="$ROOT_DIR/build/downloads"
EXTERNAL_DIR="$ROOT_DIR/external"
TARGET_DIR="$EXTERNAL_DIR/cef"

mkdir -p "$DOWNLOAD_DIR" "$EXTERNAL_DIR"

if [[ -f "$TARGET_DIR/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]]; then
  echo "CEF is already available at $TARGET_DIR"
  exit 0
fi

if [[ ! -f "$DOWNLOAD_DIR/$CEF_ARCHIVE" ]]; then
  echo "Downloading $CEF_URL"
  curl -L --fail --progress-bar "$CEF_URL" -o "$DOWNLOAD_DIR/$CEF_ARCHIVE"
fi

rm -rf "$EXTERNAL_DIR/$CEF_DIST" "$TARGET_DIR"
tar -xjf "$DOWNLOAD_DIR/$CEF_ARCHIVE" -C "$EXTERNAL_DIR"
mv "$EXTERNAL_DIR/$CEF_DIST" "$TARGET_DIR"

echo "CEF is available at $TARGET_DIR"
