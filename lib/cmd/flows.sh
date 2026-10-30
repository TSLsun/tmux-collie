# shellcheck shell=bash
# Sourced by bin/collie: flow, wait.

cmd_flow() {
  local sub=${1:-}
  [ $# -eq 0 ] || shift
  case $sub in
    ls) flow_ls "$@" ;;
    show) flow_show "$@" ;;
    start) flow_start "$@" ;;
    continue) flow_continue "$@" ;;
    stop) flow_stop_cmd "$@" ;;
    done) flow_done "$@" ;;
    *) die "usage: collie flow ls | show <name> | start <name> [<id>] | continue [<id>] | stop [<id>] | done" ;;
  esac
}

# The git dir whose main checkout holds repo-local flows: a task's first
# repo, else the repo of the current directory, else "".
flow_common() { # [id]
  local name c
  if [ -n "${1:-}" ]; then
    IFS=$TAB read -r name c _ <"$TASKS_DIR/$1/repos.tsv"
    printf '%s\n' "$c"
  elif repo_at . 2>/dev/null; then
    printf '%s\n' "$R_COMMON"
  fi
}

# Flows by name, source and file; one that an earlier source shadows is
# marked so.
flow_ls() {
  local common dir src f seen=" "
  [ $# -eq 0 ] || die "usage: collie flow ls"
  common=$(flow_common "${COLLIE_TASK:-}")
  for src in repo personal builtin; do
    case $src in
      repo) [ -n "$common" ] && [ "$common" != - ] || continue; dir="${common%/*}/.collie/flows" ;;
      personal) dir="$CONFIG_DIR/flows" ;;
      builtin) dir="$PLUGIN_DIR/flows" ;;
    esac
    for f in "$dir"/*; do
      { [ -f "$f" ] && valid_id "${f##*/}"; } || continue
      case $seen in
        *" ${f##*/} "*) printf '%s\t%s\t%s\t(shadowed)\n' "${f##*/}" "$src" "$f" ;;
        *) printf '%s\t%s\t%s\n' "${f##*/}" "$src" "$f"; seen="$seen${f##*/} " ;;
      esac
    done
  done
}

# A flow's resolved file and steps, after checking it.
flow_show() {
  local i line
  [ $# -eq 1 ] || die "usage: collie flow show <name>"
  flow_find "$1" "$(flow_common "${COLLIE_TASK:-}")"
  flow_parse "$FLOW_FILE"
  printf '%s (%s) %s\n' "$1" "$FLOW_SOURCE" "$FLOW_FILE"
  for i in "${!FS_NAME[@]}"; do
    line="  ${FS_NAME[i]}: role=${FS_ROLE[i]} agent=${FS_AGENT[i]}"
    [ -z "${FS_MODEL[i]}" ] || line="$line model=${FS_MODEL[i]}"
    [ -z "${FS_EFFORT[i]}" ] || line="$line effort=${FS_EFFORT[i]}"
    [ -z "${FS_RESUME[i]}" ] || line="$line (continues ${FS_RESUME[i]})"
    printf '%s\n' "$line"
  done
  [ -z "$FLOW_REVIEW" ] || printf '  loop: %s %s, at most %s fix rounds\n' "$FLOW_REVIEW" "$FLOW_FIX" "$FLOW_MAX"
}

flow_start() {
  local name=${1:-} id d
  { [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: collie flow start <name> [<id>]"
  task_id "${2:-}"
  d="$TASKS_DIR/$id"
  command -v tmux >/dev/null || die "flow: tmux required"
  [ ! -e "$d/flow/FLOW" ] || die "flow: task '$id' already has a flow; see collie flow continue"
  flow_find "$name" "$(flow_common "$id")"
  flow_parse "$FLOW_FILE"
  if grep -q '^## Ship' "$d/TASK.md"; then
    warn "TASK.md has a Ship section; flow steps before ship are told not to push"
  fi
  mkdir -p "$d/flow"
  cp "$FLOW_FILE" "$d/flow/FLOW"
  fm_set "$d/TASK.md" flow "$name"
  log_event "$id" flow_started "flow=$name source=$FLOW_SOURCE"
  flow_advance "$id"
  flow_report "$id"
}

flow_continue() {
  local id
  [ $# -le 1 ] || die "usage: collie flow continue [<id>]"
  task_id "${1:-}"
  flow_state "$id"
  [ "$FLOW_STATUS" = stopped ] || die "flow: task '$id' has no stopped flow"
  log_event "$id" flow_continued "n=$FLOW_N"
  flow_advance "$id" continue
  flow_report "$id"
}

flow_stop_cmd() {
  local id
  [ $# -le 1 ] || die "usage: collie flow stop [<id>]"
  task_id "${1:-}"
  flow_state "$id"
  [ "$FLOW_STATUS" = running ] || die "flow: task '$id' has no running flow"
  log_event "$id" flow_stopped "n=$FLOW_N step=$FLOW_STEP reason=user"
  flow_report "$id"
}

# The done signal of the current step, from its agent: the run is $COLLIE_RUN
# (set by `collie run`), else the pane's. Waits for flow/lock, so a step that
# is still being started is the current one.
flow_done() ( # no arguments: the task is $COLLIE_TASK
  local id run d lock i=0
  [ $# -eq 0 ] || die "usage: collie flow done"
  task_id ""
  d="$TASKS_DIR/$id"
  run=${COLLIE_RUN:-}
  [ -n "$run" ] || [ -z "${TMUX_PANE:-}" ] || run=$(tmux display-message -p -t "$TMUX_PANE" '#{@collie_run}' 2>/dev/null) || run=""
  [ -f "$d/flow/FLOW" ] || die "flow: task '$id' has no flow"
  lock="$d/flow/lock"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 600 ] || die "flow: timed out waiting for $lock"
    sleep 0.05
  done
  # shellcheck disable=SC2064
  trap "rmdir $(printf '%q' "$lock")" EXIT
  flow_state "$id"
  { [ "$FLOW_STATUS" = running ] && [ "$FLOW_N" != 0 ]; } || die "flow: task '$id' has no running step"
  [ -z "$run" ] || [ "$run" = "$FLOW_RUN" ] || die "flow: this is run $run; step $FLOW_STEP is run $FLOW_RUN"
  : >"$d/flow/$FLOW_PACKET/DONE"
  log_event "$id" step_done "n=$FLOW_N step=$FLOW_STEP run=${run:--}"
  echo "collie: step $FLOW_STEP done; the flow goes on when you stop"
)

# One line on where a flow is.
flow_report() { # id
  flow_state "$1"
  case $FLOW_STATUS in
    running)
      if [ "$FLOW_N" = 0 ]; then
        echo "flow $FLOW_NAME: running, no step started"
      else
        [ "$FLOW_ROUND" = 0 ] || FLOW_STEP="$FLOW_STEP r$FLOW_ROUND"
        echo "flow $FLOW_NAME: running, step $FLOW_STEP (run $FLOW_RUN)"
      fi ;;
    stopped) echo "flow $FLOW_NAME: stopped at $FLOW_STEP ($FLOW_REASON)" ;;
    *) echo "flow $FLOW_NAME: $FLOW_STATUS" ;;
  esac
}

# Steps and artifacts of a task's flow, for `collie show`.
flow_task_lines() { # id
  local d="$TASKS_DIR/$1" n step role round run packet f files
  flow_report "$1"
  while IFS=$TAB read -r n step role round run packet; do
    files=""
    for f in "$d/flow/$packet"/*; do
      [ -f "$f" ] || continue
      case ${f##*/} in REVIEW.md | SUMMARY.md | DONE) files="$files ${f##*/}" ;; esac
    done
    printf '  %s  run %s%s\n' "$packet" "$run" "$files"
  done < <(flow_steps "$1")
}

