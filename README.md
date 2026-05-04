# GSDE

A personal native macOS app built with Swift and AppKit, without opening Xcode.

## Build

Build the app shell:

```sh
make app
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
# or
GSDE_BROWSER_PANES=2 make run-cef-foreground
```

`GSDE_BROWSER_PANES` accepts 1-4 browser panes. Initial browser URLs can be overridden with comma-separated `GSDE_BROWSER_URLS`:

```sh
GSDE_BROWSER_PANES=2 \
GSDE_BROWSER_URLS="https://example.com,https://www.wikipedia.org" \
make run-cef-foreground
```

`make app-with-chromium` packages the CEF framework and the required macOS helper app variants (`GSDE Helper`, `GSDE Helper (Renderer)`, `GSDE Helper (GPU)`, etc.) under `GSDE.app/Contents/Frameworks`.

Run a CLI smoke test that launches the app, waits for CEF browser creation and successful page loads, then shuts it down:

```sh
make smoke-cef
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

On launch, the app opens one native macOS window sized to the union of all connected display frames. The content area is split into three equal-width vertical panes: terminal, browser, terminal.

The browser pane currently provides URL entry, back/forward/reload, standard context menus, persistent website data, and developer tools entry points. Browser shortcuts include Cmd-L for the URL bar, Cmd-R reload, Cmd-Shift-R reload ignoring cache, Cmd-[ back, Cmd-] forward, and Cmd-Option-I DevTools. By default it uses the WebKit fallback so normal app launch stays stable. The dynamically loaded CEF/Chromium backend is available behind `GSDE_ENABLE_CEF=1` / `make run-cef`; it initializes CEF, creates a native browser view, starts renderer helpers, and loads the initial page.
