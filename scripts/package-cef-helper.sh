#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <helper-binary> <frameworks-dir> <app-name> <bundle-id-prefix>" >&2
  exit 2
fi

HELPER_BINARY="$1"
FRAMEWORKS_DIR="$2"
APP_NAME="$3"
BUNDLE_ID_PREFIX="$4"

if [[ ! -f "$HELPER_BINARY" ]]; then
  exit 0
fi

suffixes=("" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)")
ids=("" ".alerts" ".gpu" ".plugin" ".renderer")

for i in "${!suffixes[@]}"; do
  suffix="${suffixes[$i]}"
  id_suffix="${ids[$i]}"
  helper_name="$APP_NAME Helper$suffix"
  helper_bundle="$FRAMEWORKS_DIR/$helper_name.app"
  helper_contents="$helper_bundle/Contents"
  helper_macos="$helper_contents/MacOS"
  helper_frameworks="$helper_contents/Frameworks"

  mkdir -p "$helper_macos" "$helper_frameworks"
  cp "$HELPER_BINARY" "$helper_macos/$helper_name"
  chmod +x "$helper_macos/$helper_name"
  ln -sfn "../../../Chromium Embedded Framework.framework" "$helper_frameworks/Chromium Embedded Framework.framework"

  printf 'APPL????' > "$helper_contents/PkgInfo"

  cat > "$helper_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$helper_name</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID_PREFIX.helper$id_suffix</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$helper_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

done
