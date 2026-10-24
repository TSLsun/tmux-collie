# tmux-collie

Herd coding agents across git worktrees, from tmux.

> **Status: 0.x, experimental.** Interfaces may change without notice.

One task → one worktree → one tmux window (→ one agent, coming in P2).
See [docs/SCOPE.md](docs/SCOPE.md) for goals, non-goals and roadmap.

## Install

With [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'TSLsun/tmux-collie'
```

Then `prefix + I`. The plugin prepends its `bin/` to tmux's global `PATH`, so
`collie` is available in every new pane.

## Usage

```sh
collie new feat/login              # worktree + tmux window, branched from default branch
collie new fix/x --from v1.2.0     # branch from a specific ref
collie new spike/y --no-window     # worktree only
collie ls                          # slug  branch  path  window(*|-)
collie go feat/login               # switch to its window (fzf picker if no arg)
cd "$(collie go feat/login)"       # outside tmux: prints the path
collie rm feat/login               # remove worktree + window, keep branch
collie rm feat/login --delete-branch
```

### Repository layouts

| Layout | Detected by | Worktrees go to |
|---|---|---|
| bare | `<root>/.bare` + `<root>/.git` (`gitdir: ./.bare`) | `<root>/<slug>` |
| normal clone | `<repo>/.git` directory | `<repo>.worktrees/<slug>` |

`<slug>` is the branch name with `/` replaced by `-` (`feat/login` → `feat-login`).
Each repo gets one tmux session (named after the repo); each worktree gets a
window tagged with `@collie_path`, so renaming windows is safe.

`collie new` does not fetch; run `git fetch` first if you want a fresh base.

## Development

```sh
make check   # shellcheck + bats (uses an isolated tmux server per test)
```

Scripts target bash 3.2 (macOS `/bin/bash`).

## License

MIT
