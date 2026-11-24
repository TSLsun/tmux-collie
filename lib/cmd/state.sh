# shellcheck shell=bash
# Sourced by bin/collie: run lifecycle, state, status, and agent hooks.

# Window command of a run: runs the agent, records its exit, leaves a shell.
cmd__exec() { # id run argv...
  local id=$1 run=$2 code=0 i
  shift 2
  # wait until `collie run` has tagged the window, so early hooks land
  for ((i = 1; i <= 40; i++)); do
    [ -z "$(tmux_display_message -p -t "${TMUX_PANE:-}" '#{@collie_run}' 2>/dev/null)" ] || break
    sleep 0.05
  done
  trap : INT
  # `collie signal done` tells its run by these
  PATH="$PLUGIN_DIR/bin:$PATH" COLLIE_TASK=$id COLLIE_RUN=$run "$@" || code=$?
  trap - INT
  log_event "$id" run_exited "run=$run code=$code"
  set_state "${TMUX_PANE:-}" exited
  exec "${SHELL:-/bin/sh}"
}

# Waits until a run reaches a state, or signals done and stops. Follows
# restores. Exit 0 when reached, 1 on timeout, 2 when it cannot happen any
# more (the run is gone).
cmd_wait() {
  local id="" run="" want=idle timeout=0 start=$SECONDS
  while [ $# -gt 0 ]; do
    case $1 in
      --run) need_value wait "--run needs a number" "${2:-}"; run=$2; shift ;;
      --state) need_value wait "--state needs a state" "${2:-}"; want=$2; shift ;;
      --done) want="done" ;;
      --timeout) need_value wait "--timeout needs seconds" "${2:-}"; timeout=$2; shift ;;
      -*) die "wait: unknown option $1" ;;
      *) [ -z "$id" ] || die "wait: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [[ $timeout =~ ^[0-9]+$ ]] || die "wait: --timeout needs seconds"
  case $want in "done" | working | idle | waiting | exited) ;; *) die "wait: --state working|idle|waiting|exited" ;; esac
  [ -n "$run" ] || run=$(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 0 }' "$TASKS_DIR/$id/events.log")
  [[ $run =~ ^[1-9][0-9]*$ ]] || die "wait: no run to wait for"
  while :; do
    run_resolve "$id" "$run"
    run_state "$id" "$RUN_LIVE"
    case $want in
      "done") [ "$RUN_DONE" = 0 ] || [ "$RUN_STATE" = working ] || return 0 ;;
      exited) [ "$RUN_STATE" != gone ] || return 0 ;;
      *) [ "$RUN_STATE" != "$want" ] || return 0 ;;
    esac
    [ "$RUN_STATE" != gone ] || exit 2
    [ "$timeout" = 0 ] || [ $((SECONDS - start)) -lt "$timeout" ] || exit 1
    sleep 0.5
  done
}

# Run by an agent in its run's window: logs that its turn is done.
cmd_signal() {
  local id run=${COLLIE_RUN:-}
  [ $# -eq 1 ] && [ "$1" = "done" ] || die "usage: collie signal done"
  task_id ""
  [ -n "$run" ] || [ -z "${TMUX_PANE:-}" ] ||
    run=$(tmux_display_message -p -t "$TMUX_PANE" '#{@collie_run}' 2>/dev/null || true)
  [[ $run =~ ^[1-9][0-9]*$ ]] || die "signal: not inside a collie run"
  log_event "$id" run_signal "run=$run signal=done"
}

cmd_state() {
  case ${1:-} in
    working | waiting | idle | exited) ;;
    *) die "usage: collie state <working|waiting|idle|exited>" ;;
  esac
  local pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -n "$pane" ] || return 0
  # a hook proves the agent is past its startup dialogs: ends _startup-watch
  tmux_unset_window_opt "$pane" @collie_startup 2>/dev/null || true
  set_state "$pane" "$1"
}

