# Unverified

Behaviour that has no automated test and has not been checked by hand yet.
Check items off (with date + how) before calling a phase done for real use;
delete an item only when it is covered by a test.

## P0 — Foundation
- [ ] CI workflow (`.github/workflows/ci.yml`) has never run (no remote yet).
- [ ] Install through tpm (`set -g @plugin ...` + `prefix I`) on a real tmux config.

## P1 — Task model
- [ ] `collie go` inside tmux (`switch-client`) and from a bare tty (`exec attach`);
      tests only cover the non-tty path.
- [ ] bash 5 (Linux / Homebrew bash); tests have only run on macOS `/bin/bash` 3.2.
- [ ] Daily use on real repos (bare layout from the dotfiles clone script,
      normal clones, repos with `origin/HEAD` unset).

## P2 — Agent runtime
- [ ] Claude `waiting`: `Notification` matcher `permission_prompt|elicitation_dialog`
      never fired in a manual run (auto mode on, no permission prompt).
      Verified by hand on 2026-10-24: working → idle → exited with Claude Code 2.1.310.
- [ ] Claude folder-trust dialog on a new worktree shows as `working` until
      answered (known gap; no hook covers it).
- [ ] Built-in notifications (`osascript` on macOS, `notify-send` on Linux);
      tests only use a custom `$COLLIE_NOTIFY` command.
- [ ] Notification skipped for the active window of an attached session
      (tests never attach a client).
- [ ] `#{collie_status}` rendering in a real status bar (glyph width, colours,
      refresh every `status-interval`).
- [ ] Latency of `collie state` from `PostToolUse` on every tool call is
      unnoticeable.

## P3 — Dashboard & interaction
- [ ] `collie dash` interactively: fzf layout, preview pane, `ctrl-r` reload,
      enter selecting the urgent window and switching session (from a popup,
      `switch-client` must act on the popup's client). Tests cover rows,
      ordering, preview text and target window only.
- [ ] The `prefix h` menu with a real client: `#{session_name}` expanding in
      nested items (status submenu, confirm-before), popups sizing, lazygit popup
      opening in the pane's directory. Tests only check the binding text and
      `run-shell collie done`.
- [ ] Menu actions on a session that is not a task (should show collie's error).
- [ ] zsh completion in an interactive shell (only `zsh -n` is checked).
- [ ] Alacritty `chars = "\u0002hh"` example in README.
