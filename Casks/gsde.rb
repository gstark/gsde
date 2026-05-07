cask "gsde" do
  version "0.1.16"
  sha256 "5af815c0740a362a5dcd96d8a8690a6cd7a5f969e76b007500a71eb418499d92"

  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  name "GSDE"
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"

  depends_on macos: ">= :ventura"

  app "GSDE.app"
  binary "GSDE.app/Contents/Resources/bin/gsde"

  caveats <<~EOS
    If you installed the earlier formula-based GSDE package, remove it first:
      brew uninstall --formula gsde 2>/dev/null || true
      rm -f "/opt/homebrew/bin/gsde"
  EOS
end
