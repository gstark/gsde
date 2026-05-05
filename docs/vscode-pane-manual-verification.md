# VS Code pane manual verification

Use this checklist before shipping the first VS Code pane UI/CEF integration. It is intentionally manual because several acceptance criteria depend on native focus, keyboard routing, visual fit, and macOS process cleanup that are not fully covered by Swift unit tests or CEF smoke tests.

## Setup

1. Build a Chromium-enabled app bundle with bundled code-server:

   ```sh
   make app-with-chromium verify-code-server-bundle
   ```

2. Create a temporary project that exercises two isolated VS Code panes:

   ```sh
   tmp_project="$(mktemp -d /tmp/gsde-vscode-manual.XXXXXX)"
   mkdir -p "$tmp_project/.config/gsde"
   cat > "$tmp_project/.config/gsde/config.toml" <<'TOML'
   version = 1
   title = "Two VS Code panes"
   startup_layout = "two-vscode"

   [[panes]]
   id = "editor-left"
   kind = "vscode"

   [[panes]]
   id = "editor-right"
   kind = "vscode"

   [[layouts]]
   id = "two-vscode"
   areas = ["editor-left editor-right"]
   TOML
   ```

3. Validate and launch GSDE through the packaged `gsde` shim from that project so `GSDE_PROJECT_DIR` is set, the project-local config is discovered, and pane state is written under the project-local `.config/gsde` directory:

   ```sh
   (cd "$tmp_project" && /path/to/GSDE.app/Contents/Resources/bin/gsde --validate)
   (cd "$tmp_project" && /path/to/GSDE.app/Contents/Resources/bin/gsde)
   ```

## Acceptance checklist

Record pass/fail, date, GSDE build, macOS version, and notes for each item.

- [ ] `kind = "vscode"` launch: GSDE loads the TOML config without diagnostics, creates both panes, and each pane reaches the VS Code workbench instead of the startup overlay.
- [ ] Full-bleed visual integration: the editor fills the entire pane content area, has no unexpected toolbar/address-bar chrome, has no visible gaps around the CEF view, and resizes cleanly when pane dividers or the window are moved.
- [ ] Focus passthrough: clicking inside each VS Code pane moves keyboard focus into that editor; typing edits the focused editor or VS Code input field.
- [ ] Common shortcut passthrough: VS Code receives common editor shortcuts including `Cmd-P`, `Cmd-Shift-P`, `Cmd-F`, `Cmd-S`, `Cmd-/`, `Cmd-B`, and `Cmd-Backtick` when the pane is focused. GSDE-owned global shortcuts should remain limited to explicitly reserved app/window actions.
- [ ] Extension and settings persistence: install or enable a harmless extension and change a user setting in one pane, quit GSDE, relaunch the same config, and confirm the extension/setting remains present in that pane.
- [ ] Per-pane isolation: with both VS Code panes open, make a visible setting or extension change in only `editor-left`; confirm `editor-right` does not inherit it. Verify the project contains separate state roots under `.config/gsde/panes/editor-left/code-server`, `.config/gsde/panes/editor-right/code-server`, `.config/gsde/chromium/vscode-panes/editor-left`, and `.config/gsde/chromium/vscode-panes/editor-right`.
- [ ] Missing code-server inline failure: temporarily move `GSDE.app/Contents/Resources/code-server/bin/code-server` aside, launch the same config, and confirm the VS Code pane shows an inline error with a retry action instead of crashing GSDE or silently falling back to another editor path. Restore the executable and confirm retry starts the pane.
- [ ] App close cleanup: quit GSDE normally and confirm the main GSDE process, code-server child processes, and CEF helper processes for the workspace exit.
- [ ] Workspace close cleanup: close the GSDE workspace window and confirm the same GSDE-owned code-server and CEF helper processes exit without leaving listeners on the pane ports.

## Completion boundary

The VS Code pane first-version UI/CEF behavior is complete only when every checklist item above has a recorded passing result on a packaged app bundle that includes CEF and code-server. Any unchecked, unrun, or failed item must either be completed or linked to a tracked follow-up issue with the release decision explicitly documented.

## Verification log

