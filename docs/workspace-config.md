# Workspace configuration

GSDE workspace configuration is a small TOML file that declares panes and named mosaic layouts. For project-specific configuration, place the file at `.config/gsde/config.toml` in the project directory and launch with the `gsde` command:

```sh
gsde
# or from elsewhere:
gsde /path/to/project
```

You can also launch with an explicit config path using `GSDE_CONFIG`:

```sh
GSDE_CONFIG="$PWD/docs/sample-configs/browser-terminal-dev.toml" make run-cef-foreground
```

Validate the resolved configuration without launching the app:

```sh
gsde --validate
# or validate a specific project directory
gsde --validate /path/to/project
```

## Lookup order

GSDE loads the first available configuration in this order:

1. `GSDE_CONFIG` when the environment variable is set to a non-empty path. `~` is expanded.
2. `$GSDE_PROJECT_DIR/.config/gsde/config.toml` when `GSDE_PROJECT_DIR` is set by the `gsde` command and the file exists.
3. `~/.config/gsde/config.toml` when that file exists.
4. The built-in default layout.

If a file is found but invalid, GSDE reports a diagnostic on stderr and uses the built-in default. It does not try later locations because an explicit or discovered config with errors should be fixed, not silently skipped.

## Format version and startup layout

```toml
version = 1
title = "Dashboard"
startup_layout = "dev"
layout_flash_enabled = true
layout_flash_duration = 1.4
```

- `version` is required and must currently be `1`.
- `title` is optional. When present, GSDE uses it for the window title and Dock/App Switcher badge.
- `startup_layout` is required and must match one `[[layouts]]` `id`.
- `layout_flash_enabled` is optional and defaults to `true`. When enabled, direct previous/next layout switching briefly flashes the new layout name centered on every screen.
- `layout_flash_duration` is optional and defaults to `1.4` seconds.
- Unknown keys are rejected so typos fail fast.

## Panes

Declare each pane with a `[[panes]]` table:

```toml
[[panes]]
id = "terminal.main"
kind = "terminal"

[[panes]]
id = "browser.app"
kind = "browser"
url = "http://localhost:5173"
profile = "dev-app"

[[panes]]
id = "editor"
kind = "vscode"
```

Supported pane kinds:

- `terminal`: native Ghostty terminal host. Terminal panes must not set `url` or `profile`.
- `browser`: Chromium/CEF browser pane. Browser panes must set an absolute `url` with a scheme such as `https://` or `http://`.
- `vscode`: VS Code editor pane. VS Code panes do not require `url`, `command`, `procfile`, or `process`, and must not set browser-only fields (`url`, `profile`) or terminal-only fields (`command`, `procfile`, `process`).

Terminal panes can optionally run a startup command. Use `command` for a direct command line:

```toml
[[panes]]
id = "terminal.agent"
kind = "terminal"
command = "claude"
```

Or use `procfile` plus `process` to run a named Procfile entry:

```toml
[[panes]]
id = "terminal.web"
kind = "terminal"
procfile = "Procfile.dev"
process = "web"
```

Startup commands run from the project directory. Procfile paths are resolved relative to `GSDE_PROJECT_DIR`, i.e. the project directory passed to or inferred by the `gsde` launcher. For example, `process = "web"` with this `Procfile.dev` line runs `npm run dev` in the terminal:

```text
web: npm run dev
```

`command` cannot be combined with `procfile`/`process`, and `procfile`/`process` must be provided together.

Browser storage is persisted beside the resolved config file using CEF's global browser profile. For project configs, all browser panes share `.config/gsde/chromium/Default` in the project directory. For an explicit `GSDE_CONFIG=/path/to/config.toml`, the shared profile is `/path/to/chromium/Default`. GSDE creates the needed directories automatically. Built-in fallback launches use `~/Library/Application Support/GSDE/Chromium`. The `profile` field is currently accepted for config compatibility, but configured browser panes intentionally share one project profile.

Each configured `vscode` pane is isolated by pane ID. GSDE launches a separate code-server lifecycle with its own random port, user data directory, extensions directory, and CEF browser profile under `chromium/vscode-panes/<pane-id>`.

Panes can optionally define CSS-style pixel border and padding shorthands. Defaults can be set by pane kind and overridden per pane:

```toml
[[pane_defaults.terminal]]
border = "0 1"
padding = "8 12"

[[pane_defaults.vscode]]
border = "1"
padding = "0"

[[panes]]
id = "terminal.main"
kind = "terminal"
border = "0 0 0 1"
padding = "4"
```

`border` and `padding` accept one to four non-negative pixel values, with optional `px` suffixes, using CSS shorthand expansion: one value applies to all sides, two are vertical/horizontal, three are top/horizontal/bottom, and four are top/right/bottom/left. Defaults are `0`. Pane borders are drawn between layout cells and visually collapse with adjacent pane borders; padding is always applied inside the border and does not collapse.

Pane IDs must be unique. They are also the tokens used in layout areas, so choose IDs without whitespace.

## Layout area syntax

Declare each named layout with a `[[layouts]]` table:

```toml
[[layouts]]
id = "dev"
areas = [
    "terminal.editor browser.app",
    "terminal.logs   browser.app",
]
```

`areas` is an array of strings. Each string is one row in an equal-sized grid. Split a row by whitespace to get columns. Repeating the same pane token across adjacent cells makes that pane span those cells.

Examples:

- `docs/sample-configs/terminal-12-33.toml`: terminal-only `12/33` layout:

  ```text
  1 2
  3 3
  ```

- `docs/sample-configs/browser-terminal-dev.toml`: terminals on the left, one browser spanning the full right column.
- `docs/sample-configs/vscode-terminal-dev.toml`: VS Code editor pane beside a terminal.
- `docs/sample-configs/multiple-named-layouts.toml`: more than one validated layout, with `startup_layout` selecting the one opened initially. Use **Workspace → Switch Layout…** or `Shift-Ctrl-Option-Command-L` to open the layout switcher. Arrow keys or `j`/`k` move through the list, Return activates the selected layout, and Escape closes without changing. Use `Shift-Ctrl-Option-Command-Left`/`Right` to switch directly to the previous or next layout.

## Validation rules

GSDE validates every declared layout before using the config:

- `areas` must contain at least one row.
- Every row must contain at least one pane token.
- Every row must have the same number of columns.
- Every token must reference a declared pane ID.
- Pane IDs and layout IDs must be unique.
- Each pane's cells must form one filled rectangle.

The rectangular-area rule is why L-shaped layouts are rejected. For this invalid grid:

```text
a a
a b
```

pane `a` has a 2x2 bounding box but does not occupy the bottom-right cell, so its area is L-shaped rather than rectangular. GSDE rejects it with a diagnostic like `pane a areas are not a single rectangle`. Use another pane for the missing cell, or change the grid so each repeated token fills its complete rectangle.
