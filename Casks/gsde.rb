cask "gsde" do
  version "0.1.15"
  sha256 "d21ee0ec819bf21a4bd1dd0796a60ad7f60eebe1ec0905f92a105fa0c7a0eb2f"

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
