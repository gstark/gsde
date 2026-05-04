cask "gsde" do
  version "0.1.13"
  sha256 "7dc1eb5dda55c3c9fdf840c766547b73aaac0074c64bfa4a6d5a60a70aeeeb27"

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
