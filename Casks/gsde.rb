cask "gsde" do
  version "0.1.11"
  sha256 "84b5210a857db793cb7d343257d0030144b4c11c01909958b0307fdb5826abbe"

  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  name "GSDE"
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"

  depends_on macos: ">= :ventura"

  app "GSDE.app"
  binary "GSDE.app/Contents/Resources/bin/gsde"
end
