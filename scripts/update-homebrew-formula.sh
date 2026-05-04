#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/update-homebrew-formula.sh VERSION RELEASE_ZIP GITHUB_REPOSITORY

Example:
  scripts/update-homebrew-formula.sh 0.1.0 dist/GSDE-0.1.0.zip gstark/gsde

Updates Formula/gsde.rb to install the given GitHub release archive.
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

cat > Formula/gsde.rb <<RUBY
class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/${OWNER}/${REPO}"
  version "${VERSION}"
  url "https://github.com/${OWNER}/${REPO}/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "${SHA256}"

  depends_on macos: :ventura

  def install
    if File.directory?("Contents") && File.file?("Contents/Info.plist")
      (prefix/"GSDE.app").install "Contents"
    else
      app = Dir["GSDE.app", "**/GSDE.app"].first
      odie "GSDE.app not found in release archive" if app.nil?
      prefix.install app
    end

    (bin/"gsde").write <<~SH
      #!/bin/sh
      export GSDE_APP_PATH="#{prefix}/GSDE.app"
      exec "#{prefix}/GSDE.app/Contents/Resources/bin/gsde" "\$@"
    SH
  end

  test do
    assert_match "Usage: gsde", shell_output("#{bin}/gsde --help")
  end
end
RUBY

echo "Updated Formula/gsde.rb for ${REPOSITORY} v${VERSION} (${SHA256})"
