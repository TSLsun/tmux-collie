# Folder tasks — design draft

> Status: **proposal, not implemented.** Pick a direction (§4) and answer the
> open questions (§6) before any code is written.

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

## 5. Proposed shape for A (if chosen)

| Area | Behaviour |
|---|---|
| Discovery | Folders are given by path (`-r <path>`); not scanned. Optional `@collie-folder-roots` later if picking by name is wanted. `workspaces` file may list paths: `trips: ~/ClaudeHome/Travel\ Planning` (quoting TBD). |
| Name | Window/row name = slug of the basename (`Tokyo 2027-01` → `tokyo-2027-01`). Paths with spaces stored verbatim in `repos.tsv` (tab-separated, safe). |
| `.collie` link | Not created in folders (shared folder, no `info/exclude`, would collide between tasks). Agents get the absolute task dir. |
| `ls` / `dash` | Repo column shows the folder name; a `missing` marker if the path no longer exists. |
| `go` | Recreates the session with `-c <folder>`; `missing` → error naming the path. |
| `doctor` | Reports folder rows whose path is missing; skips git checks. |
| `add` | `-r <path>` adds a folder row to any task. |
| Status | Unchanged derivation. |

Estimated size: `new`/`add` path branch, `finish_task` skip, `gc` skip,
`review` mtime listing, prompt text, `doctor`; plus bats tests for each. No
new files.

## 6. Open questions

1. **Direction:** A, A-now-C-later, or B?
2. **Command shape:** reuse `-r <path>` (auto-detect non-git) or an explicit
   flag (`--dir <path>`)? Auto-detect is less to learn; explicit avoids
   silently making a folder task from a typo'd repo name.
3. **Overlap:** a second active task on the same folder (or a parent/child
   of it): warn, or refuse unless `--force`?
4. **`collie new` in a non-git cwd:** default to a folder task on cwd, or keep
   erroring ("not in a git repo") unless a path is given?
5. **Task-dir location for folder tasks:** keep the state dir only, or also
   let the task live inside the folder (e.g. `<folder>/.collie-task/`) so the
   contract sits next to the notes and syncs with iCloud/Dropbox?
