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
startup_layout = "dev"
layout_flash_enabled = true
layout_flash_duration = 1.4
```

- `version` is required and must currently be `1`.
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
```

Supported pane kinds:

- `terminal`: native Ghostty terminal host. Terminal panes must not set `url` or `profile`.
- `browser`: Chromium/CEF browser pane. Browser panes must set an absolute `url` with a scheme such as `https://` or `http://`.

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

Browser profiles are persisted under `~/Library/Application Support/GSDE/Chromium/Profiles`. When `profile` is omitted, GSDE uses the pane `id` as the stable profile name. Set `profile` when several layouts should share browser state under a shorter or more explicit name.

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
- `docs/sample-configs/multiple-named-layouts.toml`: more than one validated layout, with `startup_layout` selecting the one opened initially. Use **Workspace → Switch Layout…**, `Ctrl-Option-Command-L`, `Globe-L`, or `F13` then `L` to open the layout switcher. Arrow keys or `j`/`k` move through the list, Return activates the selected layout, and Escape closes without changing. Use `Ctrl-Option-Command-Left`/`Right`, `Globe-Left`/`Right`, or `F13` then `Left`/`Right` to switch directly to the previous or next layout. Remap Caps Lock to Globe in System Settings or to F13 at the key-remapping layer to use the physical Caps Lock key as GSDE's layout meta key.

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
