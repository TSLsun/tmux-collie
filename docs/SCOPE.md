# Scope

> Run many coding agents in parallel, each in its own git worktree, managed
> from tmux — and see at a glance which one needs you.

You are the shepherd; collie rounds up the agents and barks when one needs you.

## Principles

1. **TUI only** — tmux + git + fzf. No GUI, no daemon.
2. **Agent-agnostic** — one tiny state protocol; adapters per agent CLI.
3. **Hands off your config** — collie prints snippets (`collie doctor`), it
   never rewrites agent settings files.
4. **Non-destructive** — never touches existing worktrees; removals go through
   git's own safety checks.
5. **No baked-in personal defaults** — everything is a `@collie-*` tmux option.

## In scope

| Module | Content | Phase |
|---|---|---|
| Worktree lifecycle | `new / ls / go / rm`; bare (`.bare`) and normal-clone layouts | P1 ✅ |
| Agent state protocol | `collie state <working\|waiting\|done\|error>` stored as tmux window option; stale-state cleanup after resurrect | P2 |
| tmux UI | status-bar glyphs, fzf dashboard, lazygit/focus popups, configurable keys | P2 |
| Agent adapters | claude, omp, codex, gemini, generic fallback (silence + exit) | P3 |
| `doctor` | dependency check, installed agents, hook snippets to paste | P3 |
| Task handoff | `.collie/TASK.md / NOTES.md / REVIEW.md` templates; `review / land / spike / park / gc` | P4 |
| Multi-agent | `--plan`, `review --agent`, `race` — file-based handoff only | P5 |
| Notifications | macOS `osascript`, Linux `notify-send`; opt-out | P2 |

## Non-goals

- Not an agent; never calls an LLM API.
- No orchestration bus or scheduler.
- Not a session manager (works alongside sesh / tmux-sessionizer).
- Never edits agent config files.
- No editor integration (separate project if ever).
- No secrets or agent-permission management.

## Requirements

- Required: tmux ≥ 3.2, git ≥ 2.31, bash ≥ 3.2, fzf (for pickers)
- Optional: lazygit, direnv, notify-send / terminal-notifier
