#!/usr/bin/env bash
set -euo pipefail

APP="build/GSDE.app/Contents/MacOS/GSDE"
CONFIG="${GSDE_CONFIG:-docs/sample-configs/configured-smoke.toml}"
WAIT_SECONDS="${GSDE_CONFIGURED_SMOKE_WAIT_SECONDS:-45}"
EXPECTED_BROWSERS="${GSDE_CONFIGURED_SMOKE_BROWSER_PANES:-2}"
EXPECTED_LAYOUT_ID="${GSDE_CONFIGURED_SMOKE_EXPECT_LAYOUT_ID-smoke}"
EXPECTED_URL_SUBSTRINGS="${GSDE_CONFIGURED_SMOKE_EXPECT_URL_SUBSTRINGS:-example.com,iana.org}"
LOG="/tmp/gsde_chromium.log"
STDOUT_LOG="/tmp/gsde-configured-smoke.out"
STDERR_LOG="/tmp/gsde-configured-smoke.err"
PROFILE_ROOT="$HOME/Library/Application Support/GSDE/Chromium"

if [[ ! -x "$APP" ]]; then
  echo "Missing $APP; run make app-with-chromium first" >&2
  exit 2
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing configured smoke config $CONFIG" >&2
  exit 2
fi

pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
pkill -f 'GSDE Helper' >/dev/null 2>&1 || true
rm -f "$PROFILE_ROOT/SingletonLock" "$PROFILE_ROOT/SingletonCookie" "$PROFILE_ROOT/SingletonSocket"
rm -rf "$PROFILE_ROOT/Profiles/smoke-docs" "$PROFILE_ROOT/Profiles/smoke-reference"
rm -f "$LOG" "$STDOUT_LOG" "$STDERR_LOG"

# Legacy pane environment variables intentionally bypass TOML configs in GSDE.
# Clear inherited values so this smoke test always exercises the configured path.
unset GSDE_BROWSER_PANES GSDE_BROWSER_URLS

GSDE_CONFIG="$CONFIG" "$APP" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
app_pid=$!

cleanup() {
  kill "$app_pid" >/dev/null 2>&1 || true
  pkill -f 'GSDE.app/Contents' >/dev/null 2>&1 || true
  pkill -f 'GSDE Helper' >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_configured_launch() {
  if ! grep -q 'GSDE config: loaded TOML workspace config' "$STDERR_LOG"; then
    echo "GSDE did not report loading the TOML workspace config" >&2
    cat "$STDERR_LOG" >&2 || true
    return 1
  fi
  if [[ -n "$EXPECTED_LAYOUT_ID" ]]; then
    if ! grep -Fq "using Mosaic workspace layout $EXPECTED_LAYOUT_ID" "$STDERR_LOG"; then
      echo "GSDE did not launch the expected configured mosaic layout '$EXPECTED_LAYOUT_ID'" >&2
      cat "$STDERR_LOG" >&2 || true
      return 1
    fi
  fi
  IFS=',' read -r -a expected_url_substrings <<< "$EXPECTED_URL_SUBSTRINGS"
  for expected in "${expected_url_substrings[@]}"; do
    expected="$(echo "$expected" | xargs)"
    [[ -z "$expected" ]] && continue
    if ! grep -E 'CEF browser #[0-9]+ load end: HTTP 200 URL ' "$LOG" | grep -Fq "$expected"; then
      echo "Expected successful configured browser load URL containing '$expected'" >&2
      cat "$LOG" >&2
      return 1
    fi
  done
}

for _ in $(seq 1 "$WAIT_SECONDS"); do
  if [[ -f "$LOG" ]]; then
    created_count=$(grep -Ec 'CEF browser #[0-9]+ created with native view' "$LOG" || true)
    loaded_browser_count=$(grep -E 'CEF browser #[0-9]+ load end: HTTP 200' "$LOG" | sed -E 's/.*CEF browser #([0-9]+) load end.*/\1/' | sort -u | wc -l | tr -d ' ' || true)
    if [[ "$created_count" -ge "$EXPECTED_BROWSERS" && "$loaded_browser_count" -ge "$EXPECTED_BROWSERS" ]]; then
      verify_configured_launch
      osascript -e 'tell application "GSDE" to quit' >/dev/null 2>&1 || kill "$app_pid" >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do
        if ! kill -0 "$app_pid" >/dev/null 2>&1; then break; fi
        sleep 0.25
      done
      if kill -0 "$app_pid" >/dev/null 2>&1; then
        echo "GSDE did not exit after configured smoke test" >&2
        cat "$LOG" >&2
        exit 1
      fi
      if ! wait "$app_pid"; then
        echo "GSDE exited non-zero after configured smoke test" >&2
        cat "$STDERR_LOG" >&2 || true
        exit 1
      fi
      echo "Configured mosaic smoke test passed: $created_count browser(s) created and $loaded_browser_count browser(s) loaded from $CONFIG"
      cat "$STDERR_LOG"
      cat "$LOG"
      exit 0
    fi
  fi

  if ! kill -0 "$app_pid" >/dev/null 2>&1; then
    echo "GSDE exited before configured smoke test completed" >&2
    cat "$STDERR_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

echo "Configured smoke test timed out after ${WAIT_SECONDS}s" >&2
[[ -f "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2
[[ -f "$LOG" ]] && cat "$LOG" >&2
exit 1
