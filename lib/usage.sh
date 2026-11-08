# shellcheck shell=bash
# Sourced by bin/collie: the help text. usage is the overview; cmd_help
# prints a command's or a topic's details.

usage() {
  cat <<'EOF'
usage: collie <command> [args]
       collie help <command>    flags, side effects, examples (or: <command> -h)
       collie help concepts     ids, statuses, TASK.md/REPORT.md, side effects
       collie help workflows    common sequences
       collie help all          everything above, in one read

tasks:
  new [<id>]          create a task: branch + worktree per repo, tmux session
  add [<id>] -r repo  attach repos, or switch one's branch (-r repo:branch)
  drop [<id>] -r repo remove repos from a task, keeping their branches
  ls [-a]             list tasks: id, status, priority, session, agent, needs
  brief               what waits on you: one line per task, with the command
  show [<id>]         fields, TASK.md, repos, agent runs, events, REPORT.md
  history [-n] [pat]  finished tasks, newest first; searches TASK.md/REPORT.md
  log <5 fields>      append a row to the task's decision log (decisions.tsv)
  edit [<id>]         open the task's TASK.md in $EDITOR
  go [<id>]           switch to the task session (fzf picker if omitted)
  dash [-n]           fzf dashboard, most urgent first
  set [<id>] f=v...   set priority (P0..P3), title or after (task deps)
  review [<id>] [-p]  per-repo commits, diff stat, dirty files, REPORT.md
  verify [<id>]       run TASK.md's ## Verify sh blocks in each worktree
  spike <id> [-u]     new exp/<id> task with this worktree's uncommitted changes
  race <id> -n N      start N independent candidate tasks from one base
  pick <id> <n>       fast-forward the task branch to candidate n
  gc [-n]             finish tasks whose branches are merged into base
  sync [<id>...] [-n] merge base into active task branches and push them
  done [<id>]         accept: remove worktrees + session, keep branches
  archive [<id>]      abandon: same cleanup, status archived (unmerged ok)
  reopen [<id>]       undo done/archive: worktrees back on the kept branches

agents:
  run [<id>]          start an agent in a new window of the task session
  handoff [<id>]      continue a claude/codex run with the other agent
  send <id> <text>    type into an idle or waiting agent run and submit
  ci [<id>] [--send]  failing CI logs of its PRs; --send tells its agent
  pause <id>          ask an idle agent run to pause and leave RESUME.md
  adopt [<id>] [-y]   restart a hand-started agent under collie run
  restore [<id>] [-n] restart the agents lost with the tmux server
  wait [<id>]         block until a run reaches a state or signals done
  signal done         called by an agent: its run's current turn is done
  state <state>       called by agent hooks; no-op outside a collie window
  status              agent counts for the status bar (#{collie_status})

admin:
  doctor              dependencies, agents, and task/git/tmux consistency

discovery:
  repos               repos found under @collie-repo-roots / $COLLIE_REPO_ROOTS
  workspaces          named repo sets from ~/.config/collie/workspaces

Omitted <id> falls back to $COLLIE_TASK, set in every pane of a task session.
Read-only: ls brief show history review dash status doctor repos workspaces,
and -n.
Status: todo -> active -> review -> done | archived (derived; see concepts).
Agents: read .collie/TASK.md first, write .collie/REPORT.md when finished.
EOF
}

help_concepts() {
  cat <<'EOF'
concepts:

task      a slug id ([a-z0-9-], max 40) with a record in
          ~/.local/state/collie/tasks/<id>/ (TASK.md, repos.tsv, events.log,
          REPORT.md, decisions.tsv), one git worktree per repo on branch
          <type>/<id> (default type feat), and one tmux session <id> (a window
          per repo, plus one per agent run). A non-git directory joins as a
          folder: used in place, no branch, never removed.

<id>      every [<id>] may be omitted inside a task session: panes there
          export COLLIE_TASK=<id> and COLLIE_TASK_DIR, and collie falls back
          to $COLLIE_TASK. Outside one, an omitted id is an error, except
          `go` (fzf picker) and `new` on a tty (prompts). Agents started by
          `collie run` inherit it, so their own task needs no id; name the
          id to act on any other task.

<repo>    a name from `collie repos` or a path; repo:branch picks the branch.

status    derived on every ls/dash; only done and archived are stored.
            todo      created, no agent run yet
            active    at least one run; an agent is working or waiting, or
                      the last run left no REPORT.md
            review    agents quiet and REPORT.md written since the last run
                      started (scratch runs, run --scratch, not counted)
            done      accepted (done, gc): worktrees + session removed
            archived  abandoned (archive): same cleanup
          todo -> active -> review -> done | archived; review -> active when
          an agent works again; reopen takes done/archived back to active.

agent     per run: working, waiting (needs an answer), idle (turn over),
          exited, unknown (window gone). ls's needs column: answer,
          findings, review, reply, stalled, start, or -.

TASK.md   the contract, at .collie/TASK.md in each worktree (a symlink to the
          record): frontmatter (id, title, priority, status) and sections
          Objective, Context, Constraints, Acceptance Criteria, Verify, and
          Ship when shipping is on. The agent reads it first and asks if the
          Objective is empty. Humans edit it (`edit`, `new -m`); agents
          follow it.

REPORT.md written by the agent to .collie/REPORT.md when it finishes: what
          changed, how it was verified, open questions, the PR URL. Writing
          it moves the task to review; `review` and `show` print it.

RESUME.md written by a paused agent to .collie/RESUME.md (`pause`). `show`
          and the dashboard preview mention it; `run`, `handoff` and `adopt`
          point the next agent at it.

changes   creates branch + worktree   new, add, spike, reopen (worktree only)
          removes worktree + session  done, archive, gc
          creates/rebuilds session    new, go, reopen, spike
          starts agent windows        run, handoff, adopt, restore,
                                      new --run
          types into agent panes      send, pause, sync (conflicts)
          commits/pushes              sync (merge commit, push if upstream)
          fetches origin              new, add, done, gc, sync
          edits TASK.md               set, edit, done/archive/reopen (status)
          appends decisions.tsv       log
          runs your commands          verify (TASK.md ## Verify blocks)
          never deletes branches or the task record
          read-only                   ls brief show history review dash
                                      status doctor repos workspaces; -n
                                      variants (gc -n still fetches origin)
EOF
}

help_workflows() {
  cat <<'EOF'
workflows:

one-repo change, from inside the repo:
  collie new fix-retry -t fix -m 'retry 5xx on upload'   # branch fix/fix-retry
  collie run fix-retry                    # agent reads .collie/TASK.md
  collie ls                               # wait for status review
  collie review fix-retry                 # commits, diff stat, REPORT.md
  collie gc                               # after the merge (or: done fix-retry)

create and start in one step, agent ships the PR:
  collie new login -m 'add OAuth login' --ship --run

cross-repo task, a second agent on repo B:
  collie new deploy-v2 -r A -r B
  collie run deploy-v2
  collie run deploy-v2 -r B --agent codex -p 'fix CI'

as an agent inside a task session ($COLLIE_TASK set):
  collie show                             # contract, repos, runs
  collie review                           # what this task changed so far
  collie set priority=P1                  # only when asked
  # finish by writing .collie/REPORT.md; never run done/archive/gc unasked

after a PR lands, keep the other branches mergeable:
  collie sync -n                          # predict conflicts (read-only)
  collie sync                             # merge base in, push; agents resolve

closed by mistake:   collie reopen <id>
tmux server died:    collie restore -n; collie restore
EOF
}

# Prints the details of command $1; fails for an unknown one.
help_command() {
  case $1 in
    new)
      cat <<'EOF'
usage: collie new [<id>] [-r repo[:branch]]... [-w workspace] [-t type]
                  [--title text] [-m objective] [--from ref] [--edit]
                  [--no-window] [--ship|--no-ship] [--run] [--agent name]
                  [-p prompt] [--after ids] [-- args]

Create a task: its record and TASK.md, branch <type>/<id> and a worktree in
each repo (default: the current repo, or the current directory as a folder
outside git), and tmux session <id> with a window per repo.

  -r repo[:branch]  a repo by name or path, optionally its branch; repeatable
  -w workspace      every repo of a named workspace
  -t type           branch prefix (default feat): fix, docs, refactor, ...
  --title text      title (default: the id)
  -m objective      fill TASK.md's Objective
  --from ref        start the branches from ref (default: origin's default)
  --edit            open TASK.md in $EDITOR afterwards
  --no-window       no tmux session (collie go builds it later)
  --ship/--no-ship  add the commit/push/PR/CI rules to TASK.md (default:
                    $COLLIE_SHIP, @collie-ship, else off)
  --run             start the agent as `collie run` does; --agent, -p and
                    -- are passed to run and imply --run
  --after ids       tasks this one builds on (as `collie set <id> after=`);
                    repeatable

No id on a tty prompts for id, type, objective, ship, and (given an
objective) whether to start the agent. A bad id or type is asked again at
once (an uppercase one offers its lowercase); objective e writes TASK.md in
$EDITOR instead. If creation fails, the input is kept in new-draft under
the state dir and the next prompt offers it. Fetches origin first; prints
the primary worktree path. All-or-nothing: a failure removes the worktrees
and branches it created.

  collie new login -m 'add OAuth login' --run
  collie new deploy-v2 -r api -r web:release/v2
EOF
      ;;
    add)
      cat <<'EOF'
usage: collie add [<id>] -r repo[:branch]... [--from ref] [--no-window]
                  [--force]

Attach repos to an existing task, or switch an attached repo to another (new
or existing) branch with -r repo:branch; several -r, attaching and switching
mixed, apply all-or-nothing. A switch replaces the repo's worktree (and its
scratch worktrees) but keeps the old branch; it refuses a working or waiting
agent or the current directory there, and, unless --force, a dirty worktree
or a branch not merged into the default branch. --from is the base of new
branches. Fetches origin first.

  collie add deploy-v2 -r infra
  collie add deploy-v2 -r infra:release/v2 -r web
EOF
      ;;
    drop)
      cat <<'EOF'
