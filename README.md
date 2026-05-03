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

This places CEF under `external/cef`. See `docs/chromium-cef-integration.md` for the bridge and packaging plan. The current browser pane is backend-isolated so it can be swapped from WebKit to CEF while preserving the URL bar/navigation/multi-pane shell.

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

If the dylib is not present, the window opens with a centered status message explaining where the app looked.

The shim vendors Ghostty's public C header in `Sources/GhosttyShim/include/ghostty.h`; see `THIRD_PARTY_NOTICES.md`.

## Current behavior

On launch, the app opens one native macOS window sized to the union of all connected display frames. The content area is split into three equal-width vertical panes: terminal, browser, terminal.

The browser pane currently provides URL entry, back/forward/reload, standard context menus, persistent website data, and an inspectable developer-tools-capable web view. It is structured as a replaceable pane backend so multiple browser panes can be created and the implementation can be swapped to CEF/Chromium while preserving the Swift/AppKit shell.
