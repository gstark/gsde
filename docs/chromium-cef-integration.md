# Chromium / CEF integration plan

CEF is the intended backend for real Chromium panes. The current `BrowserPaneView` is intentionally isolated behind a native AppKit pane so the layout, URL bar, navigation controls, and multi-pane behavior can be developed before the CEF bridge replaces the WebKit implementation.

## Fetch CEF

```sh
make cef
```

This downloads the arm64 macOS CEF minimal distribution into:

```text
external/cef
```

The downloaded distribution includes:

```text
external/cef/Release/Chromium Embedded Framework.framework
external/cef/include
external/cef/libcef_dll
```

## Current repository support

The app now has a `ChromiumStub` target that the Swift browser pane can call without linking CEF yet. `make app` copies `external/cef/Release/Chromium Embedded Framework.framework` into `GSDE.app/Contents/Frameworks` when CEF has been fetched.

This means packaging can be tested independently while the real Objective-C++ CEF bridge is added.

## Desired CEF bridge

Swift should not talk to CEF C++ directly. We should add a small Objective-C++/C bridge with this shape:

```c
bool gsde_cef_initialize(const char *root_cache_path, const char *subprocess_path);
void gsde_cef_shutdown(void);

gsde_cef_browser_t *gsde_cef_browser_create(
    void *parent_nsview,
    const char *initial_url,
    const char *cache_path
);

void gsde_cef_browser_destroy(gsde_cef_browser_t *browser);
void gsde_cef_browser_resize(gsde_cef_browser_t *browser, int width, int height);
void gsde_cef_browser_load_url(gsde_cef_browser_t *browser, const char *url);
void gsde_cef_browser_go_back(gsde_cef_browser_t *browser);
void gsde_cef_browser_go_forward(gsde_cef_browser_t *browser);
void gsde_cef_browser_reload(gsde_cef_browser_t *browser);
void gsde_cef_browser_show_devtools(gsde_cef_browser_t *browser);
```

Each `BrowserPaneView` can then own one `gsde_cef_browser_t` and a per-pane `CefRequestContext`.

## macOS CEF packaging notes

A complete CEF macOS app normally needs more than the framework:

- `Chromium Embedded Framework.framework` in `Contents/Frameworks`
- CEF helper app bundles/executables for renderer/GPU/utility subprocesses
- `CefExecuteProcess` handling for helper process startup
- `CefInitialize` in the browser process
- an explicit persistent cache path via `CefSettings.root_cache_path` and/or `CefRequestContextSettings.cache_path`

The current `make cef` target only fetches CEF. The next implementation step is the Objective-C++ bridge and helper packaging.

## Current browser pane behavior

`BrowserPaneView` currently provides the shell behavior we need:

- URL bar
- Back/forward/reload
- Standard context menu behavior
- Persistent website data
- Multiple pane instances

The class should keep the same Swift API when the backend changes from WebKit to CEF.