# A real Codex hook proves trust/config loading for this window. Until then,
# use output-silence fallback instead of claiming reliable lifecycle hooks.
cmd__codex-hook() {
  local pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -n "$pane" ] || return 0
  tmux_set_window_opt "$pane" @collie_hooks 1 2>/dev/null || return 0
  tmux_unset_window_opt "$pane" @collie_startup 2>/dev/null || true
  # All Codex lifecycle payloads carry session_id, including hooks first
  # trusted after SessionStart was skipped.
  cmd__session
  case ${1:-} in
    _session) : ;;
    state)
      if [ "${2:-}" = working ]; then
        # A different tool may finish while a human prompt is still open.
        # Leave the observer authoritative until the dialog closes.
        [ -z "$(tmux_window_opt "$pane" @collie_codex_pending)" ] || return 0
      else
        tmux_unset_window_opt "$pane" @collie_codex_pending 2>/dev/null || true
      fi
      cmd_state "${2:-}" ;;
    wait)
      # PermissionRequest precedes hook/automatic review too: it does not
      # prove the user must answer. Observe the TUI before sending an alert.
      tmux_set_window_opt "$pane" @collie_codex_pending "$$" 2>/dev/null || return 0
      "$BASH" "$PLUGIN_DIR/bin/collie" _codex-wait "$pane" "$$" >/dev/null 2>&1 &
      ;;
  esac
}

# Codex 0.165.0 has no approval-resolved hook. Check only the current TUI
# footer, never scrollback: announce a human wait after two observations,
# then recover as soon as the dialog disappears, before a slow tool ends.
# Unknown/custom UI falls back to working; never infer a human wait from
# an automatic permission review. Idle/exited hooks invalidate the observer;
# working hooks can arrive from other concurrent tools while a dialog is open.
cmd__codex-wait() { # pane pending-token
  local info pending st screen visible=0 missing=0 seen=0
  while :; do
    sleep 0.2
    info=$(tmux_display_message -p -t "$1" '#{@collie_codex_pending}|#{@collie_state}' 2>/dev/null) || return 0
    IFS='|' read -r pending st <<<"$info"
    [ "$pending" = "$2" ] && [ "$st" != exited ] || return 0
    screen=$(pane_bottom "$1" 4) || return 0
    case $screen in
      *'to confirm or '*'to cancel'* | *'to submit answer'* | *'to submit all'*)
        visible=$((visible + 1)) missing=0 ;;
      *) missing=$((missing + 1)) visible=0 ;;
    esac
    [ "$(tmux_window_opt "$1" @collie_codex_pending)" = "$2" ] || return 0
    if [ "$visible" -ge 2 ] && [ "$seen" = 0 ]; then
      set_state "$1" waiting "$2"
      seen=1
    elif [ "$st" = waiting ] && [ "$missing" -ge 2 ]; then
      set_state "$1" working "$2"
      seen=0
    fi
  done
}

# No hook fires at a startup trust dialog, so watch the pane until the agent's
# first hook (cmd_state, cmd__codex-hook unset the token), for
# COLLIE_STARTUP_WATCH seconds (60) after the last dialog seen, or 24 h: a
# dialog can wait for a human indefinitely. Two observations either way; when
# a dialog closes, back to the run's starting state, as a run with no prompt
# fires no hook. Keeps watching: agents show more than one dialog in a row.
cmd__startup-watch() { # pane token state-after-dialog
  local info tok st visible=0 missing=0 seen=0 start=$SECONDS last=$SECONDS limit=${COLLIE_STARTUP_WATCH:-60}
  while [ $((SECONDS - start)) -lt 86400 ]; do
    sleep 0.5
    info=$(tmux_display_message -p -t "$1" '#{@collie_startup}|#{@collie_state}' 2>/dev/null) || return 0
    IFS='|' read -r tok st <<<"$info"
    [ "$tok" = "$2" ] && [ "$st" != exited ] || return 0
    if startup_dialog "$1"; then
      visible=$((visible + 1)) missing=0 last=$SECONDS
    else
      missing=$((missing + 1)) visible=0
    fi
    if [ "$visible" -ge 2 ] && [ "$seen" = 0 ]; then
      set_state "$1" waiting "$2" @collie_startup
      seen=1
    elif [ "$seen" = 1 ] && [ "$missing" -ge 2 ]; then
      set_state "$1" "$3" "$2" @collie_startup
      seen=0
    fi
    [ "$seen" = 1 ] || [ $((SECONDS - last)) -lt "$limit" ] || break
  done
  tmux_unset_window_opt "$1" @collie_startup 2>/dev/null || true
}

