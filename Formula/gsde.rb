class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.8"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "72113a809e49f2c4b5a49bad14ba98c0e0063aeff854b8f8a9789c8f06a5a04a"

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
      exec "#{prefix}/GSDE.app/Contents/Resources/bin/gsde" "$@"
    SH
  end

  test do
    assert_match "Usage: gsde", shell_output("#{bin}/gsde --help")
  end
end
