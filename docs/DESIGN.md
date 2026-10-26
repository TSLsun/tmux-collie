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
| Task contract | — | — | `TASK.md` (goal, constraints, acceptance) |

---

## 2. Principles

1. **Thin layer.** git / lazygit own code, tmux owns terminals, agents own
   conversations. collie only tracks *what a task needs, where it lives, who is
   running, and what needs you*.
2. **Derive state; store only what can't be derived.** Ask git whether a
   worktree exists, ask tmux and the process table whether an agent is alive.
   Persist only goals, priority, the final outcome (done/archived) and
   history; task status is derived too (§3.2). If something can't
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

### 3.2 Task status (derived)

| Status | Meaning | Source |
|---|---|---|
| `todo` | Registered, no agent run yet | no `run_started` in events.log |
| `active` | In progress | at least one run |
| `review` | Waiting for you to check | no agent working or waiting, and REPORT.md modified at or after the last `run_started` |
| `done` | Accepted; worktrees removed, record kept | stored by `collie done` / `gc` |
| `archived` | Abandoned; worktrees removed, record kept | stored by `collie archive` |

Only `done` / `archived` are written to frontmatter. Other `status:` values in
older records (`todo`, `blocked`, …) and their `next:` field are ignored.
There is no manual status: an agent that is stuck says so by waiting, and a
human-kept "next" or notes file went unused in practice; the agent's REPORT.md
is the handoff.

`review` needs REPORT.md, not just quiet agents: an idle agent may have ended
its turn with a question in plain text, and agents commit as they go, so new
commits don't mean finished either (checking them would also cost a git call
per task on every dashboard refresh). An agent that skips REPORT.md leaves the
task `active`; when no agent is working or waiting, `show` and the dashboard
preview add `no REPORT.md since run N` so the task doesn't look stuck for no
reason. Ask the agent for the report, or `collie review` it anyway.

### 3.3 Agent run state (automatic)

| State | Source |
|---|---|
| `working` | hook: prompt submitted / agent started processing |
| `waiting` | hook: agent asks for permission or input |
| `idle` | hook: agent finished its turn (**not** task done) |
| `exited` | agent process no longer in its pane |
| `unknown` | session gone or state can't be determined |

Dashboard order: `waiting` > `idle` > task `review` > `working`
(the more it needs you, the higher it sorts).

### 3.4 Files

```
~/.config/collie/workspaces          # optional; one per line:  shop: api web infra
~/.config/collie/TASK.md             # optional; overrides the TASK.md body template
~/.local/state/collie/tasks/<id>/    # task record; survives worktree removal
  TASK.md        # contract + frontmatter (title, priority; status once finished)
  repos.tsv      # machine-owned: name<TAB>git common dir<TAB>branch<TAB>worktree path
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
priority: P2
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
  open an editor and fills `title` with the id; `--edit` opens the full contract,
  and `collie edit` reopens it later (`show` and the dash preview print it).
  A hand-edited `status:` line is ignored unless it is `done`/`archived`.
  An agent that finds an empty Objective should ask before starting.

---

## 4. Command interface

### Everyday

| Command | Purpose |
|---|---|
| `collie new <id> [-r repo[:branch]]... [-w workspace] [-t type] [--title ..] [--from ref] [--edit] [--no-window]` | Create task, worktrees and session; defaults to the current repo |
| `collie add [<id>] -r repo[:branch]...` | Pull another repo into an existing task |
| `collie ls [-a]` | Active tasks: id, derived status, priority, session, agent, repos |
| `collie go [<id>]` | Switch to the task session (fzf if no id); recreate it if missing |
| `collie run [<id>] [--agent X] [-r repo] [-p prompt] [-- args]` | Launch an agent in a new task window; records a run |
| `collie dash [-n]` | fzf dashboard, most urgent first; enter jumps to the most urgent agent window |
| `collie set [<id>] priority=P1 title="..."` | Update priority or title; a bare field reads stdin |
| `collie edit [<id>]` | Open TASK.md in `$EDITOR` (also `new --edit`, dash `e`, menu `e`) |
| `collie review [<id>] [-p]` | Per-repo commits, diff stat (`-p` patch), dirty files, then REPORT.md |
| `collie spike <id>` | New `exp/<id>` task from the current worktree, carrying its uncommitted tracked changes (`git stash create`); source untouched |
| `collie done [<id>] [--force]` | Accept: safety checks, then remove worktrees and session |
| `collie archive [<id>] [--force]` | Abandon: same cleanup |
| `collie gc [-n]` | Finish (`done`) tasks whose branches all moved past their start and are contained in base; dirty ones are skipped |

### Admin

| Command | Purpose |
|---|---|
| `collie show [<id>]` | Full task info, the TASK.md body, runs + recent events |
| `collie state <working\|waiting\|idle\|exited>` | Endpoint called by agent hooks; no-op outside a collie window |
| `collie status` | Agent counts for the status bar (`#{collie_status}`) |
| `collie doctor` | Dependencies, installed agents, task/git/tmux reconciliation; exits 1 on failures |
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
            │ t  terminal         │
            │ c  new task         │
            │ e  edit task        │
            │ v  review           │
            │ r  run agent        │
            │ d  done             │
            └─────────────────────┘
