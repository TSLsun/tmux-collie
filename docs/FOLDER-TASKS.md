# Folder tasks — design draft

> Status: **option A chosen and implemented** (decisions in §6). §4 keeps the
> rejected options for the record.

## 1. Problem

collie's unit of work is a task = `TASK.md` + one git worktree per repo + one
tmux session. Everything that is not a git repo is out of reach, yet the
original "workspace" idea was broader: a place where an agent works on a goal
and you see at a glance when it needs you.

Concrete case: `~/ClaudeHome` (not a git repo).

```
~/ClaudeHome/
  CLAUDE.md, MEMORY.md            # routing + memory, read by every agent run
  Travel Planning/
    CLAUDE.md, MEMORY.md
    Tokyo 2026-07/  Tokyo 2027-01/  Yilan 2026-07/
  Housing/
    CLAUDE.md, MEMORY.md
    buy-watch/  rent-watch/
  Career/  Finance/  Learning/ ...
```

Things a task here looks like: "plan Tokyo 2027-01", "compare rent-watch
listings this month". The value collie adds is unchanged — a contract
(`TASK.md`), a session, agent state, the dashboard, a REPORT.md handoff — but
there are no branches, no merge, nothing to diff against.

Two properties of this folder shape the design:

- **Agents depend on the real path.** Claude Code loads `CLAUDE.md` from the
  working directory *and its parents*, and these folders keep `MEMORY.md`
  that the agent is told to update. A copy elsewhere loses the parent
  `CLAUDE.md` and writes memory to the wrong place.
- **Folder names contain spaces** (`Travel Planning`) and are not slugs.

## 2. Prior art

| Tool | Non-git support | Model |
|---|---|---|
| **Orca** (stablyai/orca) | Yes: "Open as Folder" registers a `kind: folder` project; a **folder workspace** is a non-git context with its own terminals, status and sidebar row. No isolation — it *is* the folder. | Folder workspaces can be the **parent** of git worktrees created from inside them (`worktree create --parent-worktree folder:<id>`), so one ticket spanning several repos reads as one unit. |
| Orca issues | — | Demand is real: #15939 "why must every workspace be a worktree? some folders are for analysis/reports", #6913 / #13358 (CLI `repo add --kind folder`). Pain points: renamed/moved folders break terminals (#19208, #23899), folder workspaces missed by sort/filter/board code paths written for worktrees (#27236, #33386, #18198). |
| Conductor, claude-squad, cmux-style worktree managers | No (git worktree per agent is the whole point) — *from project docs, not re-checked here* | Isolation via worktree. |
| Plain tmux session managers (sesh, tmuxinator, `tmux new -c <dir>`) | Yes | A session per directory; no task contract, no agent state. |

Lessons taken:

1. Orca's answer is **in place, no isolation**, and that is what users asked
   for. Isolation for non-git folders was not something anyone requested.
2. Bolting a second kind onto worktree-shaped code leaks: every listing,
   sort and filter path must handle it. collie should make the folder a
   *row kind in the existing repo list*, not a parallel concept, so `ls`,
   `dash`, `go`, `run` keep one code path.
3. Store the path, detect when it vanished, report it (`unknown` /
   `missing`) instead of failing obscurely.

## 3. What stays the same

Regardless of option: task id/slug, `TASK.md`, `events.log`, task dir under
`~/.local/state/collie/tasks/<id>/`, one session per task, agent adapters and
hooks, derived status (`todo` → `active` → `review` from runs and REPORT.md
mtime; none of it uses git), dashboard ordering, notifications, `edit`,
`set`, `show`. These are why folder tasks are cheap to add.

What has to change is everything that assumes a branch: `new`/`add`
(create worktree), `done`/`archive` (dirty + merged checks, worktree removal),
`gc` (merged detection), `review` (commits, diff), `spike`, `doctor`
(git/worktree reconciliation), and the `.collie` link + `info/exclude`.

## 4. Options

### A. In-place folder task (recommended)

A task row may point at an existing directory instead of a worktree. Nothing
is created or deleted in it.

- `repos.tsv` row: `name<TAB>-<TAB>-<TAB>/abs/path` (`-` = no git dir, no
  branch). Mixed tasks (folder + repo worktrees) fall out for free, like
  Orca's folder parent.
- `collie new plan-tokyo -r ~/ClaudeHome/'Travel Planning/Tokyo 2027-01'`, or
  `collie new plan-tokyo` from a non-git cwd → folder task on cwd.
