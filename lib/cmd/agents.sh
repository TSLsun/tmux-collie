# shellcheck shell=bash
# Sourced by bin/collie: run, adopt, state, status.

cmd_run() {
  local id="" agent="" repo="" prompt=$DEFAULT_PROMPT custom=0 extra=()
  while [ $# -gt 0 ]; do
    case $1 in
      --agent) agent=${2:?--agent needs a name}; shift ;;
      -r) repo=${2:?-r needs a repo}; shift ;;
      -p) [ $# -ge 2 ] || die "-p needs a prompt"; prompt=$2 custom=1; shift ;;
      --) shift; extra=("$@"); break ;;
      -*) die "run: unknown option $1" ;;
      *) [ -z "$id" ] || die "run: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  command -v tmux >/dev/null || die "run: tmux required"
  agent=${agent:-${COLLIE_AGENT:-$(tmux_opt @collie-agent)}}
  agent=${agent:-claude}

  local d name c b p rname="" path=""
  d="$TASKS_DIR/$id"
  while IFS=$TAB read -r name c b p; do
    if [ -z "$rname" ] && { [ -z "$repo" ] || [ "$name" = "$repo" ]; }; then rname=$name path=$p; fi
  done <"$d/repos.tsv"
  [ -n "$rname" ] || die "repo '$repo' is not part of task '$id'"
  [ -d "$path" ] || die "missing worktree $path"

  # adapter inputs: other worktrees + the task dir, the initial prompt and a
  # session name. The default prompt leads with the task so agents that title
  # sessions from their first prompt tell tasks apart.
  # shellcheck disable=SC2034
  local RUN_NAME=$id RUN_PROMPT RUN_DIRS
  fm_get "$d/TASK.md" title
  [ -z "$FM" ] || [ "$FM" = "$id" ] || RUN_NAME="$id: $FM"
  [ "$custom" = 1 ] || prompt="Task $RUN_NAME. $prompt"
  # shellcheck disable=SC2034
  RUN_PROMPT=$prompt
  # shellcheck disable=SC2034
  RUN_DIRS=$(awk -F'\t' -v p="$path" '$4 != p { print $4 }' "$d/repos.tsv"; printf '%s\n' "$d")
  AGENT_HOOKS=0
  if [[ $agent != */* ]] && [ -f "$PLUGIN_DIR/agents/$agent.sh" ]; then
    # shellcheck source=/dev/null
    . "$PLUGIN_DIR/agents/$agent.sh"
    agent_argv
  else
    AGENT_ARGV=("$agent")
  fi
  command -v "$agent" >/dev/null || die "agent command '$agent' not found"

  # an agent with hooks and no prompt sits at its input box
  local st=working run wid
  [ "$AGENT_HOOKS" = 0 ] || [ -n "$prompt" ] || st=idle
  run=$(($(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 0 }' "$d/events.log") + 1))
  ensure_session "$id"
  wid=$(tmux_spawn new-window -d -P -F '#{window_id}' -t "=$id:" -n "$agent" -c "$path" \
    "$BASH" "$PLUGIN_DIR/bin/collie" _exec "$id" "$run" "${AGENT_ARGV[@]}" ${extra[@]+"${extra[@]}"})
  # @collie_run last: the wrapper starts the agent once it is set
  tmux set-option -w -t "$wid" @collie_task "$id" \; set-option -w -t "$wid" @collie_path "$path" \; \
    set-option -w -t "$wid" @collie_agent "$agent" \; set-option -w -t "$wid" @collie_hooks "$AGENT_HOOKS" \; \
    set-option -w -t "$wid" @collie_state "$st" \; set-option -w -t "$wid" @collie_run "$run"
  # an instant agent exit may log run_exited first; task_runs is order-free
  log_event "$id" run_started "run=$run agent=$agent repo=$rname window=$wid"
}

# Restarts an agent started by hand in the task's session as a `collie run`
# that resumes its conversation, so its hooks report state and notify.
cmd_adopt() {
  local id="" yes=0 info agent wid pane pid path repo a i
  while [ $# -gt 0 ]; do
    case $1 in
      -y) yes=1 ;;
      -*) die "adopt: unknown option $1" ;;
      *) [ -z "$id" ] || die "adopt: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  has_session "$id" || die "adopt: task '$id' has no session"
  info=$(manual_runs "=$id" | head -n 1)
  [ -n "$info" ] || die "adopt: no agent started by hand in task '$id'"
  IFS=$TAB read -r a agent a wid pane pid path <<<"$info"
  AGENT_RESUME=()
  # shellcheck source=/dev/null
  [ ! -f "$PLUGIN_DIR/agents/$agent.sh" ] || . "$PLUGIN_DIR/agents/$agent.sh"
  [ ${#AGENT_RESUME[@]} -gt 0 ] || die "adopt: collie cannot resume $agent sessions"
  repo=$(awk -F'\t' -v p="$path" '$4 == p || index(p, $4 "/") == 1 { print $1; exit }' "$TASKS_DIR/$id/repos.tsv")
  [ -n "$repo" ] || die "adopt: $agent in $pane runs outside the task's worktrees ($path)"
  if [ "$yes" -eq 0 ]; then
    [ -t 0 ] || die "adopt: confirm with -y"
    read -r -p "stop $agent in $pane and resume it under collie run? (y/n) " a || exit 1
    [ "$a" = y ] || exit 1
  fi
  kill -TERM "$pid" 2>/dev/null || die "adopt: cannot stop $agent (pid $pid)"
  for ((i = 1; i <= 100; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$pid" 2>/dev/null || die "adopt: $agent (pid $pid) did not exit"
  log_event "$id" agent_adopted "agent=$agent pane=$pane window=$wid"
  cmd_run "$id" -r "$repo" --agent "$agent" -p '' -- "${AGENT_RESUME[@]}"
}

# Window command of a run: runs the agent, records its exit, leaves a shell.
cmd__exec() { # id run argv...
  local id=$1 run=$2 code=0 i
  shift 2
  # wait until `collie run` has tagged the window, so early hooks land
  for ((i = 1; i <= 40; i++)); do
    [ -z "$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@collie_run}' 2>/dev/null)" ] || break
    sleep 0.05
  done
  trap : INT
  "$@" || code=$?
  trap - INT
  log_event "$id" run_exited "run=$run code=$code"
  set_state "${TMUX_PANE:-}" exited
  exec "${SHELL:-/bin/sh}"
}

cmd_state() {
  case ${1:-} in
    working | waiting | idle | exited) ;;
    *) die "usage: collie state <working|waiting|idle|exited>" ;;
  esac
  local pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -z "$pane" ] || set_state "$pane" "$1"
}

# Pane whose process is an ancestor of this one, for agents that strip
# $TMUX_PANE from their hooks' environment.
ancestor_pane() {
  local panes pid=$PPID i
  panes=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null) || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    case $pid in "" | 0 | 1) return 0 ;; esac
    if awk -v p="$pid" '$1 == p { print $2; f = 1; exit } END { exit !f }' <<<"$panes"; then
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

cmd_status() {
  win_states -a | awk -F'\t' '
    { n[$5]++ }
    END {
      if (n["waiting"]) s = s " #[fg=red]●" n["waiting"]
      if (n["idle"]) s = s " #[fg=yellow]●" n["idle"]
      if (n["working"]) s = s " #[fg=green]●" n["working"]
      if (s != "") print substr(s, 2) "#[default]"
    }'
}
