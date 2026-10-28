# Cross-agent Handoff Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Continue Claude work with Codex and vice versa using explicit, preserved context and separate runs.

**Architecture:** Add `cmd_handoff` beside `cmd_run`; reuse the existing adapters and task worktrees. Store a unique read-only context packet per attempt and log successful source/destination linkage.

**Tech Stack:** Bash 3.2, tmux, Bats, shellcheck.

**Spec:** Approved proposal in `.collie/REPORT.md` (2026-10-29).

## Global Constraints

- Work only in the task worktree; never merge branches.
- Keep shared command lists in place.
- Preserve source runs, session IDs, and task context; never stop the source process.
- Tests use isolated tmux servers, never the live user's server.

## Review Focus

- Unknown or malformed source runs: reject before launching.
- Empty or unreadable note: reject before launching.
- Wrong repository: reject; default to the source repository.
- Failed launch: retain the packet for diagnosis, no success linkage.
- Repeated handoff: unique packet, no overwritten snapshots.

## Task 1: Handoff command and regression tests

**Files:** `lib/cmd/agents.sh`, new `test/handoff.bats`.

**Interfaces:** `cmd_handoff [id] --from run --agent claude|codex --note file [-r repo]`; `cmd_run` exposes `RUN_STARTED` after launch.

- [ ] Add tests with stub executables for both directions, packet preservation, source-session preservation, validation and failure events.
- [ ] Run `bats test/handoff.bats`; confirm missing-command failures.
- [ ] Implement note validation, event lookup, packet snapshots, new run launch and handoff linkage.
- [ ] Run the focused suite and lint; commit feature and tests together.

## Task 2: Documentation and delivery

**Files:** `README.md`, `lib/usage.sh`, `completions/_collie`, `.collie/REPORT.md`.

- [ ] Add command usage and examples in place; explain fresh conversations, source lifecycle and read-only packets.
- [ ] Run `make check`; report every failure.
- [ ] Review the diff and commit docs; push the task branch and create a PR using `GH`.
- [ ] Check CI, update REPORT.md with evidence, and stop for human review.
