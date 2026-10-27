
## Objective

## Context

## Constraints
- Work only inside this task's worktrees; never touch the main checkout.
- Do not merge, rebase onto main, or delete branches.
- Keep edits to shared lists (README command list, usage, completions)
  minimal and in place; don't reorder them. Parallel tasks conflict there.
- Ask before making design decisions that are hard to reverse.
- You run inside the user's live tmux ($TMUX overrides TMUX_TMPDIR): experiment
  only on a private server (`tmux -L <name>` on every call); never kill-server or
  kill-session on the user's server.

## Acceptance Criteria

## Verify
