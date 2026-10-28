# Unverified

Behaviour that has no automated test and has not been checked by hand yet.
Check items off (with date + how) before calling a phase done for real use;
delete an item only when it is covered by a test.

## P0 — Foundation
- [ ] CI workflow (`.github/workflows/ci.yml`) has never run (no remote yet).
- [ ] Install through tpm (`set -g @plugin ...` + `prefix I`) on a real tmux config.

## P1 — Task model
- [ ] Menu `new task` popup (`display-popup -EE`): prompts, `switch-client`
  to the new session, popup kept open on failure. Prompt mode itself was
  checked with `expect`, the popup was not.
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
      nested items (confirm-before), popups sizing, lazygit popup
      opening in the pane's directory. Tests only check the binding text and
      `run-shell collie done`.
- [ ] Menu actions on a session that is not a task (should show collie's error).
- [x] `edit task` popups (menu `prefix h e`, dash `?` `e`) open `$EDITOR`, close on
      save, and the dash preview shows the change. Checked 2026-10-26 with vi on
      `tmux -L collie-test` (tmux 3.8), driving a real client from an outer tmux.
- [ ] `$EDITOR` inside the menu popup comes from the tmux server environment;
      an `EDITOR` exported only in a later shell does not reach it (falls back to vi).
- [ ] zsh completion in an interactive shell (only `zsh -n` is checked).
- [ ] Alacritty `chars = "\u0002hh"` example in README.

## P4 — More agents & doctor
- [x] omp adapter, checked 2026-10-28 with real omp 18.13.1 (bun script,
      argv `bun …/omp …`) and 18.13.2 (Homebrew binary, argv `omp …`): found
      by process, `adopt` resumes its own conversation by the id of the
      `run/session-owners/<id>.lock` it holds (`-c` took the session a reused
      tty last showed), extension reports working/idle. `waiting` (ask,
      approvals) only tested with a fake omp.
- [x] Codex 0.165.0 on macOS, checked 2026-10-28: hooks, approval/question
      waits and recovery, notifications/status, adoption and exact restore.
- [ ] Other Codex versions/platforms and localized/custom prompts are unverified.
      Human waits may remain working; startup trust dialogs do not notify.
- [ ] Codex adoption requires a hand-started `--no-daemon` process and `lsof`;
      unknown or ambiguous conversations are refused.
- [ ] Restore caveat: an old window closed without an exit record can appear
      lost after a later server failure. Inspect `restore -n` first.
- [ ] Gemini for real: system settings layer picked up and merged with user
      hooks; hooks enabled without extra flags; `ToolPermission` matcher;
      ancestor-pane lookup under its sanitized env. Tried 2026-10-25: two trust
      dialogs (folder, then `--include-directories`) appeared before any hook ran;
      run not completed.
- [ ] `GEMINI_CLI_SYSTEM_SETTINGS_PATH` hides an existing
      `/etc/gemini-cli/settings.json` for collie runs.
- [ ] `ancestor_pane` on Linux (`ps -o ppid=`), and with deep process trees
      (gives up after 10 levels).
- [ ] `collie doctor` version parsing for tmux builds like `next-3.6` / `3.3a`.
- [x] Real Codex 0.165.0 tmux guard denial, checked 2026-10-28. Named private
      servers pass the guard, but macOS sandbox permissions may still block
      socket access.
- [ ] Claude and Gemini tmux guards through real agents. Deterministic tests
      verify their emitted hook commands and denial behavior.

## P5 — Review & lifecycle
- [ ] `gc` against a real remote: PR merge commits (non-ff) detected after
      `git fetch`; squash merges are known not to be detected.
- [ ] `gc` on tasks created before P5 (no `start=` in events): never collected.
- [ ] `spike` with a merge/rebase in progress, submodules, or renames staged.
- [ ] `review` popup from the menu (`| less -R`), long outputs and colours.
- [ ] Agents actually writing `.collie/REPORT.md` from the default prompt.
- [ ] Derived `review` with a real agent: REPORT.md written, then the agent
      goes idle (tests drive the hooks and write REPORT.md themselves).
- [ ] `hooks/pre-push` installed by symlink into a bare repo's `hooks/`
      (tests use `core.hooksPath`).