```

Terminal-level shortcuts (e.g. a `Cmd+…` key sending `prefix h h`) belong in
the user's own terminal config.

---

## 5. Agent adapters

One file per agent, `agents/<name>.sh`, sourced by `collie run`:

```bash
AGENT_HOOKS=1         # 1 if the agent reports state through `collie state`
agent_argv            # sets AGENT_ARGV from RUN_PROMPT (initial prompt) and
                      # RUN_DIRS (other worktrees + task dir, one per line)
```

An agent name without an adapter file runs as-is (generic adapter):
`collie run --agent aider -- --model x`. `collie run` checks the command
exists, then starts it through a wrapper (`collie _exec`) that records the
exit (`run_exited`, state `exited`) and leaves a shell in the window.

Run state lives in window options (`@collie_run`, `@collie_agent`,
`@collie_state`, `@collie_hooks`); `collie state` finds its window via
`$TMUX_PANE`, so hooks need no arguments besides the state. Transitions are
logged once (`agent_state run=N state=X`); repeats are dropped.

The claude adapter passes its hooks with `--settings '<json>'`, so they only
fire in sessions collie started and the user's settings stay untouched:
`UserPromptSubmit`/`PostToolUse` → working, `Notification`
(`permission_prompt|elicitation_dialog`) → waiting, `Stop` → idle,
`SessionEnd` → exited.

| Agent | State source | Confidence |
|---|---|---|
| claude | hooks via `--settings` (above) | working/idle/exited verified; waiting unverified |
| omp | extension `agents/omp.ts` loaded with `-e` (omp has no command hooks): `agent_start`/`tool_execution_end` → working, `tool_approval_requested` → waiting, `tool_approval_resolved` → working, `agent_end` → idle, `session_shutdown` → exited | fake agent only |
| codex | hooks via `-c hooks.<Event>=[...]`: `UserPromptSubmit`/`PostToolUse` → working, `PermissionRequest` → waiting, `Stop` → idle, `SessionEnd` → exited; trust once in `/hooks` | fake agent only |
| gemini | hooks in a generated settings file passed as `GEMINI_CLI_SYSTEM_SETTINGS_PATH`: `BeforeAgent`/`AfterTool` → working, `Notification` (`ToolPermission`) → waiting, `AfterAgent` → idle, `SessionEnd` → exited; hooks print `{}` | fake agent only |
| generic | wrapper exit + `window_activity`: working → idle after `@collie-silence` s (30) without output | always works, coarse; no `waiting` |

Agents that strip the hook environment (gemini) lose `$TMUX_PANE`;
`collie state` then walks parent processes until it reaches a pane's process.
The `collie _exec` wrapper waits until `collie run` has tagged the window before
starting the agent, so the first hook never races the tagging.

`exited` / `unknown` are also derived: a run whose window is gone (no
`run_exited` logged) is `exited` while the session exists and `unknown` once the
session is gone (e.g. `kill-server`).

Notifications fire on → `waiting` and on `working` → `idle`, skipped for the
active window of an attached session. `@collie-notify`: `on` (osascript /
notify-send), `off`, or a command receiving title and body.

Known gap: folder-trust dialogs on a new worktree (Claude; Gemini asks twice,
once for the folder and once for `--include-directories`) are not reported by
any hook, so the run shows `working` until they are answered.

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

### P2 — Agent runtime ✅
**Goal:** know what every agent is doing.
- `run`, `state`; claude adapter + generic adapter.
- Derive `exited` / `unknown`; log each run as events.
- Status-bar counts (`#{collie_status}`); notifications on `waiting` / `idle`
  (macOS / Linux, opt-out).
- **Acceptance:**
  - three concurrent tasks show correct state transitions (fake agent script
    driving the hooks)
  - killing the agent → `exited`; `kill-server` → `unknown`
  - *manual:* one working → idle cycle with a real Claude Code session

### P3 — Dashboard & interaction ✅
**Goal:** from any pane, reach the agent that needs you in two keystrokes.
- fzf dashboard (ordering per §3.3; preview shows status, runs, diff stat).
- `prefix h` menu, lazygit popup, `set`, zsh completion
  (`completions/_collie`).
- Docs: terminal key mapping examples.
- **Acceptance:** dashboard ordering tests; *manual* day-to-day check.

### P4 — More agents & doctor ✅
- omp, codex, gemini adapters.
- `doctor`: dependency versions, installed agents, task/git/tmux
  reconciliation (hooks are injected per run, so there are no snippets to
  install).
- **Acceptance:** each adapter passes working → idle with a fake agent;
  *manual* check per real agent.

### P5 — Review & lifecycle ✅
- `review` (multi-repo diff + REPORT), `gc`.
- `spike`: branch off with uncommitted changes into `exp/*` without touching
  the source worktree (`git stash create`).
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