usage: collie drop [<id>] -r repo... [--force]

Remove repos from a task, all-or-nothing: the worktree and its scratch
worktrees, links and repos.tsv row; the branch is kept. A folder only loses
its row and link. Refuses a working or waiting agent or the current
directory in it, and the task's last repo (use done or archive); unless
--force, also a dirty worktree or a branch not merged into the default branch.

  collie drop deploy-v2 -r infra
EOF
      ;;
    race)
      cat <<'EOF'
usage: collie race <id> -n N [--agent a,b,c] [--model m] [--effort e]
                  [-r repo] [-p prompt]

Create N child tasks <id>-1 through <id>-N with exp/<id>-<n> branches from
the same tip of the task branch. Each copies the parent's TASK.md and starts
one run. --agent assigns agents in order and cycles; omitted agents use the
default. --model, --effort and -p are passed to every run. A race uses one
git repo (the task's first repo, or -r); N must be 2..9. Existing child tasks
or exp branches are refused. Runs start only after every candidate is created;
partial creation is reported and any created branches/worktrees are retained.
Output gives each child task, run and path; use `collie wait <id>-<n> --done`
for each candidate.
EOF
      ;;
    pick)
      cat <<'EOF'
usage: collie pick <id> <n>

Fast-forward the task branch to race candidate <id>-<n>. The task worktree
must be clean and its branch must still be at the race base. The candidate
branches and tasks are kept; archive candidate tasks when finished.
EOF
      ;;
    ls)
      cat <<'EOF'
