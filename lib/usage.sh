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
  add [<id>] -r repo  attach more repos to an existing task
  ls [-a]             list tasks: id, status, priority, session, agent, needs
  show [<id>]         fields, TASK.md, repos, agent runs, events, REPORT.md
  history [-n] [pat]  finished tasks, newest first; searches TASK.md/REPORT.md
  edit [<id>]         open the task's TASK.md in $EDITOR
  go [<id>]           switch to the task session (fzf picker if omitted)
  dash [-n]           fzf dashboard, most urgent first
  set [<id>] f=v...   set priority (P0..P3) or title
  review [<id>] [-p]  per-repo commits, diff stat, dirty files, REPORT.md
  spike <id> [-u]     new exp/<id> task with this worktree's uncommitted changes
  gc [-n]             finish tasks whose branches are merged into base
  sync [<id>...] [-n] merge base into active task branches and push them
  done [<id>]         accept: remove worktrees + session, keep branches
  archive [<id>]      abandon: same cleanup, status archived (unmerged ok)
  reopen [<id>]       undo done/archive: worktrees back on the kept branches

agents:
  run [<id>]          start an agent in a new window of the task session
  handoff [<id>]      continue a claude/codex run with the other agent
  adopt [<id>] [-y]   restart a hand-started agent under collie run
  restore [<id>] [-n] restart the agents lost with the tmux server
  state <state>       called by agent hooks; no-op outside a collie window
  status              agent counts for the status bar (#{collie_status})
  flow <sub>          multi-agent flows: ls, show, start, continue, stop, done
  wait [<id>]         wait for a run state, a flow step's done signal, a flow

admin:
  doctor              dependencies, agents, and task/git/tmux consistency

discovery:
  repos               repos found under @collie-repo-roots / $COLLIE_REPO_ROOTS
  workspaces          named repo sets from ~/.config/collie/workspaces

Omitted <id> falls back to $COLLIE_TASK, set in every pane of a task session.
Read-only: ls show history review dash status doctor repos workspaces, and -n.
Status: todo -> active -> review -> done | archived (derived; see concepts).
Agents: read .collie/TASK.md first, write .collie/REPORT.md when finished.
EOF
}

help_concepts() {
  cat <<'EOF'
concepts:

task      a slug id ([a-z0-9-], max 40) with a record in
          ~/.local/state/collie/tasks/<id>/ (TASK.md, repos.tsv, events.log,
          REPORT.md), one git worktree per repo on branch <type>/<id>
          (default type feat), and one tmux session <id> (a window per repo,
          plus one per agent run). A non-git directory joins as a folder:
          used in place, no branch, never removed.

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
                      started
            done      accepted (done, gc): worktrees + session removed
            archived  abandoned (archive): same cleanup
          todo -> active -> review -> done | archived; review -> active when
          an agent works again; reopen takes done/archived back to active.

agent     per run: working, waiting (needs an answer), idle (turn over),
          exited, unknown (window gone). ls's needs column: answer, review,
          reply, stalled, start, or -.

TASK.md   the contract, at .collie/TASK.md in each worktree (a symlink to the
          record): frontmatter (id, title, priority, status) and sections
          Objective, Context, Constraints, Acceptance Criteria, Verify, and
          Ship when shipping is on. The agent reads it first and asks if the
          Objective is empty. Humans edit it (`edit`, `new -m`); agents
          follow it.

REPORT.md written by the agent to .collie/REPORT.md when it finishes: what
          changed, how it was verified, open questions, the PR URL. Writing
          it moves the task to review; `review` and `show` print it.

changes   creates branch + worktree   new, add, spike, reopen (worktree only)
          removes worktree + session  done, archive, gc
          creates/rebuilds session    new, go, reopen, spike
          starts agent windows        run, handoff, adopt, restore,
                                      new --run
          commits/pushes              sync (merge commit, push if upstream)
          fetches origin              new, add, done, gc, sync
          edits TASK.md               set, edit, done/archive/reopen (status)
          never deletes branches or the task record
          read-only                   ls show history review dash status
                                      doctor repos workspaces; -n variants
                                      (gc -n still fetches origin)
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
                  [-p prompt] [--flow name] [-- args]

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
  --flow name       with --run: start that flow instead of one agent (see
                    collie help flow); its ship step ships, so TASK.md gets
                    no Ship section

No id on a tty prompts for id, type, objective, ship, and (given an
objective) whether to start the agent. Fetches origin first; prints the
primary worktree path. All-or-nothing: a failure removes the worktrees and
branches it created.

  collie new login -m 'add OAuth login' --run
  collie new deploy-v2 -r api -r web:release/v2
  collie new fix-x -m 'fix the parser crash' --flow review-loop --run
EOF
      ;;
    add)
      cat <<'EOF'
usage: collie add [<id>] -r repo[:branch]... [--from ref] [--no-window]

