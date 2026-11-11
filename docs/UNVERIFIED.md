# Unverified

Behaviour that has no automated test and has not been checked by hand yet.
Check items off (with date + how) before calling a phase done for real use;
delete an item only when it is covered by a test.

## P0 — Foundation
- [x] CI workflow (`.github/workflows/ci.yml`) ran successfully. Checked 2026-11-11:
      `gh run list --workflow ci.yml` showed successful PR and main runs
      (42939102536 and 42938123842).
- [x] Install through tpm (`set -g @plugin ...` + `prefix I`). Checked
      2026-11-11 with a fresh TPM checkout, isolated config and private tmux
      pty client: plugin installed and collie binding and home were active.

## P1 — Task model
- [x] Menu `new task` popup (`display-popup -EE`): prompts, `switch-client`
      to the new session, popup kept open on failure. Checked 2026-11-11 with
      a private tmux pty client: successful creation switched sessions; a
      branch conflict left the error and draft notice visible.
- [x] `collie go` inside tmux (`switch-client`) and from a bare tty (`exec attach`).
      Checked 2026-11-11 with private tmux pty clients in both paths.
- [x] bash 5. Checked 2026-11-11: `COLLIE_BASH=/opt/homebrew/bin/bash make test`
      passed all 371 tests with Homebrew Bash 5.3.20 on macOS.
- [ ] Daily use on real repos (bare layout from the dotfiles clone script,
      normal clones, repos with `origin/HEAD` unset).
      2026-11-11: sustained daily use cannot be established by isolated tests.

## P2 — Agent runtime
- [ ] Claude `waiting`: `Notification` matcher `permission_prompt|elicitation_dialog`
      never fired in a manual run (auto mode on, no permission prompt).
      Verified by hand on 2026-10-24: working → idle → exited with Claude Code 2.1.310.
      2026-11-11: no real permission prompt was triggered.
- [ ] Claude folder-trust dialog on a new worktree shows as `working` until
      answered (known gap; no hook covers it).
      2026-11-11: no isolated real trust dialog was triggered.
- [ ] Built-in notifications (`osascript` on macOS, `notify-send` on Linux);
      tests only use a custom `$COLLIE_NOTIFY` command.
      2026-11-11: macOS GUI delivery needs visual confirmation; Linux
      `notify-send` is unavailable on this host.
- [x] Notification skipped for the active window of an attached session.
      Checked 2026-11-11 on private tmux 3.8: the active window suppressed a
      waiting notification; switching sessions allowed the next one.
- [ ] Clickable status counts on tmux 3.2/3.3 (no `range=user`): the counts
      should still render, colored and unclickable. Click → menu → jump was
      checked on 3.8 on 2026-10-29 with a pty client sending SGR mouse events.
      2026-11-11: only tmux 3.8 available locally.