usage: collie ls [-a]

List live tasks, tab-separated: id, status, priority, session (* exists,
- none), agent (most urgent run state), repos, needs (answer, findings,
review, reply, stalled, start, blocked:<ids>, -). -a includes done and
archived. Read-only.
EOF
      ;;
    brief)
      cat <<'EOF'
usage: collie brief

What waits on you, most urgent first (answer, reply, findings, review,
stalled; then priority, id): one line per task with what it waits on and
the command to act. review shows REPORT.md's first line and the PR with its
state and CI from the cache the dashboard keeps (never calls gh). Prints
"nothing waits on you" when nothing does. Read-only.
EOF
      ;;
    show)
      cat <<'EOF'
usage: collie show [<id>]

Task fields, the TASK.md body, repos and branches, agent runs, the last
logged decision and recent events; for finished tasks also when, their
commits and REPORT.md. Read-only.
EOF
      ;;
    history)
      cat <<'EOF'
usage: collie history [-n] [pattern]

Finished tasks, newest first: date, status, id, title, branches, PR. pattern
searches TASK.md, REPORT.md and decisions.tsv. On a tty an fzf picker
(enter: show); -n prints the rows. Read-only.

  collie history -n oauth
EOF
      ;;
    log)
      cat <<'EOF'
usage: collie log <phase> <decision> <why> <evidence> <result>

