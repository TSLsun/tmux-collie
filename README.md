# tmux-collie

Herd coding agents across git worktrees, from tmux.

> **Status: 0.x, experimental.** Interfaces may change without notice.

New here? [docs/USAGE.md](docs/USAGE.md) shows the task lifecycle, states and
where each action lives in diagrams and tables.
See [docs/DESIGN.md](docs/DESIGN.md) for goals, data model and roadmap, and
[docs/UNVERIFIED.md](docs/UNVERIFIED.md) for what has not been checked yet.

## Install

Requires bash 3.2+ (macOS `/bin/bash` is fine), git and tmux 3.2+.
Optional: [fzf](https://github.com/junegunn/fzf) 0.63+ (`dash`, `go` without an id),
[lazygit](https://github.com/jesseduffield/lazygit) (menu entry), and at least
one coding agent CLI (claude, codex, gemini or omp). `collie doctor` checks
all of these.

With [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'TSLsun/tmux-collie'          # or 'TSLsun/tmux-collie#v0.2.0' to pin
```

Then `prefix + I`. The plugin prepends its `bin/` to tmux's global `PATH`, so
`collie` is available in every new pane.

## Usage

The unit of work is a **task**: a slug id, a `TASK.md` contract, one worktree
per repo involved, and one tmux session (one window per repo).

```sh
collie new login                       # task in the current repo, branch feat/login
collie new typo -t fix                 # branch fix/typo
collie new login -m 'add OAuth login'  # pre-fill TASK.md's Objective
collie new                             # on a terminal: prompts for id, type, objective, ship,
                                       # and with an objective, whether to start the agent
collie new login -m 'add OAuth login' --run   # create and start the agent (see collie run)
collie new login --ship                # agent ships it: commits, PR, CI (see below)
collie new deploy-v2 -r A -r B         # cross-repo task (repos by name or path)
collie new trip -r ~/notes/Trip        # plain folder (not git): used in place
collie new deploy-v2 -r A -r B:release/v2   # per-repo branch
collie new checkout-fix -w shop        # all repos of a workspace
collie add deploy-v2 -r C              # pull another repo in mid-task
collie ls                              # id  status  priority  session(*|-)  agent  repos  needs
collie show deploy-v2                  # fields, TASK.md contract, repos, runs, events
collie edit deploy-v2                  # adjust TASK.md in $EDITOR (also: dash e, prefix h e)
collie go deploy-v2                    # switch/attach (fzf picker if no id)
collie done deploy-v2                  # accept: remove worktrees + session, keep branches
collie archive deploy-v2               # abandon: same cleanup
collie reopen deploy-v2                # closed by mistake: worktrees back on the kept branches
```

### Agents

```sh
collie run deploy-v2                   # claude in a new window of the task session
collie run deploy-v2 -r B -p 'fix CI'  # in repo B's worktree, custom first prompt
collie run deploy-v2 --agent codex      # also: gemini, omp; state hooks injected per run
collie run --agent aider -- --model x  # any command works (no state hooks)
collie doctor                          # deps, agents, task/worktree consistency
collie ls                              # agent column: waiting/idle/working/exited/unknown
```

### Review and lifecycle

```sh
collie review deploy-v2                # commits, diff stat, dirty files, REPORT.md
collie spike try-cache                 # from a dirty worktree: exp/try-cache task with the same changes
collie spike try-cache -u              # ...plus untracked (non-ignored) files
collie gc                              # finish tasks whose branches were merged
collie history                         # finished tasks, newest first; fzf picker, enter: show
collie history -n oauth                # rows of finished tasks whose TASK.md/REPORT.md mention oauth
collie sync -n                         # after a merge: which task branches would conflict
collie sync                            # merge base into them; agents resolve conflicts
```

`collie run`'s default prompt asks the agent to write `.collie/REPORT.md`.
Task status is derived, never set by hand: `todo` until the first agent run,
`active` after it, `review` once no agent is working or waiting and REPORT.md
was written since the last run started; `done` / `archived` come from
`done`, `gc` and `archive`, and `reopen` undoes them. If the agents are quiet
but the last run left no REPORT.md, the task stays `active` and `show` and the
dashboard preview say `no REPORT.md since run N`.
`done` and `gc` fetch `origin` first, so a PR merged on GitHub counts without
a manual fetch (progress is reported per repo on stderr), and also recognize
squash merges with git >= 2.38. A client viewing a finished task's session
switches to its last session (else the most recently used one) instead of
detaching; it detaches only when no other session exists.
`collie sync` merges the base branch (fetched first) into every active task
branch, so open PRs stay mergeable after one lands. A clean merge is committed
and pushed if the branch has an upstream. On a conflict the merge is started
and the agent is told which files to resolve: typed into it if idle, or a new
run if it exited; with no agent the worktree is left alone. Tasks whose agent
is working or waiting, dirty worktrees and branches without commits of their
own are skipped. It merges instead of rebasing: no force-push, conflicts are
resolved once, and squash merges discard the merge commits anyway.
`collie sync -n` also predicts conflicts between tasks: for each two branches
of a repo, whether the second conflicts once the first has landed, and in which
files (read-only: `git merge-tree` on a dangling merge of base and the first).
Merged branches and branches without commits of their own are left out; one
that conflicts with base is shown as that alone. It helps pick the merge order
or spot tasks to combine.
`hooks/pre-push` refuses to push `exp/*` branches:
`ln -s ~/.tmux/plugins/tmux-collie/hooks/pre-push "$(git rev-parse --git-common-dir)/hooks/pre-push"`.

### Dashboard and menu

```sh
collie dash                            # fzf: needs you > active > todo; tab regroups
collie set deploy-v2 priority=P1 "title=Ship v2"
```

`ls`'s last column says what a task needs from you: `answer` (an agent waits
for permission or input), `review` (fresh REPORT.md), `reply` (an agent
finished its turn without one), `stalled` (active, no live agent), `start`
(todo), or `-` (an agent is working, or the task is finished).

Dashboard rows start with a glyph (red `●` needs you: answer, review, reply,
stalled; yellow `◐` working; dim `○` todo), then aligned columns: id, state
(the needs value, or `working`), priority (P0 red, P1 yellow, P3 dim), a colored badge per
running agent, the age of the last event, repos, and the task branch's PR per
repo (`#N`: open green, draft dim, merged purple, closed red; `-` for none),
then a yellow `⚡N` when the task is predicted to conflict with N others (base
counts as one; the preview names them and their files). The prediction is
cached per task by `sync`, `sync -n` and `gc`; once a branch or base moves, it
is hidden and recomputed in the background.
PRs come from `gh`, cached per task for 5 minutes and refreshed in the
background (and by `sync` and `gc`). Rows come in groups under a
`── <group> (<n>) ──` line, the most urgent next to the prompt: needs you,
active, todo. `tab` / `shift-tab` switch the grouping (status, priority,
repo); it is kept for the next dashboard. Keys work like lazygit: they act
directly, and only `/` opens a filter. The preview pane doubles as the action
panel, so the list stays in view. `enter` goes to the task; `r` runs an agent
in the background (the row updates; `enter` jumps to it), `a` adopts one, `d`
marks the task done and `x` archives it (each after y/n in the panel, then in
the background), `v` switches the panel to `collie review` and back
(`shift-↑/↓` scroll), `s` syncs; `e` edits TASK.md, `t` opens a terminal and
`c` creates a task, full screen. A finished action leaves one line in the
panel that fades; a failed one shows its output in red until a key. `j` / `k` move, `space` marks or unmarks a task (marked rows
show `*`), `q` or esc quits. In the `/` filter every key types; `enter` keeps
the filter (the header shows `filter: <query>`) and returns to the keys, esc drops it. `?`
opens the action menu in the panel (run agent, adopt agent, edit
task, review, terminal, done, archive, sync, new task): press its key, or move
with ↑↓ and press enter; esc closes it. `sync` (`s`) shows `collie sync -n` for the marked
tasks (or the selected one when none is marked) in the panel, asks y/n, then syncs only
those; switching the grouping clears the marks. The header lists the direct keys. The preview shows
the start of TASK.md's Objective.

`prefix h` opens a menu (dashboard, lazygit, terminal, new
task, edit task, review, run agent, adopt agent, done, archive, jump to alert, gc merged tasks) for the current session's task; outside a
task session it keeps only dashboard, lazygit, terminal, new task, jump to alert and gc merged tasks.
`run agent` (`r`) switches you to the new agent window;
plain `collie run` leaves it in the background (`-s` switches). `jump to alert` (`j`) switches to the pane of the last agent that notified. `prefix h h` goes straight to the
dashboard. `new task` (`c`) prompts in a popup, creates the task from the
current pane's repo and switches to it. A popup whose command fails stays open
until you press a key. Change the key with `set -g @collie-key 'h'`.

To reach the dashboard with one terminal key, send `prefix h h`. Alacritty
with prefix `C-b`:

```toml
[[keyboard.bindings]]
key = "J"
mods = "Command"
chars = "\u0002hh"
```

zsh completion: `fpath+=(~/.tmux/plugins/tmux-collie/completions)` before
`compinit`.

### Agent details

`collie run` points the agent at `.collie/TASK.md` with a prompt that starts with
the task id and title, so sessions are told apart in the agent's history (`-p ''`
for no prompt; claude also gets `--name "<id>: <title>"`).
Claude Code, Codex and Gemini CLI report their state through hooks that
collie passes per run (`--settings`, `-c hooks...`, a generated system
settings file); omp through an extension loaded with `-e agents/omp.ts`
(tool approvals and the `ask` tool count as waiting); nothing to install.
Codex asks you to trust the hooks once in `/hooks`. Other agents count as
idle after 30s without output (`@collie-silence`).
The same three also get `hooks/tmux-guard`, which blocks shell commands that
would kill your tmux server (`tmux kill-server`/`kill-session`, `pkill tmux`)
unless they name a private server with `-L`/`-S`; limits in DESIGN.md.
Agents you start by hand in a task's session (`claude`, `codex`, `gemini`,
`omp`, `aider`) are found by process and show up the same way, but without
hooks they are only working or idle (by output silence) and do not notify.
`collie adopt` (dashboard `?` → `a`, `prefix h` → `a`) stops such a Claude or omp and restarts
it with `collie run … -- --continue` (omp: `-r <id>` of the session it holds
open, else `-c`): same conversation, now with hooks.
When the tmux server dies, `collie restore` (`-n` to list) restarts every
agent run that was live, each resuming its own conversation: claude by the
session id its `SessionStart` hook logged (`--resume <id>`), omp by the
latest one in its worktree (`-c`, one run per worktree); other agents are
skipped. `set -g @collie-restore on` runs it when the plugin loads.

```tmux
set -g status-right '#{collie_status} %H:%M'   # ●waiting ●idle ●working counts
set -g @collie-agent 'claude'                  # default agent ($COLLIE_AGENT wins)
set -g @collie-notify 'on'                     # on | off | command "title" "body"
set -g @collie-restore 'off'                   # on: collie restore at plugin load
```

With [terminal-notifier](https://github.com/julienXX/terminal-notifier)
installed, clicking a notification focuses the terminal and jumps to the agent's
pane; set `@collie-terminal` to the terminal's bundle id if it is not detected
(e.g. `com.mitchellh.ghostty`). Without it, notifications are unchanged; use
`prefix h j`.

Windows carry `@collie_state`, usable in `window-status-format`.

Configuration:

```tmux
set -g @collie-repo-roots '~/Repos/*/*'      # ':'-separated globs ($COLLIE_REPO_ROOTS wins)
```

```
# ~/.config/collie/workspaces
shop: api web infra
```

Task data lives in `~/.local/state/collie/tasks/<id>/` (`TASK.md`, `repos.tsv`,
`events.log`) and survives worktree removal. Each worktree gets a `.collie`
symlink to it, excluded via the repo's `info/exclude`.

`done` refuses dirty worktrees or commits not in the base branch; `archive`
refuses only dirty worktrees, since abandoned work is unmerged by definition
(`--force` overrides and discards uncommitted changes; branches are always kept). `new` is all-or-nothing:
a failure rolls back worktrees and branches it already created.

### Ship workflow

Off by default. When on, `collie new` appends a `## Ship` section to TASK.md
telling the agent (any agent) to finish the delivery loop: logical
Conventional Commits with fixups squashed, push and `gh pr create` once the
Acceptance Criteria and Verify checks pass (no `gh`: push and report the
branch URL), wait for CI, fix a clearly-caused failure at most once, and
otherwise stop and write the failure analysis to REPORT.md. It never merges.

```tmux
set -g @collie-ship 'on'                       # default for new tasks ($COLLIE_SHIP wins)
```

`collie new --ship` / `--no-ship` overrides it per task, and the new-task popup
asks. The rules live in the task's TASK.md, so you can read (`collie show`) or
edit (`collie edit`) them before `collie run`; replace them for all tasks with
`~/.config/collie/SHIP.md`.

### Folder tasks

A directory that is not a git repository (given with `-r <path>`, or the
current one when `new` runs outside a repo) joins a task as a **folder**: the
agent works in it in place, with no branch and no copy. collie never writes
into it (no `.collie` link: the run prompt names the task dir instead), and
`done` / `archive` only close the session, without checks or removal. `gc`
never finishes a folder-only task; `review` lists the folder's files
modified since the task's first run. A folder another unfinished task already
uses (or a parent or child of it) is allowed with a warning. Folders and repos
can be mixed in one task. See [docs/FOLDER-TASKS.md](docs/FOLDER-TASKS.md).

### Repository layouts

| Layout | Detected by | Worktrees go to |
|---|---|---|
| bare | `<root>/.bare` + `<root>/.git` (`gitdir: ./.bare`) | `<root>/<slug>` |
| normal clone | `<repo>/.git` directory | `<repo>.worktrees/<slug>` |

`<slug>` is the branch name with `/` replaced by `-` (`feat/login` → `feat-login`).
Windows are tagged with `@collie_path` / `@collie_task`; sessions export
`COLLIE_TASK` and `COLLIE_TASK_DIR`.

`collie new` and `collie add` fetch `origin` before creating worktrees, so a
new branch starts from origin's latest default branch. Offline, they warn and
start from local refs.

## Development

```sh
make check   # shellcheck + bats (uses an isolated tmux server per test)
```

Scripts target bash 3.2 (macOS `/bin/bash`).

`bin/collie` is the entry point; it sources shared helpers from `lib/*.sh`
and the commands from `lib/cmd/*.sh`. A function `cmd_<name>` is the command
`<name>` (no dispatch list to edit); its help line goes in `lib/usage.sh`.

To try a checkout in your running tmux, `set -g @collie-dev on`: the menu gets
`dev: load this checkout` (reloads the plugin from the current pane's
tmux-collie checkout, e.g. a task worktree) and `dev: back to installed`
(reloads the copy tpm installed, `@collie-home`). Same from a shell:
`collie _dev load <dir>` / `collie _dev reset`.

## License

MIT
