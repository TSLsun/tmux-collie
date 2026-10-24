# tmux-collie — Design

> Status: draft v0.2 · Phase markers below track implementation progress.

---

## 1. Positioning

**One line:** manage *tasks* from tmux — each task gets its own git worktrees
(possibly across several repos), its own tmux session, swappable coding agents,
and a task contract that both humans and agents can read — and see at a glance
which task needs you.

**Metaphor:** you are the shepherd (decide, accept); collie is the sheepdog
(gathers the agents, watches them, barks when one needs you).

**For:** developers who stay in the terminal and run several coding agents in
parallel across several repositories.

**How it differs from nearby tools**

| | Agent multiplexers (e.g. herdr) | Desktop agent IDEs | collie |
|---|---|---|---|
| Terminal | Replaces tmux | GUI | Builds on tmux |
| Unit of work | pane / agent | worktree | **task** (worktrees across repos) |
| Task contract | — | — | `TASK.md` (goal, constraints, acceptance, next) |

---

## 2. Principles

1. **Thin layer.** git / lazygit own code, tmux owns terminals, agents own
   conversations. collie only tracks *what a task needs, where it lives, who is
   running, and what's next*.
2. **Derive state; store only what can't be derived.** Ask git whether a
   worktree exists, ask tmux and the process table whether an agent is alive.
   Persist only goals, priority, human status and history. If something can't
   be determined, report `unknown` — never pretend.
3. **Task ≠ agent run.** An agent exiting doesn't finish a task; switching or
   retrying agents stays within the same task.
4. **Non-destructive.** Never touch the main checkout, never merge, never
   delete branches; check for uncommitted and unmerged work before removing a
   worktree.
5. **Hands off user config.** Agent hook settings are printed as snippets
   (`collie doctor`), never rewritten.
6. **No runtime dependencies** beyond bash 3.2, git, tmux and fzf.

### Non-goals

- Not an agent; never calls an LLM API.
- No orchestration bus, scheduler, or automatic agent restarts.
- Doesn't replace lazygit (diff/commit) or session managers like sesh.
- Doesn't synchronise cross-repo dependencies (subtrees, version bumps); it
  only guarantees the related worktrees live in one task with known paths.

---

## 3. Data model

```
Task 1 ── N Worktree   (one per repo; derived from git, task stores repo + branch)
Task 1 ── N AgentRun   (one per launch; runtime state in tmux window options)
Task 1 ── N Event      (append-only log)
Repo                   (auto-discovered under configured roots; no registration)
Workspace              (optional named repo set; a shortcut when creating tasks)
```

### 3.1 Task id and branches

- **Ids are slugs:** `[a-z0-9-]`, max 40 chars, no leading `-`. Put a ticket key
  first if you have one (`abc-123-fix-retry`).
- **Default branch:** `<type>/<id>`, type defaults to `feat` (`-t fix`, …).
- Per-repo override: `-r repo:branch`.

### 3.2 Task status (mostly human-driven)

| Status | Meaning | Set by |
|---|---|---|
| `todo` | Registered, not started | `collie new --todo` |
| `active` | In progress | `new` / `run` |
| `blocked` | Waiting on an external condition or a decision | manual |
| `review` | Waiting for you to check | manual, or agent after writing its report |
| `done` | Accepted; worktrees removed, record kept | `collie done` |
| `archived` | Abandoned; worktrees removed, record kept | `collie archive` |

### 3.3 Agent run state (automatic)

| State | Source |
|---|---|
| `working` | hook: prompt submitted / agent started processing |
| `waiting` | hook: agent asks for permission or input |
| `idle` | hook: agent finished its turn (**not** task done) |
| `exited` | agent process no longer in its pane |
| `unknown` | session gone or state can't be determined |

Dashboard order: `waiting` > `idle` > task `review` > task `blocked` > `working`
(the more it needs you, the higher it sorts).

### 3.4 Files

```
~/.config/collie/workspaces          # optional; one per line:  shop: api web infra
~/.config/collie/TASK.md             # optional; overrides the TASK.md body template
~/.local/state/collie/tasks/<id>/    # task record; survives worktree removal
  TASK.md        # contract + frontmatter (status, priority, next)
  repos.tsv      # machine-owned: name<TAB>git common dir<TAB>branch<TAB>worktree path
  NOTES.md       # progress notes (P5)
  REPORT.md      # agent's final report (P5)
  events.log     # append-only: ts<TAB>event<TAB>k=v ...
  repos/<repo> -> worktree path (symlink)

<repo worktree>/.collie -> ~/.local/state/collie/tasks/<id>
```

