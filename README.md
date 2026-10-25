# tmux-collie

Herd coding agents across git worktrees, from tmux.

> **Status: 0.x, experimental.** Interfaces may change without notice.

See [docs/DESIGN.md](docs/DESIGN.md) for goals, data model and roadmap, and
[docs/UNVERIFIED.md](docs/UNVERIFIED.md) for what has not been checked yet.

## Install

Requires bash 3.2+ (macOS `/bin/bash` is fine), git and tmux 3.2+.
Optional: [fzf](https://github.com/junegunn/fzf) (`dash`, `go` without an id),
[lazygit](https://github.com/jesseduffield/lazygit) (menu entry), and at least
one coding agent CLI (claude, codex, gemini or omp). `collie doctor` checks
all of these.

With [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'TSLsun/tmux-collie'          # or 'TSLsun/tmux-collie#v0.1.0' to pin
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
collie new                             # on a terminal: prompts for id, type, objective
collie new deploy-v2 -r A -r B         # cross-repo task (repos by name or path)
collie new deploy-v2 -r A -r B:release/v2   # per-repo branch
collie new checkout-fix -w shop        # all repos of a workspace
collie add deploy-v2 -r C              # pull another repo in mid-task
collie ls                              # id  status  priority  session(*|-)  repos  next
collie show deploy-v2
collie go deploy-v2                    # switch/attach (fzf picker if no id)
collie done deploy-v2                  # accept: remove worktrees + session, keep branches
collie archive deploy-v2               # abandon: same cleanup
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
collie park -m "rerun e2e after deploy"   # remember where you stopped
git fetch && collie gc                 # finish tasks whose branches were merged
```

`collie run`'s default prompt asks the agent to write `.collie/REPORT.md`.
`gc` sees fast-forward and merge commits on the base branch, not squash merges.
`hooks/pre-push` refuses to push `exp/*` branches:
`ln -s ~/.tmux/plugins/tmux-collie/hooks/pre-push "$(git rev-parse --git-common-dir)/hooks/pre-push"`.

### Dashboard and menu

```sh
collie dash                            # fzf: waiting > idle > review > blocked > working
collie set deploy-v2 status=review "next=check the infra diff"
collie notes deploy-v2                 # $EDITOR on NOTES.md
```

`prefix h` opens a menu (dashboard, lazygit, notes, next action, status, new
task, run agent, done) for the current session's task; `prefix h h` goes straight to
the dashboard. `new task` (`c`) prompts in a popup, creates the task from the
current pane's repo and switches to it. Change the key with `set -g @collie-key 'h'`.

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

`collie run` points the agent at `.collie/TASK.md` (`-p ''` for no prompt).
Claude Code, Codex and Gemini CLI report their state through hooks that
collie passes per run (`--settings`, `-c hooks...`, a generated system
settings file); nothing to install. Codex asks you to trust the hooks once
in `/hooks`. Other agents count as idle after 30s without output
(`@collie-silence`).

```tmux
set -g status-right '#{collie_status} %H:%M'   # ●waiting ●idle ●working counts
set -g @collie-agent 'claude'                  # default agent ($COLLIE_AGENT wins)
set -g @collie-notify 'on'                     # on | off | command "title" "body"
```

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

`done`/`archive` refuse dirty worktrees or commits not in the base branch
(`--force` overrides; branches are always kept). `new` is all-or-nothing:
a failure rolls back worktrees and branches it already created.

### Repository layouts

| Layout | Detected by | Worktrees go to |
|---|---|---|
| bare | `<root>/.bare` + `<root>/.git` (`gitdir: ./.bare`) | `<root>/<slug>` |
| normal clone | `<repo>/.git` directory | `<repo>.worktrees/<slug>` |

`<slug>` is the branch name with `/` replaced by `-` (`feat/login` → `feat-login`).
Windows are tagged with `@collie_path` / `@collie_task`; sessions export
`COLLIE_TASK` and `COLLIE_TASK_DIR`.

`collie new` does not fetch; run `git fetch` first if you want a fresh base.

## Development

```sh
make check   # shellcheck + bats (uses an isolated tmux server per test)
```

Scripts target bash 3.2 (macOS `/bin/bash`).

## License

MIT
