class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.7"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "d2c9021a3ef8cecf29d221404b983fc7062ed2b3d621e870e6fbc56a76c0c1dd"

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
