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
