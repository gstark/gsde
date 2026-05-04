#!/usr/bin/env bash
set -euo pipefail

VERSION="${GSDE_CODE_SERVER_VERSION:-4.103.2}"
DEST_DIR="${GSDE_CODE_SERVER_DIR:-external/code-server}"
CACHE_DIR="${GSDE_CACHE_DIR:-build/cache}"

case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="amd64" ;;
  *) echo "Unsupported code-server architecture: $(uname -m)" >&2; exit 2 ;;
esac

TARBALL="code-server-${VERSION}-macos-${ARCH}.tar.gz"
URL="https://github.com/coder/code-server/releases/download/v${VERSION}/${TARBALL}"
ARCHIVE_PATH="${CACHE_DIR}/${TARBALL}"
EXTRACT_DIR="${CACHE_DIR}/code-server-${VERSION}-macos-${ARCH}"

if [[ -x "${DEST_DIR}/bin/code-server" ]]; then
  echo "code-server already available at ${DEST_DIR}/bin/code-server"
  exit 0
fi

mkdir -p "${CACHE_DIR}"
if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Downloading ${URL}"
  curl --fail --location --show-error --output "${ARCHIVE_PATH}" "${URL}"
fi

rm -rf "${EXTRACT_DIR}" "${DEST_DIR}"
tar -xzf "${ARCHIVE_PATH}" -C "${CACHE_DIR}"
if [[ ! -x "${EXTRACT_DIR}/bin/code-server" ]]; then
  echo "Downloaded archive does not contain executable bin/code-server" >&2
  exit 1
fi
mkdir -p "$(dirname "${DEST_DIR}")"
ditto "${EXTRACT_DIR}" "${DEST_DIR}"
chmod +x "${DEST_DIR}/bin/code-server"
echo "code-server ${VERSION} installed at ${DEST_DIR}"
