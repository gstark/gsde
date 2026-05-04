#!/usr/bin/env bash
set -euo pipefail

APP="build/GSDE.app/Contents/MacOS/GSDE"
LOG="/tmp/gsde_chromium.log"
WAIT_SECONDS="${GSDE_DEFAULT_SMOKE_WAIT_SECONDS:-5}"

if [[ ! -x "$APP" ]]; then
  echo "Missing $APP; run make app first" >&2
  exit 2
fi

pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
pkill -f 'GSDE Helper' >/dev/null 2>&1 || true
rm -f "$LOG"

GSDE_BROWSER_PANES="${GSDE_BROWSER_PANES:-1}" "$APP" >/tmp/gsde-default-smoke.out 2>/tmp/gsde-default-smoke.err &
app_pid=$!

cleanup() {
  kill "$app_pid" >/dev/null 2>&1 || true
  pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 "$WAIT_SECONDS"); do
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    echo "GSDE exited before default smoke test completed" >&2
    cat /tmp/gsde-default-smoke.err >&2 || true
    exit 1
  fi
  sleep 1
done

if [[ -f "$LOG" ]] && grep -q 'CEF initialized' "$LOG"; then
  echo "Default launch unexpectedly initialized CEF" >&2
  cat "$LOG" >&2
  exit 1
fi

osascript -e 'tell application "GSDE" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then break; fi
  sleep 0.25
done

if kill -0 "$app_pid" >/dev/null 2>&1; then
  echo "GSDE did not quit after default smoke test" >&2
  exit 1
fi

if ! wait "$app_pid"; then
  echo "GSDE exited non-zero after default smoke test" >&2
  cat /tmp/gsde-default-smoke.err >&2 || true
  exit 1
fi

echo "Default smoke test passed: app launched without initializing CEF"
