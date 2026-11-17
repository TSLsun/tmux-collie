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
      2026-11-12: an isolated repo without `origin/HEAD` selected `origin/main`.

## P2 — Agent runtime
- [ ] Claude `waiting`: `Notification` matcher `permission_prompt|elicitation_dialog`
      never fired in a manual run (auto mode on, no permission prompt).
      Verified by hand on 2026-10-24: working → idle → exited with Claude Code 2.1.310.
      2026-11-12: Claude 2.1.322 displayed a real permission modal under
      collie, but remained idle with no waiting event. Fix `claude-wait-notification`.
- [x] Claude folder-trust dialog (2.1.319 on macOS, checked 2026-11-10):
      `waiting`, `answer`, notification, `wait --state waiting` and `send` exit 2;
      after trusting a throwaway repo the run followed its hooks to `idle`.
      Before `startup-blocked` merged, Claude 2.1.322 showed idle during trust
      in an isolated run on 2026-11-12.
- [ ] Startup dialog text in other agent versions and locales: unknown text
      stays `working`, and `send` is not blocked. The first moments before a
      dialog draws are unguarded: a `send` to an idle no-prompt run can land there.
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
      2026-11-12: privately built tmux 3.2a and 3.3a rendered real collie
      waiting, idle and working counts (`●1 ●1 ●1`) in attached ptys;
      colors and clicks remain unchecked.
      2026-11-16: color capture and reliable click mapping unavailable here.
