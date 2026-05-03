# GSDE

A personal native macOS app built with Swift and AppKit, without opening Xcode.

## Build

```sh
make app
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

## Current behavior

On launch, the app opens one native macOS window sized to the union of all connected display frames and shows `Hello world` centered in the window.