Append a row to the task's decision trail, decisions.tsv in the task record
(.collie/decisions.tsv): ts, run, phase, decision, why, evidence, result.
The task is $COLLIE_TASK; ts (UTC) and run (the agent window's run, else -)
are stamped. The first row brings the header. Tabs and newlines in a cell
become spaces; a leading = + - or @ gets a ' prefix. Append-only: correct a
row with a new one. show and the dash preview print the last row; history
searches it. Never committed.

  collie log build 'header via ln' 'atomic under races' test/log.bats ok
EOF
      ;;
    edit)
      cat <<'EOF'
usage: collie edit [<id>]

Open the task's TASK.md in $EDITOR (default vi). For humans; agents edit
.collie/TASK.md directly only when asked.
EOF
      ;;
    go)
      cat <<'EOF'
usage: collie go [<id>]

Switch the client to the task session, rebuilding it (a window per repo) if
it is gone. No id: fzf picker ($COLLIE_TASK is not used). Outside tmux it
attaches; not on a tty it prints the primary worktree path instead.

  cd "$(collie go login)"
EOF
      ;;
    dash)
      cat <<'EOF'
usage: collie dash [-n]

fzf dashboard of live tasks, most urgent first, with a preview and actions
(? lists them). r asks which agent to run (the default first; a digit picks,
enter takes the default); R runs the default agent. u lists the selected
task's runs, newest first, with their exits and handoff/restore links: enter
goes to one's window, h hands a claude or codex run off to the other agent
(see handoff), esc goes back. -n prints the rows instead. -n is read-only.
EOF
      ;;
    set)
      cat <<'EOF'
usage: collie set [<id>] field=value...

Set fields in TASK.md's frontmatter: priority (P0..P3), title, after (the
task ids it builds on, space- or comma-separated; empty clears). A bare field
name reads its value from stdin. Values are single lines.

A todo task is blocked until each after: task is done or has a merged PR in
every repo (cached by the dashboard; gc marks merged branches done). Unknown and
archived deps keep it blocked; a cycle only warns. `collie run` on a blocked
task asks on a terminal, else warns and runs.

  collie set login priority=P0 title='OAuth login'
  collie set lead after='run-primitives collie-send'
EOF
      ;;
    review)
      cat <<'EOF'
usage: collie review [<id>] [-p]

Per repo: commits since the branch started, diff stat (-p: the full patch),
dirty files; then REPORT.md. Folders list files modified since the first
run. Read-only.
EOF
      ;;
    verify)
      cat <<'EOF'
