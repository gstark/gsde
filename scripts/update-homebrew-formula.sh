#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/update-homebrew-formula.sh VERSION RELEASE_ZIP GITHUB_REPOSITORY

Example:
  scripts/update-homebrew-formula.sh 0.1.0 dist/GSDE-0.1.0.zip gstark/gsde

Updates Casks/gsde.rb to install the given GitHub release archive.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 64
fi

VERSION="$1"
ARCHIVE="$2"
REPOSITORY="$3"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Missing release archive: $ARCHIVE" >&2
  exit 66
fi

if [[ ! "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
  echo "GITHUB_REPOSITORY must look like owner/repo" >&2
  exit 64
fi

SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
OWNER=${REPOSITORY%%/*}
REPO=${REPOSITORY#*/}

mkdir -p Casks
rm -f Formula/gsde.rb

cat > Casks/gsde.rb <<RUBY
cask "gsde" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${OWNER}/${REPO}/releases/download/v#{version}/GSDE-#{version}.zip"
  name "GSDE"
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/${OWNER}/${REPO}"

  depends_on macos: ">= :ventura"

  app "GSDE.app"
  binary "GSDE.app/Contents/Resources/bin/gsde"
end
RUBY

echo "Updated Casks/gsde.rb for ${REPOSITORY} v${VERSION} (${SHA256})"
