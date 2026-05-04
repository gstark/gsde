cask "gsde" do
  version "0.1.13"
  sha256 "2bda1ac731099892d81b7f3f0510d6d21d326bdd2615f4c2378eaa132383eb2b"

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