- [ ] Clicking a menu item with the mouse (only the item's key was sent).
      2026-11-12: an SGR click closed the private-client menu but did not run
      the target marker; synthetic pty coordinate mapping was inconclusive.
      2026-11-16: no reliable synthetic mouse selection was established here.
- [x] `#{collie_status}` rendering in a real status bar (glyph width, colours,
      refresh every `status-interval`). Checked 2026-11-12 with an attached
      private pty and one-second interval: red waiting changed to yellow idle,
      green remained visible, and the glyphs used the same cursor column.
- [ ] Latency of `collie state` from `PostToolUse` on every tool call is
      unnoticeable.
      2026-11-11: 30 isolated hook-command calls measured median 29.40 ms,
      p95 34.02 ms, max 34.51 ms; perceived impact during agent use not checked.
- [ ] Omp run 1 from `unverified-sweep` (session
      `01a1c857-cafd-75ec-8e7b-8a2f79b1253a`) stayed `working` despite an idle
      prompt (reported 2026-11-16). Read-only `events.log` records the run start
      and notes that interactive checks were inconclusive, but contains no hook
      event/state-transition trace. `agents/omp.ts` already maps main-agent
      `agent_end` without `willContinue` to `idle`; subagent ends are ignored.
      Could not reproduce or distinguish a missing `agent_end`/`willContinue`
      case from a failed hook invocation: the original live session is no longer
      available and the event log does not record extension events. No cause
      established; needs a real omp run with event instrumentation before a
      safe code fix can be made.
- [ ] Claude interrupted while `working`: the configured Claude hook events
      include `Stop` (normal turn completion), but Claude's
      [hook event reference](https://code.claude.com/docs/en/hooks#hook-events)
      has no `Interrupt` event equivalent to Codex's. No supported hook
      can currently report this transition; Escape-interrupted sessions can
      therefore remain `working`. The `Stop` hook is not a safe substitute
      because it also runs on normal completion.

## P3 — Dashboard & interaction
- [x] `collie dash` interactively: fzf layout, preview, action reload and
      urgent-window selection from a popup. Checked 2026-11-11–12 with a private
      attached pty: rows and preview rendered, sync returned to the dashboard,
      and Enter switched that same client to the waiting run's window ID.
- [x] The `prefix h` menu with a real client: `#{session_name}` expanding in
      nested confirm-before items, popup sizing, and lazygit's pane directory.
      Checked 2026-11-12 with an attached private pty: `done x?` expanded,
      a 100×30 client displayed an 88×23 lazygit popup, and a lazygit stub
      observed the originating pane's directory.
- [ ] Menu actions on a session that is not a task (should show collie's error).
      2026-11-11: private client menu displayed “not a collie task — use
      collie new”; action error behavior remains unchecked.
- [x] `edit task` popups (menu `prefix h e`, dash `?` `e`) open `$EDITOR`, close on
      save, and the dash preview shows the change. Checked 2026-10-26 with vi on
      `tmux -L collie-test` (tmux 3.8), driving a real client from an outer tmux.
- [x] `$EDITOR` inside the menu popup comes from the tmux server environment;
      an `EDITOR` exported only in a later shell does not reach it. Checked
      2026-11-12 with an attached private pty: the server editor ran instead
      of the pane-only editor; with server `EDITOR` unset the popup opened vi.
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
      Human waits may remain working.
      2026-11-11: other platforms and localized prompts not available here.
- [x] Codex 0.166.0 startup dialogs, checked 2026-11-10: folder trust and "Hooks
      need review" report `waiting`, `send` exits 2, and the run returns to
      `working` after "Continue without trusting".
- [ ] Codex hook recovery after "Trust all": not run, because the trust is one
      global hash per hook event and would replace the user's own.
- [ ] Codex adoption requires a hand-started `--no-daemon` process and `lsof`;
      unknown or ambiguous conversations are refused.
      2026-11-12: real Codex 0.167.0 hand-started with `--no-daemon` was
      adopted on private tmux with `lsof`; fake-agent tests cover unknown
      and ambiguous conversations. Missing-prerequisite behavior not checked.
- [x] Restore caveat: an old window closed without an exit record can appear
      lost after a later server failure. Checked 2026-11-11 in isolated state:
      `restore -n` showed nothing after the window closed, then listed the run
      after its private tmux server was killed. Inspect `restore -n` first.
- [ ] Gemini for real: system settings layer picked up and merged with user
      hooks; hooks enabled without extra flags; `ToolPermission` matcher;
      ancestor-pane lookup under its sanitized env. Gemini 0.66.0, checked
      2026-11-10: both startup dialogs report `waiting`, `send` exits 2, the run
      returns to `working`. Hooks after them are unverified: it refused collie's
      settings file ("not owned by root") and stopped at its auth screen.
      2026-11-11: a non-interactive run failed authentication (exit 41);
      real hook checks require credentials.
      2026-11-16: real hook verification remains blocked on Gemini authentication.
- [ ] `GEMINI_CLI_SYSTEM_SETTINGS_PATH` hides an existing
      `/etc/gemini-cli/settings.json` for collie runs.
      2026-11-11: adapter sets its generated path; actual system-file masking
      remains unchecked.
- [ ] `ancestor_pane` on Linux (`ps -o ppid=`), and with deep process trees
      (gives up after 10 levels).
      2026-11-12: a private macOS tmux probe resolved at ten verified parent
      links and returned no pane at eleven; Linux remains unavailable here.
- [x] Real Codex 0.165.0 tmux guard denial, checked 2026-10-28. Named private
      servers pass the guard, but macOS sandbox permissions may still block
      socket access.
- [ ] Claude and Gemini tmux guards through real agents. Deterministic tests
      verify their emitted hook commands and denial behavior.
      2026-11-12: real Claude 2.1.322 denied bare `tmux kill-server` while
      the private server survived. Gemini failed authentication and remains unchecked.

## P5 — Review & lifecycle
- [ ] `gc` against a real remote: PR merge commits (non-ff) detected after
      `git fetch`; squash merges are known not to be detected. Checked
      2026-11-11 with a local bare remote and non-ff merge; hosted PR not checked.
- [ ] `spike` with staged submodule updates. Checked 2026-11-11 in isolated
      repos: staged rename passed, staged submodule updates failed (task
      `spike-submodule`). Merge and rebase conflicts were checked 2026-11-17
      in isolated worktrees, including index stages and unchanged source state.
- [x] `review` popup from the menu (`| less -R`), long outputs and colours.
      Checked 2026-11-12 in an attached private pty: an 81-line report
      retained red and green ANSI colors, scrolled to its end, and closed with q.
- [x] Agents actually writing `.collie/REPORT.md` from the default prompt.
      Checked 2026-11-11 with Codex 0.167.0 in an isolated task and private tmux.
- [x] Derived `review` with a real agent: REPORT.md written, then the agent
      goes idle. Checked 2026-11-11 with Codex 0.167.0: idle event, derived
      review status, and `collie review` displaying the report.
- [x] `hooks/pre-push` installed by symlink into a bare repo's `hooks/`.
      Checked 2026-11-11 in an isolated bare-layout repo: normal push passed,
      `exp/*` was blocked, and `COLLIE_ALLOW_EXP=1` allowed it.
