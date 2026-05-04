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
    created_count=$(grep -Ec 'CEF browser #[0-9]+ created with native view' "$LOG" || true)
    loaded_browser_count=$(grep -E 'CEF browser #[0-9]+ load end: HTTP 200' "$LOG" | sed -E 's/.*CEF browser #([0-9]+) load end.*/\1/' | sort -u | wc -l | tr -d ' ' || true)
    if [[ "$created_count" -ge "$BROWSER_PANES" && "$loaded_browser_count" -ge "$BROWSER_PANES" ]]; then
      if [[ "${GSDE_SMOKE_GRACEFUL_QUIT:-0}" == "1" ]]; then
        osascript -e 'tell application "GSDE" to quit' >/dev/null 2>&1 || kill "$app_pid" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
          if ! kill -0 "$app_pid" >/dev/null 2>&1; then break; fi
          sleep 0.25
        done
        if kill -0 "$app_pid" >/dev/null 2>&1; then
          echo "GSDE did not exit after graceful quit request" >&2
          cat "$LOG" >&2
          exit 1
        fi
        if ! wait "$app_pid"; then
          echo "GSDE exited non-zero after graceful quit request" >&2
          cat "$LOG" >&2
          exit 1
        fi
        closed_browser_count=$(grep -E 'CEF browser #[0-9]+ on_before_close' "$LOG" | sed -E 's/.*CEF browser #([0-9]+) on_before_close.*/\1/' | sort -u | wc -l | tr -d ' ' || true)
        if [[ "$closed_browser_count" -lt "$BROWSER_PANES" ]] || ! grep -q 'CEF shut down' "$LOG"; then
          echo "CEF graceful shutdown incomplete: $closed_browser_count browser(s) closed" >&2
          cat "$LOG" >&2
          exit 1
        fi
        echo "CEF smoke test passed: $created_count browser(s), $loaded_browser_count browser(s) loaded, $closed_browser_count browser(s) closed gracefully"
        cat "$LOG"
        exit 0
      fi
      echo "CEF smoke test passed: $created_count browser(s), $loaded_browser_count browser(s) loaded successfully"
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
  created_count=$(grep -Ec 'CEF browser #[0-9]+ created with native view' "$LOG" || true)
  loaded_browser_count=$(grep -E 'CEF browser #[0-9]+ load end: HTTP 200' "$LOG" | sed -E 's/.*CEF browser #([0-9]+) load end.*/\1/' | sort -u | wc -l | tr -d ' ' || true)
  echo "Observed $created_count created browser(s), $loaded_browser_count browser(s) loaded successfully" >&2
  cat "$LOG" >&2
fi
cat /tmp/gsde-cef-smoke.err >&2 || true
exit 1
