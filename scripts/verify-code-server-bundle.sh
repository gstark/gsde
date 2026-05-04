#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-build/GSDE.app}"
EXECUTABLE="${APP_BUNDLE}/Contents/Resources/code-server/bin/code-server"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "Missing app bundle: ${APP_BUNDLE}" >&2
  exit 2
fi

if [[ ! -f "${EXECUTABLE}" ]]; then
  echo "Missing bundled code-server executable: ${EXECUTABLE}" >&2
  exit 1
fi

if [[ ! -x "${EXECUTABLE}" ]]; then
  echo "Bundled code-server is not executable: ${EXECUTABLE}" >&2
  exit 1
fi

TEMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TEMP_HOME}"' EXIT
if ! VERSION_OUTPUT="$(HOME="${TEMP_HOME}" XDG_CONFIG_HOME="${TEMP_HOME}/.config" "${EXECUTABLE}" --version 2>&1)"; then
  echo "Bundled code-server failed to report a version" >&2
  printf '%s\n' "${VERSION_OUTPUT}" >&2
  exit 1
fi
VERSION_LINE="$(printf '%s\n' "${VERSION_OUTPUT}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
if [[ -z "${VERSION_LINE}" ]]; then
  echo "Bundled code-server did not report a version" >&2
  printf '%s\n' "${VERSION_OUTPUT}" >&2
  exit 1
fi

echo "Bundled code-server verified: ${VERSION_LINE}"