| Date | GSDE build | macOS | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-05-04 | 0.1.0 (build 175, git 4da04b9) | 26.4.1 | Partial fail | Agent validated the two-pane config with `gsde --validate`, launched the packaged app, observed two VS Code CEF browsers load `HTTP 200` at local code-server login URLs, and observed separate per-pane state directories. Interactive visual/focus/shortcut/persistence checks were not completed; tracked as GSDE-19. Missing code-server inline failure/retry was not completed; tracked as GSDE-20. Normal quit during the run ended in `Segmentation fault: 11`, so cleanup acceptance is not passing yet; tracked as GSDE-18. |
| 2026-05-04 | 0.1.0 (build 184, git working tree) | 26.4.1 | Partial blocked | Rebuilt packaged CEF/code-server app with `make app-with-chromium verify-code-server-bundle`; `gsde --validate` passed for `/tmp/gsde-vscode-manual.NOYiOh`. Launched through the packaged shim and verified both `editor-left` and `editor-right` started bundled `code-server` listeners, spawned CEF helper/renderer processes, and created separate code-server and CEF state roots at `.config/gsde/panes/{editor-left,editor-right}/code-server` and `.config/gsde/chromium/vscode-panes/{editor-left,editor-right}`. Normal app quit via AppleScript cleaned up the GSDE process, bundled code-server children, CEF helpers, and pane listeners without a segfault in this run. Temporarily moving `GSDE.app/Contents/Resources/code-server/bin/code-server` aside produced no bundled code-server child processes and did not crash GSDE; after restoring the executable and relaunching, both panes started code-server again. The remaining native interactive checks (full-bleed visual fit, click-to-focus typing, VS Code shortcut passthrough, visible settings/extension persistence, per-pane UI isolation, and inline failure/retry UI) could not be completed in this agent environment because `screencapture` failed with `could not create image from display` and System Events accessibility access is not granted (`osascript is not allowed assistive access`). |
| 2026-05-04 | 0.1.0 (build 185, git working tree) | 26.4.1 | Partial blocked | Re-ran packaged-app setup with `make app-with-chromium verify-code-server-bundle`; `gsde --validate` passed for `/tmp/gsde-vscode-manual.3YycNt`. Launched through the packaged shim and verified the app process, two bundled `code-server` listeners on `127.0.0.1:49161` and `127.0.0.1:49162`, CEF GPU/utility/renderer helpers, and separate per-pane state roots under `.config/gsde/panes/{editor-left,editor-right}/code-server` and `.config/gsde/chromium/vscode-panes/{editor-left,editor-right}`. The required visual/focus/shortcut/settings-extension persistence checks remain blocked in this agent environment: `screencapture -x /tmp/gsde19.png` failed with `could not create image from display`, and System Events AX inspection failed with `osascript is not allowed assistive access`. A normal AppleEvent quit could not be sent (`Can’t get application id "personal.gsde"`), so this run used `SIGTERM` cleanup and is not a valid app-close cleanup pass. |
| 2026-05-04 | 0.1.0 (build 186, git working tree) | 26.4.1 | Partial blocked | Rebuilt the packaged CEF/code-server app with `make app-with-chromium verify-code-server-bundle`; `gsde --validate` passed for `/tmp/gsde-vscode-manual.4aihaN`. Launched through the packaged shim and verified the main GSDE process, two bundled `code-server` listeners on `127.0.0.1:49428` and `127.0.0.1:49429`, CEF GPU/utility/renderer helpers, and separate per-pane state roots under `.config/gsde/panes/{editor-left,editor-right}/code-server` and `.config/gsde/chromium/vscode-panes/{editor-left,editor-right}`. Native interactive criteria remain unverified in this agent environment: `screencapture -x /tmp/gsde19.png` still failed with `could not create image from display`, and System Events process enumeration can see `GSDE` but assistive inspection/input remains unavailable. `tell application "GSDE" to quit` did complete this run, and post-quit `pgrep -fl "GSDE|code-server|GSDEChromiumHelper"` found no remaining GSDE-owned main, code-server, or CEF helper processes. |
| 2026-05-04 | 0.1.0 (build 186, git working tree) | 26.4.1 | Partial blocked | GSDE-20 retry check attempt used `/tmp/gsde20-vscode-manual.wOeQhO` with the packaged app at `build/GSDE.app`. `gsde --validate` passed, then `GSDE.app/Contents/Resources/code-server/bin/code-server` was moved to `code-server.gsde20.bak` before launching through the packaged shim. GSDE stayed running and spawned only the CEF GPU/network/storage helper processes; `pgrep -fl "code-server.*gsde20-vscode-manual"` found no bundled code-server child, so there was no silent fallback to another editor path and no app crash. The executable was restored and a fresh launch of the same config started both bundled `code-server` pane listeners (`127.0.0.1:49784` and `127.0.0.1:49785`) plus CEF renderer helpers. The required inline error text and in-place Retry button click could not be completed in this agent environment because `screencapture -x /tmp/gsde20_missing.png` failed with `could not create image from display`, and System Events AX inspection failed with `osascript is not allowed assistive access`; therefore this is not a passing manual retry verification. The executable was restored and post-run `pgrep -fl 'gsde20-vscode-manual|build/GSDE.app|code-server'` found no remaining GSDE-owned processes. |
| 2026-05-04 | 0.1.0 (build 188, git working tree) | 26.4.1 | Partial blocked | Re-ran the GSDE-20 packaged-app retry scenario with `/tmp/gsde20-vscode-manual.B8HGDm`. `make app-with-chromium verify-code-server-bundle` passed and `gsde --validate` passed. With `build/GSDE.app/Contents/Resources/code-server/bin/code-server` moved to `code-server.gsde20.bak`, launching through the packaged shim left GSDE running with CEF GPU/network/storage helpers and no `code-server.*gsde20-vscode-manual` process, confirming no crash and no silent fallback. The executable was restored while the app remained open. Visual/AX verification of the inline error and Retry control remained blocked: `screencapture -x /tmp/gsde20_missing.png` failed with `could not create image from display`, and `System Events` could list the GSDE process but failed window inspection with `osascript is not allowed assistive access`. An attempted coordinate-based CGEvent click sweep over the estimated retry-button positions did not start any `code-server` child, so the required in-place Retry acceptance check is still not recorded as passing. Post-run cleanup left no `gsde20-vscode-manual.B8HGDm`, `build/GSDE.app`, or GSDE-owned code-server processes. |
