class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.5"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "fce1ff0f8cb26eeb28fc9113ca9a200dfc2964f1ca415c548be67560fe4c80f6"

  depends_on macos: :ventura

  def install
    app = Dir["**/GSDE.app"].first
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
