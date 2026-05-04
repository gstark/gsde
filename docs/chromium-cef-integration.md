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

The app now has a `ChromiumStub` target that dynamically loads CEF at runtime. `make app` copies `external/cef/Release/Chromium Embedded Framework.framework` into `GSDE.app/Contents/Frameworks` when CEF has been fetched.

`make app-with-chromium` also packages the required macOS helper app variants using `scripts/package-cef-helper.sh`:

```text
GSDE Helper.app
GSDE Helper (Alerts).app
GSDE Helper (GPU).app
GSDE Helper (Plugin).app
GSDE Helper (Renderer).app
```

The bridge currently exposes CEF initialization, message loop work, helper process execution, browser creation, native view attachment, navigation, resizing, load/display diagnostics, same-pane popup handling, safe context-menu interception, deterministic permission denial/status logging, basic download handling with status display, edit commands, find with match count status, zoom, print, view source, focus, DevTools entry points, and graceful browser close/shutdown tracking. The CEF backend is opt-in via `GSDE_ENABLE_CEF=1` or `make run-cef`; default app launch uses the WebKit fallback while CEF integration stabilizes.

Current verified CEF paths:

```text
make smoke-cef           # 2 browser panes load HTTP 200
make smoke-cef-four      # 4 browser panes load HTTP 200
make smoke-cef-graceful  # browser panes close and CEF shuts down cleanly
make smoke-cef-repeat    # repeated graceful launch/shutdown
make verify-cef          # all of the above
```

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

`make cef` only fetches CEF. `make app-with-chromium` performs the app-bundle packaging needed for runtime testing.

## Current browser pane behavior

`BrowserPaneView` currently provides the shell behavior we need:

- URL bar
- Back/forward/reload/stop
- Find, zoom, print, DevTools, and popup handling
- Safe native context menu behavior with navigation, URL copy/open, edit, print, source, and DevTools actions
- Persistent website data via per-pane Chromium profiles
- Multiple pane instances

The class should keep the same Swift API when the backend changes from WebKit to CEF.