# SessionStart hook: logs the run's conversation id (session_id in the hook's
# JSON on stdin) for `collie restore`, when it changed (new, /clear).
cmd__session() {
  local json sid info id run re='"session_id" *: *"([A-Za-z0-9_-]+)"' pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -n "$pane" ] && [ ! -t 0 ] || return 0
  json=$(cat)
  [[ $json =~ $re ]] || return 0
  sid=${BASH_REMATCH[1]}
  info=$(tmux_display_message -p -t "$pane" '#{@collie_task}|#{@collie_run}' 2>/dev/null) || return 0
  IFS='|' read -r id run <<<"$info"
  [ -n "$id" ] && [ -n "$run" ] && [ -f "$TASKS_DIR/$id/TASK.md" ] || return 0
  log_agent_session "$id" "$run" "$sid"
}

log_agent_session() { # task run id
  [ "$(awk -F'\t' -v r="run=$2 id=" '$2 == "agent_session" && index($3, r) == 1 { s = substr($3, length(r) + 1) } END { print s }' "$TASKS_DIR/$1/events.log")" != "$3" ] || return 0
  log_event "$1" agent_session "run=$2 id=$3"
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

# Whether the status bar counts agents started by hand: @collie-status-manual on.
status_manual() { [ "$(tmux_opt @collie-status-manual)" = on ]; }

# Windows in the status bar's scope, as " @1 @2 ": with
# @collie-status-scope tasks, only those of task sessions; else all ("").
status_scope() {
  local s w
  STATUS_WINS=""
  [ "$(tmux_opt @collie-status-scope)" = tasks ] || return 0
  STATUS_WINS=" "
  while IFS='|' read -r s w; do
    [ ! -f "$TASKS_DIR/$s/TASK.md" ] || STATUS_WINS="$STATUS_WINS$w "
  done < <(tmux list-windows -a -F '#{session_name}|#{window_id}' 2>/dev/null || true)
}

# Counts the agents of collie runs; with @collie-status-manual on, also
# agents started by hand, whose state is only guessed from output silence
# (with @collie-status-scope tasks, only those in task sessions). Each count
# is a mouse range: clicking it opens `collie _status-menu` (bound in
# collie.tmux).
cmd_status() {
  status_scope
  { win_states -a | cut -f5
    ! status_manual || manual_runs -a | awk -F'\t' -v w="$STATUS_WINS" 'w == "" || index(w, " " $4 " ") { print $3 }'
  } | awk '
    function c(st, fg) { if (n[st]) s = s " #[range=user|collie-" st "]#[fg=" fg "]●" n[st] "#[norange]" }
    { n[$1]++ }
    END {
      c("waiting", "red")
      c("idle", "yellow")
      c("working", "green")
      if (s != "") print substr(s, 2) "#[default]"
    }'
}

# Menu of the agents behind a status bar count; picking one jumps to it
# (collie runs to their window, agents started by hand to their pane). A row
# is "session:window  agent  age  priority title" (the directory for agents
# outside a task); age is the time in this state, or without output when
# idle, marked "~" when the state is guessed from output silence (agents
# started by hand, runs without hooks). It opens at column x (the click), above a bottom status bar or below
# a top one; tmux keeps it on screen.
cmd__status-menu() { # range client [x]
  local st=${1#collie-} C="$PLUGIN_DIR/bin/collie" items=() locs=() ts=() ags=() ages=() descs=()
  local s t loc agent age path w1=0 w2=0 w3=0 cw i k line
  status_scope
  stamp %s
  # fields split at \037: the age may be empty, and tabs would merge
  while IFS=$'\037' read -r s t loc agent age path; do
    if [ -f "$TASKS_DIR/$s/TASK.md" ]; then
      fm_get "$TASKS_DIR/$s/TASK.md" title
      path=$FM
      fm_get "$TASKS_DIR/$s/TASK.md" priority
      path="${FM:+$FM }$path"
    else
      path=${path##*/}
    fi
    [ "${#loc}" -le 20 ] || loc="${s:0:$((19 - ${#loc} + ${#s}))}…:${loc##*:}"
    [ "${#agent}" -le 12 ] || agent="${agent:0:11}…"
    [ "${#loc}" -le "$w1" ] || w1=${#loc}
    [ "${#agent}" -le "$w2" ] || w2=${#agent}
    [ "${#age}" -le "$w3" ] || w3=${#age}
    locs+=("$loc") ts+=("$t") ags+=("$agent") ages+=("$age") descs+=("$path")
  done < <(
    {
      win_states -a | awk -F'\t' -v st="$st" '$5 == st { a = $4; if ($3 != "-" && $3 != 1) a = a " #" $3; print "w\t" $1 "\t" $2 "\t" $2 "\t" a "\t" }'
      ! status_manual || manual_runs -a | awk -F'\t' -v w="$STATUS_WINS" -v st="$st" '
        FNR == NR { j = index($0, "|"); ses[substr($0, 1, j - 1)] = substr($0, j + 1); next }
        $3 == st && (w == "" || index(w, " " $4 " ")) { print "m\t" ses[$4] "\t" $5 "\t" $4 "\t" $2 "\t" $7 }' \
        <(tmux list-windows -a -F '#{window_id}|#{session_name}' 2>/dev/null || true) -
    } | awk -F'\t' -v now="$NOW" -v st="$st" '
      function ago(n) {
        if (n == "") return ""
        if (n < 0) n = 0
        return n < 60 ? n "s" : n < 3600 ? int(n / 60) "m" : n < 86400 ? int(n / 3600) "h" : int(n / 86400) "d"
      }
      FNR == NR { split($0, f, "|"); ix[f[1]] = f[2]; cur[f[1]] = f[3]; at[f[1]] = f[4]; act[f[1]] = f[5]; hk[f[1]] = f[6]; next }
      {
        w = $4; n = ""
        if ($1 == "w" && cur[w] == st && at[w] != "") n = now - at[w]
        else if (st == "idle") n = now - act[w]
        print $2 "\037" $3 "\037" $2 ":" ix[w] "\037" $5 "\037" ($1 == "m" || hk[w] == "0" ? "~" : "") ago(n) "\037" $6
      }' <(tmux list-windows -a -F '#{window_id}|#{window_index}|#{@collie_state}|#{@collie_state_at}|#{window_activity}|#{@collie_hooks}' 2>/dev/null || true) -
  )
  if [ "${#ts[@]}" = 0 ]; then
    tmux_display_message ${2:+-c "$2"} "collie: no $st agents"
    return 0
  fi
  # a menu wider than the client does not open: the description gets the rest
  cw=$(tmux list-clients -F '#{client_name}|#{client_width}' 2>/dev/null | awk -F'|' -v c="${2:-}" '$1 == c || c == "" { print $2; exit }') || true
  cw=$((${cw:-80} - w1 - w2 - w3 - 14))
  [ "$cw" -le 32 ] || cw=32
  for i in "${!ts[@]}"; do
    k=$((i + 1))
    path=${descs[i]}
    if [ "${#path}" -gt "$cw" ]; then
      path=${path:0:$((cw > 1 ? cw - 1 : 0))}
      path="${path%"${path##*[! ]}"}…"
    fi
    [ "$cw" -gt 0 ] || path=""
    printf -v line "%s%*s  %s%*s" "${locs[i]}" $((w1 - ${#locs[i]})) "" "${ags[i]}" $((w2 - ${#ags[i]})) ""
    [ "$w3" = 0 ] || printf -v line "%s  %*s%s" "$line" $((w3 - ${#ages[i]})) "" "${ages[i]}"
    line="$line  $path"
    line=${line%"${line##*[! ]}"}
    items+=("${line//#/##}" "$([ "$k" -gt 9 ] || echo "$k")" "run-shell '$C _jump ${ts[i]} ${2:-}'")
  done
  tmux display-menu ${2:+-c "$2"} -T "#[align=centre] $st " -x "${3:-R}" -y S "${items[@]}"
}
