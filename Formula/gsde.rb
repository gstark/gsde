class Gsde < Formula
  desc "Full-screen macOS development environment with terminal and browser panes"
  homepage "https://github.com/gstark/gsde"
  version "0.1.4"
  url "https://github.com/gstark/gsde/releases/download/v#{version}/GSDE-#{version}.zip"
  sha256 "4bb126428c3f7ec80524bd7bd6915cf8ce2d61e44aca0c615dafedaa6665d4bf"

  depends_on macos: :ventura

  def install
    app = if File.directory?("GSDE.app")
      "GSDE.app"
    else
      "build/GSDE.app"
    end
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