- `done` / `archive`: mark the outcome, kill the session. **No checks, no
  removal** — there is nothing collie created to lose. Folder untouched.
- `gc`: ignores folder rows (a folder-only task is never auto-finished).
- `review`: REPORT.md, plus files under the folder modified since the first
  `run_started` (`find -newer`), capped. No diff.
- `spike`: refuses on folders.
- `run`: agent starts in the real folder, so `CLAUDE.md`/`MEMORY.md` chains
  work. Task dir passed as an extra dir (already done via `RUN_DIRS`); prompt
  uses `$COLLIE_TASK_DIR/TASK.md` (absolute) instead of `.collie/TASK.md`.

Trade-offs:
- \+ Smallest change (~one row kind, a few `case` branches). Matches how the
  folder is used today and what Orca users asked for.
- \+ Agents see the real context (parent `CLAUDE.md`, memory files).
- − No isolation: two tasks on the same folder share files; two agents can
  edit the same note. Mitigation: point tasks at subfolders, and `new` warns
  (or refuses, see Q3) when an active task already owns that path or a parent
  of it.
- − No undo / diff: what the agent changed is only visible via mtimes and
  REPORT.md.

### B. Scratch copy per task

collie copies (or creates empty) a work dir per task, e.g.
`<task dir>/work/`, seeded from a source folder; `done` offers to copy results
back.

- \+ Real isolation; parallel tasks cannot collide; `archive` = delete scratch.
- − Breaks the `CLAUDE.md` parent chain and `MEMORY.md` writes (wrong place).
- − "Copy back" is a merge without git: conflicts, deleted files, which side
  wins. A new failure mode collie would own.
- − Duplicates data (PDFs, exports) per task.
- Verdict: wrong fit for living notes folders; only makes sense for
  throwaway "analysis" tasks, which can simply use a fresh empty folder in A.

### C. In-place + shadow git for checkpoints

Option A, plus collie keeps a hidden git repo for the folder
(`GIT_DIR=<task dir>/shadow.git`, `GIT_WORK_TREE=<folder>`), snapshotting at
`run_started` and on `done`.

- \+ `review` gets a real diff ("what did the agent change in my notes"), and
  a way to restore a file.
- − Snapshots large binaries (PDFs, images) unless filtered; disk + time cost
  on every run.
- − Two tasks on one folder = two shadow repos disagreeing; still no
  isolation.
- − A second source of truth about the folder, against principle 2.
- Verdict: worth it only if "what changed" turns out to matter after using A.
  A can grow into C later without breaking the data model (the shadow repo
  lives in the task dir).

## 5. Shape of A (as implemented)

| Area | Behaviour |
|---|---|
| Discovery | Folders are given by path (`-r <path>`, or the cwd of `new`); not scanned, so a bare name still has to be a repo under `@collie-repo-roots` (a typo'd repo name fails instead of becoming a folder). Workspace entries are whitespace-split, so a folder path with spaces cannot go in `workspaces`. |
| Name | Row/window name = slug of the basename (`Tokyo 2027-01` → `tokyo-2027-01`). Path stored verbatim in `repos.tsv` (tab-separated, spaces are safe). `-r <folder>:<branch>` is refused. |
| `.collie` link | Not created in folders (shared, no `info/exclude`, would collide between tasks). The default `run` prompt names `$TASK_DIR/TASK.md` and `REPORT.md` by absolute path; the task dir is already passed to the agent as an extra dir. |
| Overlap | `new`/`add` warn when another unfinished task has the same folder, a parent or a child of it. |
| `done` / `archive` | No dirty/merged checks, no removal, no "cd elsewhere" check for folder rows; repo rows in the same task are handled as before. |
| `gc` | Ignores folder rows; a task needs at least one merged repo, so a folder-only task is never finished by `gc`. |
| `review` | `== <name>  folder  <path>`, then files modified since the first `run_started` (`find -newermt`), then REPORT.md. |
| `show` / `dash` preview / `doctor` | Folder rows print as folders; `doctor` reports a missing folder, skips git checks. |
| `add` | A repo added to a folder-first task gets `feat/<id>`. |
| Status | Unchanged derivation. |

## 6. Decisions

1. **Direction:** A (in place). C stays possible later without changing the
   data model.
2. **Command shape:** auto-detect: `-r <path>` that is not a git repo, and
   `new` in a non-git cwd, make a folder.
3. **Overlap:** warn, allow.
4. **Task dir:** state dir only (`~/.local/state/collie/tasks/<id>/`); the
   folder stays clean.