Attach more repos to an existing task: a branch + worktree and a session
window for each. Fetches origin first.

  collie add deploy-v2 -r infra
EOF
      ;;
    ls)
      cat <<'EOF'
usage: collie ls [-a]

List live tasks, tab-separated: id, status, priority, session (* exists,
- none), agent (most urgent run state), repos, needs (answer, review, reply,
stalled, start, -). -a includes done and archived. Read-only.
EOF
      ;;
    show)
      cat <<'EOF'
usage: collie show [<id>]

Task fields, the TASK.md body, repos and branches, agent runs and recent
events; for finished tasks also when, their commits and REPORT.md.
Read-only.
EOF
      ;;
    history)
      cat <<'EOF'
usage: collie history [-n] [pattern]

Finished tasks, newest first: date, status, id, title, branches, PR. pattern
searches TASK.md and REPORT.md. On a tty an fzf picker (enter: show); -n
prints the rows. Read-only.

  collie history -n oauth
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
(? lists them). u lists the selected task's runs, newest first, with their
exits and handoff/restore links: enter goes to one's window, h hands a claude
or codex run off to the other agent (see handoff), esc goes back. -n prints
the rows instead. -n is read-only.
EOF
      ;;
    set)
      cat <<'EOF'
usage: collie set [<id>] field=value...

Set fields in TASK.md's frontmatter: priority (P0..P3), title. A bare field
name reads its value from stdin. Values are single lines.

  collie set login priority=P0 title='OAuth login'
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
                  [-p prompt] [-s [-c client]] [-- args]

Start an agent in a new window of the task session, in the first repo's
worktree (-r: that repo's). The default prompt names the task and points the
agent at .collie/TASK.md and .collie/REPORT.md. claude, codex, gemini and
omp get state hooks per run; any other command runs without them.

  --agent name   agent command (default: $COLLIE_AGENT, @collie-agent, else
                 claude)
  --model m      model for this run (claude --model, codex -m)
  --effort e     reasoning effort (claude --effort, codex
                 model_reasoning_effort); values are the agent's own
  -r repo        which repo's worktree to start in
  -p prompt      first prompt instead of the default; -p '' sends none
  -s             switch the current client (or -c client) to the window
  -- args        extra arguments for the agent

  collie run deploy-v2 -r B --agent codex -p 'fix CI'
EOF
      ;;
    flow)
      cat <<'EOF'
usage: collie flow ls
       collie flow show <name>
       collie flow start <name> [<id>]
       collie flow continue [<id>]
       collie flow stop [<id>]
       collie flow done

A flow runs a task through agent steps without you carrying results between
them: e.g. claude implements, codex reviews, claude fixes in its own
conversation until the review is ok, then ships the PR. You are notified
when a step needs you, when the flow stops, and when it finishes.

Definitions, first match: <repo>/.collie/flows/<name> (untracked, in the
main checkout of the task's first repo), ~/.config/collie/flows/<name>,
then the built-in ones (review-loop, implement-review). One line per step:

  implement: role=implement agent=claude model=opus effort=high
  review:    role=review    agent=codex
  fix:       role=fix       resume=implement
  loop:      review fix max=2
  ship:      resume=implement

Roles: implement (writes REPORT.md), review (writes REVIEW.md starting
`verdict: ok` or `verdict: changes-needed`), fix (answers each finding in a
`## Review response` section of REPORT.md), ship (pushes, opens the PR
with the flow summary). resume=<step> continues that step's conversation:
typed into its pane while it is idle, else relaunched by conversation id.

  ls         flows by name, source and file; shadowed ones are marked
  show       a flow's steps, after checking it
  start      start a flow on a task; it is copied to the task record
  continue   go on after a stop (after the loop limit: review again)
  stop       stop advancing; agents keep running
  done       for agents: the current step is complete (or create the
             DONE file in the step's directory); the flow goes on when the
             agent stops

A step ends when its agent signals done and stops; an agent that stops
without the signal is waiting for you. Steps, prompts and artifacts are in
the task record's flow/ directory (collie show lists them).
EOF
      ;;
    wait)
      cat <<'EOF'
usage: collie wait [<id>] [--run n] [--for state] [--timeout seconds]

Wait until a run reaches a state (working, idle, waiting, exited; default
idle, run the latest), until the current flow step signals done (done, the
default while a flow runs), or until the flow finishes (flow). Exits 0 when
reached, 1 on timeout, 2 when it cannot happen any more (the run is gone,
the flow stopped).

  collie wait fix-x --for flow --timeout 3600
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
#{collie_status}: collie runs and agents started by hand in any tmux
session (`set -g @collie-status-scope tasks`: only in task sessions).
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
HELP_COMMANDS='new add ls show history edit go dash set review spike gc sync done archive reopen run handoff adopt restore state status flow wait doctor repos workspaces'

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
