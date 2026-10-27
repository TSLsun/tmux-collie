# shellcheck shell=bash
# Sourced by bin/collie: the usage text.

usage() {
  cat <<'EOF'
usage: collie <command> [args]

tasks:
  new [<id>] [-r repo[:branch]]... [-w workspace] [-t type] [--title text]
           [-m objective] [--from ref] [--edit] [--no-window]
           [--ship|--no-ship]
                      create a task: worktree per repo + tmux session;
                      no id on a tty prompts for id, type, objective, ship;
                      --ship adds commit/push/PR/CI rules to TASK.md
                      (default: $COLLIE_SHIP, @collie-ship, else off)
  add [<id>] -r repo[:branch]... [--from ref] [--no-window]
                      attach more repos to an existing task
  ls [-a]             list tasks: id, status, priority, session (*|-), agent, repos;
                      status is todo (no run yet), active, review (agent done,
                      REPORT.md written since its run started), done, archived
  show [<id>]         task fields, TASK.md body, repos, agent runs and recent events
  edit [<id>]         open the task's TASK.md in $EDITOR
  go [<id>]           switch to the task session (fzf picker if omitted);
                      outside tmux and not a tty, print the primary worktree path
  dash [-n]           fzf dashboard, most urgent first; -n prints the rows
  set [<id>] field=value...   priority (P0..P3), title; a bare field name
                      reads stdin
  review [<id>] [-p]  per-repo commits, diff stat (-p: patch), dirty files, REPORT.md
  spike <id> [--title text] [--no-window]
                      new exp/<id> task from the current worktree, carrying its
                      uncommitted changes (the source is left untouched)
  gc [-n]             finish tasks whose branches are merged into base (-n: list)
  sync [<id>...] [-n] merge base into active task branches and push them;
                      conflicts go to the task's idle agent (-n: predict only)
  done [<id>] [--force]     accept: remove worktrees + session, keep branches
  archive [<id>] [--force]  abandon: same cleanup, status archived

agents:
  run [<id>] [--agent name] [-r repo] [-p prompt] [-- args]
                      start an agent in a new task window (default agent:
                      $COLLIE_AGENT, @collie-agent, else claude); -p '' = no prompt
  adopt [<id>] [-y]   restart an agent you started by hand in the task's session
                      under collie run, resuming its conversation (claude, omp)
  state <working|waiting|idle|exited>
                      called by agent hooks; no-op outside a collie window
  status              agent counts for the status bar (#{collie_status})

admin:
  doctor              dependencies, agents, and task/git/tmux consistency

discovery:
  repos               repos found under @collie-repo-roots / $COLLIE_REPO_ROOTS
  workspaces          named repo sets from ~/.config/collie/workspaces

<id> is a slug ([a-z0-9-], max 40). Omitted <id> falls back to $COLLIE_TASK.
<repo> is a discovered repo name or a path. Default branch: <type>/<id>, type=feat.
EOF
}
