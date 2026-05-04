#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/GSDE"

pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
pkill -f 'GSDE Helper' >/dev/null 2>&1 || true

defaults delete personal.gsde.app >/dev/null 2>&1 || true
rm -rf "$APP_SUPPORT/Chromium"
rm -f /tmp/gsde_chromium.log /tmp/gsde-cef-smoke.out /tmp/gsde-cef-smoke.err

echo "Reset GSDE saved state and Chromium profile data."
