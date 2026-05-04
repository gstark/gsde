class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/OWNER/gsde"
  version "0.1.0"
  url "https://github.com/OWNER/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  depends_on macos: :ventura

  def install
    prefix.install "GSDE.app"

    (bin/"gsde").write <<~SH
      #!/bin/sh
      export GSDE_APP_PATH="#{prefix}/GSDE.app"
      exec "#{prefix}/GSDE.app/Contents/Resources/bin/gsde" "$@"
    SH
  end

  test do
    assert_match "Usage: gsde", shell_output("#{bin}/gsde --help")
  end
end
