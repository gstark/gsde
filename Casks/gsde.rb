cask "gsde" do
  version "0.1.12"
  sha256 "6c4a26dc6ce5d1ff8fa739bf0300562715a1117c6803c83fe623c032309aa0f2"

  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  name "GSDE"
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"

  depends_on macos: ">= :ventura"

  app "GSDE.app"
  binary "GSDE.app/Contents/Resources/bin/gsde"
end