- Worktrees stay next to their repo: `<root>/<slug>` for a bare layout
  (`<root>/.bare`), `<repo>.worktrees/<slug>` for a normal clone.
- `.collie` is added to the repo's `$GIT_COMMON_DIR/info/exclude` — no global
  gitignore changes, never committed.
- Task sessions export `COLLIE_TASK` and `COLLIE_TASK_DIR` so hooks and agents
  know which task they belong to.

### 3.5 `TASK.md`

```markdown
---
id: deploy-v2
title: Ship v2 of api and bump it in infra
status: active
priority: P2
next: find where infra reads the api version
created: 2026-01-01
---
## Objective
## Context
## Constraints
## Acceptance Criteria
## Verify
```

- Frontmatter is flat `key: value`, parseable with awk.
- The repo list lives in `repos.tsv`, not frontmatter: humans edit `TASK.md`,
  the tool reads `repos.tsv`, and neither can break the other.
- **Lightweight by default:** only frontmatter is required. `collie new` doesn't
  open an editor and fills `title` with the id; `--edit` opens the full contract.
  An agent that finds an empty Objective should ask before starting.

---

## 4. Command interface

### Everyday

| Command | Purpose |
|---|---|
| `collie new <id> [-r repo[:branch]]... [-w workspace] [-t type] [--title ..] [--from ref] [--todo] [--edit] [--no-window]` | Create task, worktrees and session; defaults to the current repo |
| `collie add [<id>] -r repo[:branch]...` | Pull another repo into an existing task |
| `collie ls [-a]` | Active tasks: id, status, priority, session, repos, next |
| `collie go [<id>]` | Switch to the task session (fzf if no id); recreate it if missing |
| `collie run [<id>] [--agent X]` | Launch an agent in a new window; records a run (P2) |
| `collie set [<id>] status=review next="..."` | Update status or next action (P3) |
| `collie review [<id>]` | Per-repo diff stat + REPORT.md; key to open lazygit (P5) |
| `collie done [<id>] [--force]` | Accept: safety checks, then remove worktrees and session |
| `collie archive [<id>] [--force]` | Abandon: same cleanup |
| `collie gc` | Pick tasks whose branches are merged and archive them (P5) |

### Admin

| Command | Purpose |
|---|---|
| `collie show [<id>]` | Full task info + recent events |
| `collie state <working\|waiting\|idle>` | Endpoint called by agent hooks (P2) |
| `collie doctor` | Dependencies, installed agents, hook snippets, task/git/tmux reconciliation (P4) |
| `collie repos` / `collie workspaces` | What collie can see |

An omitted `<id>` falls back to `$COLLIE_TASK`.

### tmux key binding

collie claims **one** prefix key, `h` (**h**erd; unbound in stock tmux,
override with `@collie-key`). It opens a `display-menu` that lists every action,
so nothing has to be memorised:

```
prefix h →  ┌ collie ─────────────┐
            │ h  dashboard        │   ← prefix h h: the most used action
            │ g  lazygit          │
            │ n  notes / next     │
            │ r  run agent        │
            │ v  review           │
            │ s  set status       │
            │ d  done             │
            └─────────────────────┘
```

Terminal-level shortcuts (e.g. a `Cmd+…` key sending `prefix h h`) belong in
the user's own terminal config.

---

## 5. Agent adapters

One file per agent, `agents/<name>.sh`, implementing:

```bash
agent_detect          # is it installed (command -v)
agent_launch_cmd      # command to start it in a worktree, pointing it at .collie/TASK.md
agent_extra_dirs      # how to grant access to the task's other worktrees (claude: --add-dir)
agent_hook_snippet    # config snippet printed by `collie doctor`
```

| Agent | State source | Confidence |
|---|---|---|
| claude | hooks: `UserPromptSubmit` → working, `Notification` → waiting, `Stop` → idle | known |
| omp | to be researched | P4 |
| codex | `notify` (turn complete → idle) + silence detection | unverified |
| gemini | hooks, if available | unverified |
| generic | tmux `monitor-silence` + process exit | always works, coarse |

`exited` / `unknown` don't come from hooks; `ls` derives them from window
existence and the pane's foreground process (`#{pane_current_command}`).

---

## 6. Phases

Each phase is usable on its own. Every acceptance item has an automated test
unless marked *manual*.

### P0 — Foundation ✅
- tpm entry point, PATH injection, bats + isolated tmux server harness,
  shellcheck, CI config.

### P1 — Task model ✅
- Repo discovery (`@collie-repo-roots` / `$COLLIE_REPO_ROOTS`), bare and
  normal-clone layouts.
