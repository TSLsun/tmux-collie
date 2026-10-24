# tmux-collie

Herd coding agents across git worktrees, from tmux.

> **Status: 0.x, experimental.** Interfaces may change without notice.

See [docs/DESIGN.md](docs/DESIGN.md) for goals, data model and roadmap.

## Install

With [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'TSLsun/tmux-collie'
```

Then `prefix + I`. The plugin prepends its `bin/` to tmux's global `PATH`, so
`collie` is available in every new pane.

## Usage

The unit of work is a **task**: a slug id, a `TASK.md` contract, one worktree
per repo involved, and one tmux session (one window per repo).

```sh
collie new login                       # task in the current repo, branch feat/login
collie new typo -t fix                 # branch fix/typo
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
