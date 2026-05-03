#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_REPO_URL="${GHOSTTY_REPO_URL:-https://github.com/ghostty-org/ghostty.git}"
GHOSTTY_REF="${GHOSTTY_REF:-main}"
GHOSTTY_DIR="${GHOSTTY_DIR:-$ROOT_DIR/external/ghostty}"
OUT_DIR="$ROOT_DIR/build/libghostty"
ZIG="${ZIG:-}"

if [[ -z "$ZIG" ]]; then
  if [[ -x /opt/homebrew/opt/zig@0.15/bin/zig ]]; then
    ZIG=/opt/homebrew/opt/zig@0.15/bin/zig
  elif command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == 0.15.* ]]; then
    ZIG="$(command -v zig)"
  else
    echo "error: Ghostty currently requires Zig 0.15.x." >&2
    echo "Install it with: brew install zig@0.15" >&2
    echo "Or set ZIG=/path/to/zig-0.15.x" >&2
    exit 1
  fi
fi

if ! xcrun -sdk macosx metal -v >/dev/null 2>&1; then
  echo "error: Xcode's Metal Toolchain is not installed or not runnable." >&2
  echo "Ghostty's full embeddable library needs Metal shader compilation." >&2
  echo "Try: xcodebuild -downloadComponent MetalToolchain" >&2
  echo "If that fails, run: xcodebuild -runFirstLaunch" >&2
  exit 1
fi

if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
  mkdir -p "$(dirname "$GHOSTTY_DIR")"
  git clone "$GHOSTTY_REPO_URL" "$GHOSTTY_DIR"
fi

cd "$GHOSTTY_DIR"
git fetch --depth 1 origin "$GHOSTTY_REF"
git checkout FETCH_HEAD

python3 - <<'PY'
from pathlib import Path

build_zig = Path('build.zig')
s = build_zig.read_text()
old = '''        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty-internal.dll");
                lib_static.install("ghostty-internal-static.lib");
            } else {
                lib_shared.install("ghostty-internal.so");
                lib_static.install("ghostty-internal.a");
            }
        }'''
new = '''        lib_shared.installHeader(); // Only need one header
        if (config.target.result.os.tag == .windows) {
            lib_shared.install("ghostty-internal.dll");
            lib_static.install("ghostty-internal-static.lib");
        } else if (config.target.result.os.tag.isDarwin()) {
            lib_shared.install("libghostty.dylib");
            lib_static.install("ghostty-internal.a");
        } else {
            lib_shared.install("ghostty-internal.so");
            lib_static.install("ghostty-internal.a");
        }'''
if old in s:
    build_zig.write_text(s.replace(old, new))
elif 'lib_shared.install("libghostty.dylib");' not in s:
    raise SystemExit('error: build.zig layout changed; could not patch libghostty install step')

shared_deps = Path('src/build/SharedDeps.zig')
s = shared_deps.read_text()
old = '''        if (self.config.renderer == .opengl) {
            step.linkFramework("OpenGL");
        }
'''
new = '''        if (self.config.renderer == .opengl) {
            step.linkFramework("OpenGL");
        }
        if (target.result.os.tag.isDarwin()) {
            step.linkFramework("Metal");
        }
'''
if old in s and 'step.linkFramework("Metal");' not in s:
    shared_deps.write_text(s.replace(old, new))
elif 'step.linkFramework("Metal");' not in s:
    raise SystemExit('error: SharedDeps.zig layout changed; could not patch Metal framework link')
PY

"$ZIG" build \
  -Dapp-runtime=none \
  -Demit-macos-app=false \
  -Demit-xcframework=false \
  -Demit-docs=false \
  -Demit-lib-vt=false \
  -Doptimize=ReleaseFast

mkdir -p "$OUT_DIR"
cp zig-out/lib/libghostty.dylib "$OUT_DIR/libghostty.dylib"
cp include/ghostty.h "$OUT_DIR/ghostty.h"

install_name_tool -id "@rpath/libghostty.dylib" "$OUT_DIR/libghostty.dylib" || true

echo "Built $OUT_DIR/libghostty.dylib"
