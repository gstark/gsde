class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.7"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "41e5d2734a909ed0fba5cc8f8a0063370a23dd9214cf6b8b9b09e841b7141897"

  depends_on macos: :ventura

  def install
    if File.directory?("Contents") && File.file?("Contents/Info.plist")
      prefix.install buildpath => "GSDE.app"
    else
      app = Dir["GSDE.app", "**/GSDE.app"].first
      odie "GSDE.app not found in release archive" if app.nil?
      prefix.install app
    end

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
