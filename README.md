# tmux-collie

Herd coding agents across git worktrees, from tmux. Collie creates task
worktrees and sessions, starts agents, and helps you monitor and review their
work. See the [feature tour](https://tslsun.github.io/tmux-collie/).

> **Status: 0.x, experimental.** Interfaces may change without notice.

These docs describe the current `main` branch, not necessarily a pinned release.

## Install

Requires bash 3.2+ (macOS `/bin/bash` is fine), git and tmux 3.2+.
Optional: [fzf](https://github.com/junegunn/fzf) 0.73+ for `dash` and the
`go` picker, [lazygit](https://github.com/jesseduffield/lazygit), and a coding
agent CLI (Claude, Codex, Gemini or omp). `collie doctor` checks dependencies.

With [tpm](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'TSLsun/tmux-collie'  # or 'TSLsun/tmux-collie#v0.3.0' to pin
```

Then press `prefix + I`. The plugin prepends its `bin/` to tmux's global
`PATH`, making `collie` available in new panes.

## Quickstart

A **task** has an id, a `TASK.md` contract, a worktree per repo and a tmux
session. From a repository inside tmux:

```sh
collie new fix-retry -t fix -m 'retry 5xx on upload'
collie run fix-retry       # start an agent in the task session
collie brief               # see what needs your attention
collie review fix-retry    # inspect commits, changes and REPORT.md
collie verify fix-retry    # run TASK.md's verification commands
# Merge the branch, then:
collie done fix-retry      # remove worktrees and session, keep branches
```

Use `collie dash` for the interactive dashboard or `collie gc` to finish
merged tasks. Run `collie help <command>` for command options.

## Configuration

Configure tmux options, repositories, workspaces, agents and notifications
using the [configuration guide](docs/USAGE.md#configuration). The
[usage guide](docs/USAGE.md) covers workflows, dashboard actions and task state.

## More

- [Design and roadmap](docs/DESIGN.md)
- [Folder tasks](docs/FOLDER-TASKS.md)
- [Unverified behavior](docs/UNVERIFIED.md)
- [Development and contribution](docs/USAGE.md#development)

## License

MIT