- [ ] Clicking a menu item with the mouse (only the item's key was sent).
      2026-11-11: no live mouse-selection fixture was established.
- [ ] `#{collie_status}` rendering in a real status bar (glyph width, colours,
      refresh every `status-interval`).
      2026-11-11: substitution confirmed on tmux 3.8; visible width, colours,
      and periodic refresh were not established.
- [ ] Latency of `collie state` from `PostToolUse` on every tool call is
      unnoticeable.
      2026-11-11: 30 isolated hook-command calls measured median 29.40 ms,
      p95 34.02 ms, max 34.51 ms; perceived impact during agent use not checked.

## P3 — Dashboard & interaction
- [ ] `collie dash` interactively: fzf layout, preview pane, rows reloading after an action,
      enter selecting the urgent window and switching session (from a popup,
      `switch-client` must act on the popup's client). Tests cover rows,
      ordering, preview text and target window only.
      2026-11-11: private attached client displayed fzf rows and preview; Enter
      switched to the selected task. Popup client, urgent window, and reload remain unchecked.
- [ ] The `prefix h` menu with a real client: `#{session_name}` expanding in
      nested items (confirm-before), popups sizing, lazygit popup
      opening in the pane's directory. Tests only check the binding text and
      `run-shell collie done`.
      2026-11-11: these menu interactions were not exercised.
- [ ] Menu actions on a session that is not a task (should show collie's error).
      2026-11-11: private client menu displayed “not a collie task — use
      collie new”; action error behavior remains unchecked.
- [x] `edit task` popups (menu `prefix h e`, dash `?` `e`) open `$EDITOR`, close on
      save, and the dash preview shows the change. Checked 2026-10-26 with vi on
      `tmux -L collie-test` (tmux 3.8), driving a real client from an outer tmux.
- [ ] `$EDITOR` inside the menu popup comes from the tmux server environment;
      an `EDITOR` exported only in a later shell does not reach it (falls back to vi).
      2026-11-11: server environment inheritance was not exercised.
- [x] zsh completion in an interactive shell. Checked 2026-11-11 with `expect`:
      `collie doct<Tab>` completed to `collie doctor` after `compinit`.
- [ ] Alacritty `chars = "\u0002hh"` example in README.
      2026-11-11: Alacritty 0.17 is installed; keybinding needs GUI interaction.

## P4 — More agents & doctor
- [x] omp adapter, checked 2026-10-28 with real omp 18.13.1 (bun script,
      argv `bun …/omp …`) and 18.13.2 (Homebrew binary, argv `omp …`): found
      by process, `adopt` resumes its own conversation by the id of the
      `run/session-owners/<id>.lock` it holds (`-c` took the session a reused
      tty last showed), extension reports working/idle. `waiting` (ask,
      approvals) only tested with a fake omp. 2026-11-03, real 18.15.0
      (`omp -p`, one task-tool subagent): the subagent's events carry
      `ctx.agent.kind` `sub` and its `agent_end` no longer reports idle.
- [x] Codex 0.165.0 on macOS, checked 2026-10-28: hooks, approval/question
      waits and recovery, notifications/status, adoption and exact restore.
- [ ] Other Codex versions/platforms and localized/custom prompts are unverified.
      Human waits may remain working; startup trust dialogs do not notify.
      2026-11-11: other platforms and localized prompts not available here.
- [ ] Codex adoption requires a hand-started `--no-daemon` process and `lsof`;
      unknown or ambiguous conversations are refused.
      2026-11-11: fake-agent tests cover unknown and ambiguous conversations;
      no real hand-started adoption was run.
- [x] Restore caveat: an old window closed without an exit record can appear
      lost after a later server failure. Checked 2026-11-11 in isolated state:
      `restore -n` showed nothing after the window closed, then listed the run
      after its private tmux server was killed. Inspect `restore -n` first.
- [ ] Gemini for real: system settings layer picked up and merged with user
      hooks; hooks enabled without extra flags; `ToolPermission` matcher;
      ancestor-pane lookup under its sanitized env. Tried 2026-10-25: two trust
      dialogs (folder, then `--include-directories`) appeared before any hook ran;
      run not completed.
      2026-11-11: Gemini 0.66.0 non-interactive run failed authentication
      (exit 41); a real hook check needs credentials.
- [ ] `GEMINI_CLI_SYSTEM_SETTINGS_PATH` hides an existing
      `/etc/gemini-cli/settings.json` for collie runs.
      2026-11-11: adapter sets its generated path; actual system-file masking
      remains unchecked.
- [ ] `ancestor_pane` on Linux (`ps -o ppid=`), and with deep process trees
      (gives up after 10 levels).
      2026-11-11: Linux unavailable; private tmux deep-tree probes had invalid
      context and were inconclusive.
- [ ] `collie doctor` version parsing for tmux builds like `next-3.6` / `3.3a`.
      Checked 2026-11-11: `3.3a` passes, but `next-3.6` fails; fix task
      `doctor-tmux-version`.
- [x] Real Codex 0.165.0 tmux guard denial, checked 2026-10-28. Named private
      servers pass the guard, but macOS sandbox permissions may still block
      socket access.
- [ ] Claude and Gemini tmux guards through real agents. Deterministic tests
      verify their emitted hook commands and denial behavior.
      2026-11-11: real Gemini failed authentication; Claude was not exercised.

## P5 — Review & lifecycle
- [ ] `gc` against a real remote: PR merge commits (non-ff) detected after
      `git fetch`; squash merges are known not to be detected. Checked
      2026-11-11 with a local bare remote and non-ff merge; hosted PR not checked.
- [ ] `spike` with a merge/rebase in progress, submodules, or renames staged.
      Checked 2026-11-11 in isolated repos: staged rename passed; conflicts and
      staged submodule updates failed. Fix tasks `spike-conflicts` and
      `spike-submodule`.
- [ ] `review` popup from the menu (`| less -R`), long outputs and colours.
      2026-11-11: CLI report display checked with Codex; popup pager not exercised.
- [x] Agents actually writing `.collie/REPORT.md` from the default prompt.
      Checked 2026-11-11 with Codex 0.167.0 in an isolated task and private tmux.
- [x] Derived `review` with a real agent: REPORT.md written, then the agent
      goes idle. Checked 2026-11-11 with Codex 0.167.0: idle event, derived
      review status, and `collie review` displaying the report.
- [x] `hooks/pre-push` installed by symlink into a bare repo's `hooks/`.
      Checked 2026-11-11 in an isolated bare-layout repo: normal push passed,
      `exp/*` was blocked, and `COLLIE_ALLOW_EXP=1` allowed it.