- `new / add / ls / show / go / done / archive`, `repos / workspaces`;
  `-w`, `-t`, slug validation.
- Task dir, lightweight `TASK.md`, `repos.tsv`, `events.log`; one session per
  task, one window per repo; `.collie` link + `info/exclude`.
- **Acceptance:**
  - single-repo and two-repo tasks don't interfere (branches, files, sessions)
  - after `tmux kill-server`, `ls` still lists tasks and `go` rebuilds the session
  - failure midway (e.g. second repo can't be created) rolls back worktrees and
    branches already created
  - a branch already checked out elsewhere is rejected up front, naming the task
  - `done` / `archive` refuse dirty worktrees or commits not in the base branch
  - `new -w` creates all repos of a workspace; `add` extends an existing task
  - small change in two commands: `collie new fix-typo` → commit, merge → `collie done`

### P2 — Agent runtime
**Goal:** know what every agent is doing.
- `run`, `state`; claude adapter + generic adapter.
- Derive `exited` / `unknown`; log each run as events.
- Status-bar glyphs; notifications on `waiting` / `idle` (macOS / Linux, opt-out).
- **Acceptance:**
  - three concurrent tasks show correct state transitions (fake agent script
    driving the hooks)
  - killing the agent → `exited`; `kill-server` → `unknown`
  - *manual:* one working → idle cycle with a real Claude Code session

### P3 — Dashboard & interaction
**Goal:** from any pane, reach the agent that needs you in two keystrokes.
- fzf dashboard (ordering per §3.3; preview shows next, diff stat, NOTES tail).
- `prefix h` menu, lazygit / NOTES popups, `set`, zsh completion.
- Docs: terminal key mapping examples.
- **Acceptance:** dashboard ordering tests; *manual* day-to-day check.

### P4 — More agents & doctor
- omp, codex, gemini adapters.
- `doctor`: dependency versions, hook snippets, task/git/tmux reconciliation.
- **Acceptance:** each adapter passes working → idle with a fake agent;
  *manual* check per real agent.

### P5 — Review & lifecycle
- `review` (multi-repo diff + REPORT), `gc`.
- `spike`: branch off with uncommitted changes into `exp/*` without touching
  the source worktree (`git stash create`).
- `park`: write the next action into NOTES and frontmatter.
- Optional pre-push hook snippet blocking `exp/*`.
- **Acceptance:** after `spike` the source worktree's `git status` is unchanged;
  `review` shows diffs from two repos.

### P6 — Multi-agent collaboration (only once P1–P5 are in daily use)
- A second run in the same task (e.g. one agent plans, another implements).
- `review --agent X`: non-interactive review written to REVIEW.md.
- `race`: one TASK.md handed to N agents, one worktree each.

---

## 7. Decision records

### ADR-1: bash + files, not Python + SQLite
- **Context:** a database was proposed to handle concurrent state writes from
  several agents.
- **Decision:** bash 3.2 + plain files.
- **Why:**
  - Writes are tiny. Agent state goes into tmux options (the tmux server
    serialises them); events are single-line appends (`>>` writes under
    PIPE_BUF are atomic). Nothing needs transactions.
  - Per principle 2, most state is derived; a database would become a second
    source of truth needing reconciliation.
  - ~90% of the work is calling git and tmux; bash is the most direct fit and
    adds no runtime.
- **Revisit when:** the core exceeds ~1500 lines, cross-task queries get
  complex, or frontmatter parsing becomes fragile → port the core to Python
  (stdlib only), keeping the CLI stable.

### ADR-2: worktrees stay next to their repo
- Existing habits and tools (editors, lazygit, shell history) rely on these
  paths. Cross-repo tasks are tied together by the task dir's symlinks instead.

### ADR-3: one tmux session per task
- Switching tasks = switching sessions. Cost: more sessions, handled by the
  dashboard and fzf.

### ADR-4: one prefix key + menu
- Plugins that bind many keys collide with user configs. A single key opening a
  self-documenting menu minimises collisions and memorisation.

---

## 8. Risks and safeguards (each backed by a test)

| Risk | Safeguard |
|---|---|
| Creation fails midway | Track created worktrees/branches; roll back in reverse |
| Branch already used by another worktree | Preflight check; reject and name the owning task |
| Losing valuable work | `done` / `archive` refuse dirty or unmerged; `--force` required; branches always kept |
| Modifying the main checkout | Only ever `worktree add`; never checkout inside existing worktrees |
| State drifting from reality | Derive on every `ls`; show `unknown` when unsure |
| Agent sandbox rejects symlinks | Launch in the primary repo + adapter `extra_dirs`; symlinks are a fallback |
