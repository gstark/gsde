# GSDE

A personal native macOS app built with Swift and AppKit, without opening Xcode.

## Build

Build the app shell:

```sh
make app
# optional version overrides:
APP_VERSION=0.2.0 APP_BUILD=42 make app
```

The app icon is generated at `Resources/GSDEIcon.icns`; regenerate it with:

```sh
./scripts/generate-app-icon.sh
```

Build Ghostty's embeddable dylib and include it in the app bundle:

```sh
make app-with-ghostty
```

This creates:

```text
build/GSDE.app
```

## Run

```sh
make run
```

Or run in the foreground from the terminal:

```sh
make run-foreground
```

## Chromium/CEF preparation

Fetch the macOS arm64 CEF distribution:

```sh
make cef
```

This places CEF under `external/cef`. See `docs/chromium-cef-integration.md` for the bridge and packaging plan. CEF is the default browser backend:

```sh
make run-cef
```

To test multiple Chromium browser instances in one window:

```sh
make run-cef-two-browsers
make run-cef-four-browsers
# or
GSDE_BROWSER_PANES=2 make run-cef
# foreground:
GSDE_BROWSER_PANES=2 make run-cef-foreground
```

GSDE loads workspace startup configuration from `GSDE_CONFIG`, then a project-local `.config/gsde/config.toml` when launched via the `gsde` CLI, then `~/.config/gsde/config.toml`, then the built-in default. Invalid config files do not crash launch; GSDE reports diagnostics on stderr and uses the built-in layout. See [`docs/workspace-config.md`](docs/workspace-config.md) for the TOML format, lookup order, area-grid validation rules, and copyable samples including terminal-only `12/33`, browser+terminal development, and multiple named layouts.

The packaged app includes a VS Code-style command shim at `GSDE.app/Contents/Resources/bin/gsde`. Symlink or copy it onto your `PATH`, then run `gsde` from a project directory to launch GSDE with that project's `.config/gsde/config.toml`. Run `gsde --validate` from a project directory to validate the resolved workspace config without launching the app.

Configured terminal panes can declare a startup `command` or a named `process` from a `procfile` resolved relative to the project directory launched with `gsde`. Configured browser panes get persistent Chromium profile directories under `~/Library/Application Support/GSDE/Chromium/Profiles`; the profile name defaults to the pane ID unless `profile` is set. `GSDE_BROWSER_PANES` accepts 1-4 browser panes for smoke-test overrides. Initial browser URLs can be overridden with comma-separated `GSDE_BROWSER_URLS`:

```sh
GSDE_BROWSER_PANES=2 \
GSDE_BROWSER_URLS="https://example.com,https://www.wikipedia.org" \
make run-cef-foreground
```

`make app-with-chromium` packages the CEF framework and the required macOS helper app variants (`GSDE Helper`, `GSDE Helper (Renderer)`, `GSDE Helper (GPU)`, etc.) under `GSDE.app/Contents/Frameworks`.

Run CLI smoke tests that launch the app, wait for browser creation and successful page loads, then shut it down:

```sh
make smoke-default       # default launch; verifies CEF loads without opt-in flags
make smoke-cef           # two browser panes
make smoke-cef-custom-urls # verifies configured per-pane URLs load
make smoke-cef-four      # four browser panes
make smoke-cef-graceful  # two panes plus graceful browser close/shutdown and no lingering helpers
make smoke-cef-repeat    # repeated graceful launch/shutdown
make verify-cef-bundle   # bundled CEF framework/helper app packaging checks
make verify-cef          # CEF bundle checks plus all CEF smoke tests
make verify              # default smoke plus all CEF verification
```

Create a distributable zip archive under `dist/`. Release archives should include libghostty, so build it first:

```sh
make libghostty release        # unsigned archive
make libghostty release-adhoc  # ad-hoc codesign before archiving
```

## Homebrew tap setup

This repository is structured so it can also act as a Homebrew tap. GSDE is distributed as a cask because the release archive is a macOS `.app` bundle with embedded frameworks. After publishing a GitHub release archive, update the cask and push it:

```sh
scripts/update-homebrew-formula.sh 0.1.0 dist/GSDE-0.1.0.zip OWNER/gsde
git add Casks/gsde.rb && git commit -m "Update Homebrew cask for v0.1.0"
```

Install from the tap with:

```sh
brew tap OWNER/gsde https://github.com/OWNER/gsde.git
brew install --cask gsde
```

If you installed an earlier formula-based GSDE package, remove it before installing the cask so the `gsde` CLI symlink points at the cask app:

```sh
brew uninstall --formula gsde 2>/dev/null || true
rm -f "$(brew --prefix)/bin/gsde"
brew reinstall --cask gsde
```

