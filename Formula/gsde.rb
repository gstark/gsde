class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.5"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "50f0d2bbbc816f929c15afa3ecb63acdafb86314f2985d212fb9de5f1e508b2a"

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
