#!/usr/bin/env bash
set -euo pipefail

BROWSER_PANES="${GSDE_BROWSER_PANES:-2}"
WAIT_SECONDS="${GSDE_SMOKE_WAIT_SECONDS:-35}"
APP="build/GSDE.app/Contents/MacOS/GSDE"
DEFAULT_URLS=(
  "https://example.com"
  "https://www.wikipedia.org"
  "https://developer.apple.com"
  "https://chromium.org"
)
LOG="/tmp/gsde_chromium.log"
PROFILE_DIR="$HOME/Library/Application Support/GSDE/Chromium"

if [[ ! -x "$APP" ]]; then
  echo "Missing $APP; run make app-with-chromium first" >&2
  exit 2
fi

pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
pkill -f 'GSDE Helper' >/dev/null 2>&1 || true
rm -f "$PROFILE_DIR/SingletonLock" "$PROFILE_DIR/SingletonCookie" "$PROFILE_DIR/SingletonSocket"
rm -f "$LOG"

if [[ -z "${GSDE_BROWSER_URLS:-}" ]]; then
  urls=()
  for ((i = 0; i < BROWSER_PANES; i++)); do
    urls+=("${DEFAULT_URLS[$((i % ${#DEFAULT_URLS[@]}))]}")
  done
  GSDE_BROWSER_URLS="$(IFS=,; echo "${urls[*]}")"
fi
export GSDE_BROWSER_URLS

GSDE_ENABLE_CEF=1 GSDE_BROWSER_PANES="$BROWSER_PANES" "$APP" >/tmp/gsde-cef-smoke.out 2>/tmp/gsde-cef-smoke.err &
app_pid=$!

cleanup() {
  kill "$app_pid" >/dev/null 2>&1 || true
  pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
  pkill -f 'GSDE Helper' >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 "$WAIT_SECONDS"); do
  if [[ -f "$LOG" ]]; then
    created_count=$(grep -c 'CEF browser created with native view' "$LOG" || true)
    loaded_count=$(grep -c 'CEF load end: HTTP 200' "$LOG" || true)
    if [[ "$created_count" -ge "$BROWSER_PANES" && "$loaded_count" -ge "$BROWSER_PANES" ]]; then
      echo "CEF smoke test passed: $created_count browser(s), $loaded_count successful load(s)"
      cat "$LOG"
      exit 0
    fi
  fi
  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    echo "GSDE exited before CEF smoke test completed" >&2
    cat /tmp/gsde-cef-smoke.err >&2 || true
    exit 1
  fi
  sleep 1
done

echo "CEF smoke test timed out after ${WAIT_SECONDS}s" >&2
if [[ -f "$LOG" ]]; then
  cat "$LOG" >&2
fi
cat /tmp/gsde-cef-smoke.err >&2 || true
exit 1
