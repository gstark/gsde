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

This places CEF under `external/cef`. See `docs/chromium-cef-integration.md` for the bridge and packaging plan. The CEF backend is opt-in while it is being hardened:

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

`GSDE_BROWSER_PANES` accepts 1-4 browser panes. Each browser pane gets its own persistent Chromium profile directory under `~/Library/Application Support/GSDE/Chromium/Profiles`. Initial browser URLs can be overridden with comma-separated `GSDE_BROWSER_URLS`:

```sh
GSDE_BROWSER_PANES=2 \
GSDE_BROWSER_URLS="https://example.com,https://www.wikipedia.org" \
make run-cef-foreground
```

`make app-with-chromium` packages the CEF framework and the required macOS helper app variants (`GSDE Helper`, `GSDE Helper (Renderer)`, `GSDE Helper (GPU)`, etc.) under `GSDE.app/Contents/Frameworks`.

Run CLI smoke tests that launch the app, wait for browser creation and successful page loads, then shut it down:

```sh
make smoke-default       # default WebKit launch; verifies CEF stays off
make smoke-cef           # two browser panes
make smoke-cef-custom-urls # verifies configured per-pane URLs load
make smoke-cef-four      # four browser panes
make smoke-cef-graceful  # two panes plus graceful browser close/shutdown and no lingering helpers
make smoke-cef-repeat    # repeated graceful launch/shutdown
make verify-cef-bundle   # bundled CEF framework/helper app packaging checks
make verify-cef          # CEF bundle checks plus all CEF smoke tests
make verify              # default smoke plus all CEF verification
```

Create a distributable zip archive under `dist/`:

```sh
make release        # unsigned archive
make release-adhoc  # ad-hoc codesign before archiving
```

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

To run the experimental CEF backend instead of the default WebKit browser fallback:

```sh
make run-cef
```

If the dylib is not present, the window opens with a centered status message explaining where the app looked.

The shim vendors Ghostty's public C header in `Sources/GhosttyShim/include/ghostty.h`; see `THIRD_PARTY_NOTICES.md`.

## Current behavior

On first launch, the app opens one native macOS window sized to the union of all connected display frames. Subsequent launches restore the saved window frame, split-pane divider positions, and last browser URLs. Use **GSDE → Reset Window and Pane Layout** to clear saved layout/browser URL state and maximize across all displays again. The content area is split into resizable panes with an accent border around the active pane: terminal, browser(s), terminal. The Workspace menu can add browser panes, add terminal panes after the active pane, duplicate the active browser pane, close the active pane, close all other panes, cycle pane focus, move the active pane left/right, and reset window/pane layout. Runtime pane additions/removals are persisted with a versioned workspace layout and restored on later launches unless launch-time pane environment overrides are provided. Abandoned dynamic browser profiles are cleaned up on launch when they are no longer referenced by the saved workspace.

The Terminal menu provides copy/paste for the active Ghostty pane, and terminal panes forward mouse movement, clicks, drags, scroll events, and basic IME marked/committed text and IME candidate positioning to libghostty. The browser pane currently provides URL entry, back/forward/reload/stop, in-page find with match count status, page zoom, printing, basic download handling with status display, deterministic permission/auth/certificate cancellation with status logging, same-pane popup handling, copy/open current URL actions, a safe native browser context menu with editing actions, persistent website data, and developer tools entry points. These actions are available from the Browser menu. Browser shortcuts include Cmd-L for the URL bar, Cmd-F find, Cmd-G / Cmd-Shift-G find next/previous, Cmd-R reload, Cmd-Shift-R reload ignoring cache, Cmd-. stop loading, Cmd-[ back, Cmd-] forward, Cmd-X/C/V/A editing commands, Cmd-+ / Cmd-- / Cmd-0 zoom, Cmd-P print, Cmd-Option-U view source, and Cmd-Option-I DevTools. By default it uses the WebKit fallback so normal app launch stays stable. The dynamically loaded CEF/Chromium backend is available behind `GSDE_ENABLE_CEF=1` / `make run-cef`; it initializes CEF, creates a native browser view, starts renderer helpers, and loads the initial page.
