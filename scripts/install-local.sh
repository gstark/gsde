#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GSDE"
APP_PATH="/Applications/${APP_NAME}.app"
BUILD_APP="build/${APP_NAME}.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "Quitting ${APP_NAME} if running…"
osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
sleep 1

echo "Building ${BUILD_APP}…"
make app-with-chromium

echo "Ad-hoc signing ${BUILD_APP}…"
codesign --force --deep --sign - "${BUILD_APP}"

echo "Replacing ${APP_PATH}…"
rm -rf "${APP_PATH}"
ditto "${BUILD_APP}" "${APP_PATH}"

echo "Clearing quarantine attribute if present…"
xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

echo "Done. Launching ${APP_NAME}…"
open "${APP_PATH}"