usage: collie verify [<id>] [-r repo]

Run the fenced ```sh blocks under TASK.md's "## Verify" in each repo's
worktree (-r: only that repo), in order, each with `sh -e`, stdin from
/dev/null and your environment. A repo stops at its first failing block.
Output goes to the terminal and to verify/<time>-<repo>.log in the task
dir; a verify event records pass/fail, the exit code and the log. show,
review and the dash preview print the last result per repo; it does not
change the task's status. Exits non-zero if any repo fails. No blocks:
says so, exits 0, records nothing.

  collie verify login
  collie verify login -r api
EOF
      ;;
    spike)
      cat <<'EOF'
usage: collie spike <id> [-u] [--title text] [--no-window]

From a dirty worktree: create task <id> on branch exp/<id> carrying its
uncommitted tracked changes (-u: untracked files too). The source worktree
is left untouched. hooks/pre-push refuses to push exp/* branches.

  collie spike try-cache -u
EOF
      ;;
    gc)
      cat <<'EOF'
usage: collie gc [-n]

Run `done` on every live task whose branches all moved past their start and
are merged into base (squash merges count with git >= 2.38); skip the rest.
Fetches origin first. -n lists them without finishing (still fetches).
Each worktree is shown with a bucket (wip:N, scratch:N, unmerged, clean)
and its size, then the total reclaimed (-n: what clean ones would free).
EOF
      ;;
    sync)
      cat <<'EOF'
usage: collie sync [<id>...] [-n]

Merge the base branch (fetched first) into active task branches (all, or the
given ids), committing and pushing clean merges when the branch has an
upstream. On a conflict the merge is started and the task's agent is told
the files (typed in if idle, a new run if exited). Skips tasks whose agent
is working or waiting, dirty worktrees, and branches without own commits.
-n predicts only, including conflicts between tasks; read-only.
EOF
      ;;
    done)
      cat <<'EOF'
usage: collie done [<id>] [--force]

Accept a task: status done, worktrees and session removed, branches and the
record kept. Fetches origin first; refuses dirty worktrees or commits not in
the base branch. --force overrides both and discards uncommitted changes.
Folders only lose their session. A client viewing the session moves to
another one.
EOF
      ;;
    archive)
      cat <<'EOF'
usage: collie archive [<id>] [--force]

Abandon a task: like done, status archived, but unmerged commits are fine.
Refuses dirty worktrees; --force discards uncommitted changes. Branches and
the record are kept.
EOF
      ;;
    reopen)
      cat <<'EOF'
usage: collie reopen [<id>] [--no-window]

Undo done/archive: worktrees back on the kept branches, session rebuilt,
status live again (todo/active/review is derived as before).
EOF
      ;;
    run)
      cat <<'EOF'
usage: collie run [<id>] [--agent name] [--model m] [--effort e] [-r repo]
                  [-p prompt] [-s [-c client]] [--scratch] [-- args]

Start an agent in a new window of the task session, in the first repo's
worktree (-r: that repo's). The default prompt names the task and points the
agent at .collie/TASK.md and .collie/REPORT.md, and at .collie/RESUME.md
when a paused run left one. claude, codex, gemini and omp get state hooks
per run; any other command runs without them.

  --agent name   agent command (default: $COLLIE_AGENT, @collie-agent, else
                 claude)
  --model m      model for this run (claude --model, codex -m)
  --effort e     reasoning effort (claude --effort, codex
                 model_reasoning_effort); values are the agent's own
  -r repo        which repo's worktree to start in
  -p prompt      first prompt instead of the default; -p '' sends none
  -s             switch the current client (or -c client) to the window
  --scratch      start in a new scratch worktree: detached at the task
                 branch's head, next to the task worktree, removed with
                 its uncommitted changes by done/archive (gc lists it); for
                 reviewers whose repros must not touch the task worktree
  -- args        extra arguments for the agent

  collie run deploy-v2 -r B --agent codex -p 'fix CI'
EOF
      ;;
    handoff)
      cat <<'EOF'
usage: collie handoff [<id>] --from run --agent claude|codex --note file
                      [-r repo]

Continue claude run N with codex, or vice versa, in a fresh conversation:
a new run window like `collie run`, in the source run's repo (-r: another
repo of the task). Run numbers come from `collie show`.

  --from run      source run number (must be claude or codex)
  --agent name    destination agent, the other of claude/codex
  --note file     nonempty note: done, decisions, verification, open issues,
                  next action
  -r repo         start in that repo's worktree instead

Writes a read-only packet under the task record's handoffs/ (HANDOFF.md,
NOTE.md, TASK.md and REPORT.md snapshots) and prints its path; logs the
link between both runs. The source agent keeps running: stop it first if
edits could conflict. No branches are merged.

  collie handoff fix-retry --from 1 --agent codex --note handoff.md
EOF
      ;;
    send)
      cat <<'EOF'
usage: collie send <id> [-r repo | --run N] [--wait] <text>... | -f file

Type text into the agent of a `collie run` and press Enter, when it is idle
or waiting. Words are joined with spaces; several lines are pasted as one
(bracketed when the agent supports it), then submitted. The target is the
task's only live run; with several, pick one. Never types into an agent
started by hand or the shell left after a run exits.

  -r repo         the only live run in that repo
  --run N         run N (numbers from `collie show`)
  --wait          while the agent is working, wait for its turn to end
  -f file         send the file's contents (-: stdin)

Logs a `sent` event with the run and the text's first line.
Exit 0 sent; 2 the agent is working (not sent); 3 no live run (exited or
gone); 1 other errors, e.g. several live runs without --run.

  collie send fix-retry 'CI fails on macOS: see the log in the PR'
  collie send fix-retry --run 2 --wait -f review.md
EOF
      ;;
    ci)
      cat <<'EOF'
usage: collie ci [<id>] [--lines N] [--send [--run N] [--wait]]

For each open PR of the task's repos: the failing checks (name, URL) and, for
GitHub Actions, the end of each failed job's log (`gh run view --log-failed`)
without timestamps or ANSI escapes. Cancelled and timed-out checks are listed
as "no result, rerun" with the `gh run rerun` command: they are not failures.

  --lines N       log lines kept per job (default 80)
  --send          when a check fails, write the report to .collie/CI.md and
                  tell the agent run to read it, through `collie send`
  --run N         with --send: run N, as in `collie send`
  --wait          with --send: wait for the agent's turn to end

Never starts a run; only cancelled checks send nothing.
Exit 0 no failing checks; 2 pending and none failing; 3 at least one failing;
1 errors (no gh, no open PR). With --send and a failing check, as `collie send`:
0 sent; 2 the agent is working; 3 no live run; 1 other errors.

  collie ci fix-retry
  collie ci fix-retry --send --wait
EOF
      ;;
    pause)
      cat <<'EOF'
usage: collie pause <id> [-r repo | --run N] [-p request | -f file]

Ask the agent of a `collie run` to pause, through `collie send`: by default
to stop at a safe boundary, save its work and write a resume note to
.collie/RESUME.md, without pushing or opening a PR. Only an idle agent is
asked; a working or waiting one is left alone. The next `run`, `handoff` or
`adopt` points the new agent at the note.

  -r repo         the only live run in that repo
  --run N         run N (numbers from `collie show`)
  -p request      send this instead of the default request
  -f file         send the file's contents instead (-: stdin)

Exit 0 sent; 2 the agent is working or waiting (not sent); 3 no live run;
1 other errors.

  collie pause fix-retry
  collie pause fix-retry --run 2 -p 'Pause after the current test passes.'
EOF
      ;;
    adopt)
      cat <<'EOF'
usage: collie adopt [<id>] [-y]

Restart an agent you started by hand in the task's session (claude, codex,
omp) under collie run, resuming its conversation, so it gets hooks and
notifications. Asks first; -y does not. Codex requires an identifiable
dedicated process (started with --no-daemon, lsof installed). If the
conversation cannot be identified the process is left running.
EOF
      ;;
    restore)
      cat <<'EOF'
usage: collie restore [<id>] [-n]

After the tmux server died: restart every agent run that was live (all tasks
if no id), each resuming its own conversation (claude and codex by logged
session id, omp by the worktree's latest). Never guesses: runs without a
known conversation are skipped. -n lists them; read-only.
EOF
      ;;
    wait)
      cat <<'EOF'
usage: collie wait [<id>] [--run n] [--done | --state state] [--timeout s]

Block until a run (default: the latest) reaches a state: working, idle
(the default), waiting or exited. --done waits until the run's current
turn has signalled done (`collie signal done`) and the run is no longer
working. A restored run is followed to the run that replaced it. Polls
events.log and tmux every half second; read-only.

Exit 0 when reached, 1 on timeout (or a usage error), 2 when it cannot
happen any more (the run is gone; for --done, gone without the signal).

  collie wait fix-x --run 2 --done --timeout 3600
EOF
      ;;
    signal)
      cat <<'EOF'
usage: collie signal done

Run by an agent inside its collie run: logs that the run's current turn is
done (a run_signal event), for `collie wait --done`. The task and run come
from $COLLIE_TASK and $COLLIE_RUN, set for every collie run. The signal
counts until `collie send` prompts the run again (a sent event) and carries
over to the run `collie restore` starts in its place.
EOF
      ;;
    state)
      cat <<'EOF'
usage: collie state <working|waiting|idle|exited>

Called by agent hooks to record the run's state on its window; a no-op
outside a collie window. Not for direct use.
EOF
      ;;
    status)
      cat <<'EOF'
usage: collie status

Agent counts (waiting, idle, working) for the tmux status bar, as
#{collie_status}: collie runs; with `set -g @collie-status-manual on`,
also agents started by hand in any tmux session, whose state is guessed
from output silence (`set -g @collie-status-scope tasks`: only in task
sessions). The click menu marks guessed ages with ~.
Read-only. With the mouse on, click a count to pick one of its agents and
jump to it (tmux 3.4+).
EOF
      ;;
    doctor)
      cat <<'EOF'
usage: collie doctor

Check dependencies, agent CLIs, and that task records, worktrees, branches
and sessions agree. Read-only.
EOF
      ;;
    repos)
      cat <<'EOF'
usage: collie repos

Repos found under @collie-repo-roots / $COLLIE_REPO_ROOTS (':'-separated
globs): name, path. These names work for -r. Read-only.
EOF
      ;;
    workspaces)
      cat <<'EOF'
usage: collie workspaces

Named repo sets from ~/.config/collie/workspaces (lines `name: repo...`),
for new -w. Read-only.
EOF
      ;;
    help)
      cat <<'EOF'
usage: collie help [<command> | concepts | workflows | all]

The overview, or the details of a command or topic.
EOF
      ;;
    *) return 1 ;;
  esac
}

# the public commands, in overview order
HELP_COMMANDS='new add drop ls brief show history log edit go dash set review verify spike race pick gc sync done archive reopen run handoff send ci pause adopt restore wait signal state status doctor repos workspaces'

cmd_help() {
  local c
  case ${1:-} in
    "") usage ;;
    concepts) help_concepts ;;
    workflows) help_workflows ;;
    all)
      usage
      echo
      help_concepts
      echo
      help_workflows
      for c in $HELP_COMMANDS; do
        printf '\n%s\n\n' "--- collie $c ---"
        help_command "$c"
      done
      ;;
    *) help_command "$1" || die "help: no command or topic '$1' (see collie help)" ;;
  esac
}
