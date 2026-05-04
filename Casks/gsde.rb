cask "gsde" do
  version "0.1.14"
  sha256 "4997ba0f5ce2ab89d9dc11d6cce8de4e8518ac74ece37301ea0f0554f68408c4"

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
