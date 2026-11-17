# Repository instructions for agents

## Pull requests that must remain unmerged

- Prefix the title with `[DO NOT MERGE]` and keep the PR in draft status whenever it is for testing, benchmarking, a temporary dependency, or otherwise must remain unmerged. A warning in the body alone is insufficient.
- Start the PR body with the reason it must remain unmerged and the condition for making it mergeable. If that condition is undecided, say that explicit human authorization is required.
- Preserve the prefix and draft status across updates. Remove them only after the stated condition is satisfied and the user authorizes making the PR mergeable. Passing CI alone is not authorization.

## Plans and task artifacts

- Do not commit agent implementation plans, progress ledgers, reports, or scratch files.
- Keep them in `.collie/` when a task provides it; otherwise use `.agent-work/` (ignored by Git).
- This applies to skill-generated plans too. Repository instructions take precedence over a skill's default plan location.
- Commit durable user documentation in `README.md` and `docs/`, not agent execution notes.

## Documentation

- Keep README command examples and introductions concise; put detailed workflows, diagrams, and action tables in `docs/USAGE.md` and link them from the README.
- When adding or changing a command, update the relevant usage text, completions, README example, and `docs/USAGE.md` entries in place. Do not reorder shared lists.
- Usage text lives in two places: a command's `collie help <command>` text is its own plain-text file `lib/usage/<command>.txt`; the overview line and the `HELP_COMMANDS` list stay in `lib/usage.sh`.

## Working in this repo

- tmux: experiment only on a private server, with `tmux -L <name>` on every call. Agents inherit `$TMUX`, and `$TMUX` overrides `TMUX_TMPDIR`, so setting `TMUX_TMPDIR` alone still reaches the user's server. Never run `kill-server` or `kill-session` on the user's server.
- collie: a command without a task id falls back to `$COLLIE_TASK`, the live task you run in. Pass explicit ids, or point `COLLIE_STATE_DIR` at a scratch directory. On live tasks run read-only commands only.
- bats: never kill bats recursively. Kill the one hung pid, or ask.
- bash 3.2 (macOS `/bin/bash`) is the target: no associative arrays, no `mapfile`. Brace a variable that sits before a UTF-8 glyph (`${n}●`, not `$n●`).
- A function `cmd_<name>` in `lib/cmd/*.sh` is the command `<name>`; there is no dispatch list to edit. README `Development` says where its help text goes.
- Clean up what a probe creates (tmux sessions, worktrees, agent trust records) and list any leftovers in `.collie/REPORT.md`.
- Fill in every section of `.github/PULL_REQUEST_TEMPLATE.md` in a PR body; `gh pr create --body` does not load it for you.