The cask installs `GSDE.app` and exposes the `gsde` CLI on `PATH`.


Developer ID signing and notarization helpers are available without opening Xcode:

```sh
GSDE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make sign-release
GSDE_NOTARY_PROFILE="notarytool-profile" GSDE_RELEASE_ARCHIVE=dist/GSDE-...zip make notarize-release

# one-command variants:
GSDE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release-signed
GSDE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" GSDE_NOTARY_PROFILE="notarytool-profile" make release-notarized
```

`make sign-release` uses `GSDE.entitlements` by default, which enables the hardened-runtime allowances Chromium/CEF commonly needs for JIT, executable memory, and bundled framework loading. Override with `GSDE_ENTITLEMENTS=/path/to/file.entitlements` if needed.

Reset saved app state and Chromium profile data:

```sh
make reset-state
```

CEF diagnostics are written to:

```text
/tmp/gsde_chromium.log
~/Library/Application Support/GSDE/Chromium/chrome_debug.log
```

## libghostty hosting

The main window is now a native `NSView` host for Ghostty's embeddable library.
At runtime the app looks for `libghostty.dylib` in:

1. `LIBGHOSTTY_PATH`
2. `GSDE.app/Contents/Frameworks/libghostty.dylib`
3. system library paths such as `/opt/homebrew/lib`

To build and bundle Ghostty automatically:

```sh
make app-with-ghostty
```

This clones Ghostty into `external/ghostty`, builds `build/libghostty/libghostty.dylib`, and copies it into `build/GSDE.app/Contents/Frameworks/libghostty.dylib`.

Requirements for building Ghostty:

- Zig 0.15.x. Homebrew install: `brew install zig@0.15`
- Xcode Metal Toolchain. Install: `xcodebuild -downloadComponent MetalToolchain`

If you already have a locally built `libghostty.dylib`, bundle it while building:

```sh
LIBGHOSTTY_PATH=/path/to/libghostty.dylib make app
```

Then run:

```sh
make run
```

Run the Chromium/CEF browser backend:

```sh
make run-cef
```

CEF is the browser backend by default. If CEF is not bundled, the browser pane shows a status message explaining what is missing.

The shim vendors Ghostty's public C header in `Sources/GhosttyShim/include/ghostty.h`; see `THIRD_PARTY_NOTICES.md`.

## Current behavior

On first launch, the app opens one native macOS window sized to the union of all connected display frames. Subsequent launches restore the saved window frame, split-pane divider positions, and last browser URLs. Use **GSDE → Reset Window and Pane Layout** to clear saved layout/browser URL state and maximize across all displays again. The content area is split into resizable panes with an accent border around the active pane: terminal, browser(s), terminal. The Workspace menu can add browser panes, add terminal panes after the active pane, duplicate the active browser pane, close the active pane, close all other panes, cycle pane focus, switch configured mosaic layouts with Ctrl-Option-Command-L or step through them with Ctrl-Option-Command-Left/Right with a configurable layout-name flash, move the active pane left/right, and reset window/pane layout. Runtime pane additions/removals are persisted with a versioned workspace layout and restored on later launches unless launch-time pane environment overrides are provided. Abandoned dynamic browser profiles are cleaned up on launch when they are no longer referenced by the saved workspace.

The Terminal menu provides copy/paste for the active Ghostty pane, Ghostty clipboard callbacks are bridged to macOS `pbpaste`/`pbcopy` for terminal-initiated clipboard operations, and terminal panes forward mouse movement, clicks, drags, scroll events, title changes, mouse shape/visibility state, and basic IME marked/committed text and IME candidate positioning to libghostty. The browser pane uses Chromium/CEF directly and provides URL entry, back/forward/reload/stop, in-page find with match count status, page zoom, printing, basic download handling with status display, deterministic permission/auth/certificate cancellation with status logging, same-pane popup handling, copy/open current URL actions, a safe native browser context menu with editing actions, persistent website data, and developer tools entry points. These actions are available from the Browser menu. Browser shortcuts include Cmd-L for the URL bar, Cmd-F find, Cmd-G / Cmd-Shift-G find next/previous, Cmd-R reload, Cmd-Shift-R reload ignoring cache, Cmd-. stop loading, Cmd-[ back, Cmd-] forward, Cmd-X/C/V/A editing commands, Cmd-+ / Cmd-- / Cmd-0 zoom, Cmd-P print, Cmd-Option-U view source, and Cmd-Option-I DevTools. The dynamically loaded CEF/Chromium backend initializes on normal app launch, creates native browser views, starts renderer helpers, and loads the initial pages.
