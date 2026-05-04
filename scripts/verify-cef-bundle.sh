#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-build/GSDE.app}"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
CEF_FRAMEWORK="$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
CEF_BINARY="$CEF_FRAMEWORK/Chromium Embedded Framework"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 2
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/GSDE" ]]; then
  echo "Missing executable: $APP_BUNDLE/Contents/MacOS/GSDE" >&2
  exit 1
fi

if [[ ! -d "$CEF_FRAMEWORK" || ! -f "$CEF_BINARY" ]]; then
  echo "Missing bundled CEF framework: $CEF_FRAMEWORK" >&2
  exit 1
fi

helper_names=(
  "GSDE Helper"
  "GSDE Helper (Alerts)"
  "GSDE Helper (GPU)"
  "GSDE Helper (Plugin)"
  "GSDE Helper (Renderer)"
)

for helper_name in "${helper_names[@]}"; do
  helper_app="$FRAMEWORKS_DIR/$helper_name.app"
  helper_exe="$helper_app/Contents/MacOS/$helper_name"
  helper_info="$helper_app/Contents/Info.plist"

  if [[ ! -d "$helper_app" ]]; then
    echo "Missing helper app: $helper_app" >&2
    exit 1
  fi
  if [[ ! -x "$helper_exe" ]]; then
    echo "Missing or non-executable helper binary: $helper_exe" >&2
    exit 1
  fi
  if [[ ! -f "$helper_info" ]]; then
    echo "Missing helper Info.plist: $helper_info" >&2
    exit 1
  fi

  plist_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$helper_info" 2>/dev/null || true)
  if [[ "$plist_executable" != "$helper_name" ]]; then
    echo "Helper CFBundleExecutable mismatch for $helper_name: '$plist_executable'" >&2
    exit 1
  fi

  plist_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper_info" 2>/dev/null || true)
  if [[ -z "$plist_identifier" ]]; then
    echo "Helper CFBundleIdentifier missing for $helper_name" >&2
    exit 1
  fi
done

echo "CEF bundle verification passed: framework and ${#helper_names[@]} helper app(s) present"
