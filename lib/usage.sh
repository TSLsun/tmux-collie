# shellcheck shell=bash
# Sourced by bin/collie: the help text. usage is the overview; cmd_help
# prints a topic's details, or a command's from lib/usage/<command>.txt.

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
  brief               what waits on you and the command to act per task
  todo                fzf to-do of what waits on you; enter acts on a row
  next [-c client]    switch to the next task that waits on you
  show [<id>]         fields, TASK.md, repos, agent runs, events, REPORT.md
  history [-n] [pat]  finished tasks, newest first; searches TASK.md/REPORT.md
  note [-t <id>] [text...] record or print the latest one-line progress note
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
  handoff [<id>]      continue a claude/codex/omp run with a different agent
  send <id> <text>    type into an idle or waiting agent run and submit
  peek [<id>]         read the tail of an agent run's pane without switching
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
Read-only: ls brief show history review dash peek status doctor repos
workspaces, and -n.
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
          read-only                   ls brief show history review dash peek
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

# Prints the details of command $1, kept as plain text in lib/usage/$1.txt
# (read on demand, so nothing is parsed at startup); fails for an unknown one.
help_command() {
  case $1 in "" | *[!a-z-]*) return 1 ;; esac
  [ -f "$PLUGIN_DIR/lib/usage/$1.txt" ] || return 1
  cat "$PLUGIN_DIR/lib/usage/$1.txt"
}

# the public commands, in overview order
HELP_COMMANDS='new add drop ls brief todo next show history note log edit go dash set review verify spike race pick gc sync done archive reopen run handoff send peek ci pause adopt restore wait signal state status doctor repos workspaces'

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
