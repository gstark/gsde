class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.6"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "c00d04a2e11c45be2aaeaf7c314711856d163ae540cc7ee9ef7231ed7e538b91"

  depends_on macos: :ventura

  def install
    app = Dir["GSDE.app", "**/GSDE.app"].first
    odie "GSDE.app not found in release archive" if app.nil?
    prefix.install app

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