cmd__flow-advance() { # id [trigger]
  task_id "${1:-}"
  flow_advance "$id" "${2:-}"
}

# Waits for a run's state, the current flow step's done signal, or the end
# of the flow. Exit 0 when reached, 1 on timeout, 2 when it can no longer
# happen (the run is gone, the flow stopped).
cmd_wait() {
  local id="" run="" for="" timeout=0 start=$SECONDS
  while [ $# -gt 0 ]; do
    case $1 in
      --run) run=${2:?--run needs a number}; shift ;;
      --for) for=${2:?--for needs a state}; shift ;;
      --timeout) timeout=${2:?--timeout needs seconds}; shift ;;
      -*) die "wait: unknown option $1" ;;
      *) [ -z "$id" ] || die "wait: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [[ $timeout =~ ^[0-9]+$ ]] || die "wait: --timeout needs seconds"
  if [ -z "$for" ]; then
    for=idle
    ! flow_running "$id" || for="done"
  fi
  case $for in done | flow | working | idle | waiting | exited) ;; *) die "wait: --for done|flow|working|idle|waiting|exited" ;; esac
  case $for in done | flow) ;; *)
    [ -n "$run" ] || run=$(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 0 }' "$TASKS_DIR/$id/events.log")
    ;;
  esac
  while :; do
    case $for in
      done | flow)
        flow_state "$id"
        case $FLOW_STATUS in
          done) return 0 ;;
          running)
            if [ "$for" = "done" ] && [ "$FLOW_N" != 0 ] && [ -f "$TASKS_DIR/$id/flow/$FLOW_PACKET/DONE" ] &&
              { [ -z "$run" ] || [ "$run" = "$FLOW_RUN" ]; }; then
              return 0
            fi ;;
          *) exit 2 ;;
        esac ;;
      *)
        run_state "$id" "$run"
        [ "$RUN_STATE" != "$for" ] || return 0
        if [ "$RUN_STATE" = gone ]; then
          [ "$for" != exited ] || return 0
          exit 2
        fi ;;
    esac
    [ "$timeout" = 0 ] || [ $((SECONDS - start)) -lt "$timeout" ] || exit 1
    sleep 0.5
  done
}
