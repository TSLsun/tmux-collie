# shellcheck shell=bash
# Sourced by bin/collie: run, adopt, state, status.

# Sets RUN_AGENT, the agent `collie run` starts without --agent.
run_agent() {
  RUN_AGENT=${COLLIE_AGENT:-$(tmux_opt @collie-agent)}
  RUN_AGENT=${RUN_AGENT:-claude}
}

cmd_run() {
  local id="" agent="" repo="" prompt=$DEFAULT_PROMPT custom=0 extra=() switch=0 client=""
  while [ $# -gt 0 ]; do
    case $1 in
      --agent) agent=${2:?--agent needs a name}; shift ;;
      -r) repo=${2:?-r needs a repo}; shift ;;
      -s) switch=1 ;;
      -c) client=${2:?-c needs a client}; shift ;;
      -p) [ $# -ge 2 ] || die "-p needs a prompt"; prompt=$2 custom=1; shift ;;
      --) shift; extra=("$@"); break ;;
      -*) die "run: unknown option $1" ;;
      *) [ -z "$id" ] || die "run: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  command -v tmux >/dev/null || die "run: tmux required"
  [ -n "$agent" ] || { run_agent; agent=$RUN_AGENT; }

  local d name c b p rname="" rc="" path=""
  d="$TASKS_DIR/$id"
  while IFS=$TAB read -r name c b p; do
    if [ -z "$rname" ] && { [ -z "$repo" ] || [ "$name" = "$repo" ]; }; then rname=$name rc=$c path=$p; fi
  done <"$d/repos.tsv"
  [ -n "$rname" ] || die "repo '$repo' is not part of task '$id'"
  [ -d "$path" ] || die "missing worktree $path"
  # a folder has no .collie link
  [ "$rc" != - ] || [ "$prompt" != "$DEFAULT_PROMPT" ] || prompt=${prompt//.collie\//$d/}

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
  AGENT_HOOKS=0 AGENT_HOOKS_PENDING=0 AGENT_EXTRA_HANDLED=0 AGENT_SESSION_ID=""
  if [[ $agent != */* ]] && [ -f "$PLUGIN_DIR/agents/$agent.sh" ]; then
    # shellcheck source=/dev/null
    . "$PLUGIN_DIR/agents/$agent.sh"
    agent_argv ${extra[@]+"${extra[@]}"}
  else
    AGENT_ARGV=("$agent")
  fi
  command -v "$agent" >/dev/null || die "agent command '$agent' not found"
  [ "$AGENT_EXTRA_HANDLED" = 1 ] || AGENT_ARGV+=(${extra[@]+"${extra[@]}"})

  # an agent with hooks and no prompt sits at its input box
  local st=working run wid server pane
  [ "$AGENT_HOOKS" = 0 ] || [ -n "$prompt" ] || st=idle
  run=$(($(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 0 }' "$d/events.log") + 1))
  ensure_session "$id"
  # the server pid tells `restore` a run lost with its server from a closed
  # window; the pane is the agent's, for `sync` to type into once it is split
  wid=$(tmux_spawn new-window -d -P -F '#{window_id} #{pid} #{pane_id}' -t "=$id:" -n "$agent" -c "$path" \
    "$BASH" "$PLUGIN_DIR/bin/collie" _exec "$id" "$run" "${AGENT_ARGV[@]}")
  read -r wid server pane <<<"$wid"
  [ "$AGENT_HOOKS_PENDING" = 0 ] || AGENT_HOOKS=0
  # @collie_run last: the wrapper starts the agent once it is set
  tmux set-option -w -t "$wid" @collie_task "$id" \; set-option -w -t "$wid" @collie_path "$path" \; \
    set-option -w -t "$wid" @collie_agent "$agent" \; set-option -w -t "$wid" @collie_hooks "$AGENT_HOOKS" \; \
    set-option -w -t "$wid" @collie_pane "$pane" \; set-option -w -t "$wid" @collie_state "$st" \; \
    set-option -w -t "$wid" @collie_run "$run"
  # an instant agent exit may log run_exited first; task_runs is order-free
  log_event "$id" run_started "run=$run agent=$agent repo=$rname window=$wid server=$server"
  [ -z "$AGENT_SESSION_ID" ] || log_agent_session "$id" "$run" "$AGENT_SESSION_ID"
  # -s: show the new window (menu, dashboard); a script keeps its window
  if [ "$switch" = 1 ] && { [ -n "$client" ] || [ -n "${TMUX:-}" ]; }; then
    tmux switch-client ${client:+-c "$client"} -t "$wid" \; select-window -t "$wid" 2>/dev/null || true
  fi
  # Callers that launch a continuation need the actual new run, not a guess
  # based on the tail of an event log another agent can append to.
  RUN_STARTED=$run
}

# Cross-agent continuation uses a fresh conversation and explicit context,
# never a source agent's private transcript or its resume/session ID.
cmd_handoff() {
  local id="" from="" agent="" note="" repo="" source source_agent source_repo
  local d name c b path selected="" packet prompt RUN_STARTED=""
  while [ $# -gt 0 ]; do
    case $1 in
      --from | --agent | --note | -r)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          die "handoff: $1 needs a value"
        fi
        case $1 in
          --from) from=$2 ;;
          --agent) agent=$2 ;;
          --note) note=$2 ;;
          -r) repo=$2 ;;
        esac
        shift ;;
      -*) die "handoff: unknown option $1" ;;
      *) [ -z "$id" ] || die "handoff: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [[ $from =~ ^[1-9][0-9]*$ ]] || die "handoff: --from needs a positive source run number"
  case $agent in claude | codex) ;; *) die "handoff: --agent must be claude or codex" ;; esac
  if [ ! -f "$note" ] || [ ! -r "$note" ] || ! grep -q '[^[:space:]]' "$note"; then
    die "handoff: --note needs a readable, nonempty note file"
  fi
  d="$TASKS_DIR/$id"
  source=$(awk -F'\t' -v r="$from" '
    $2 == "run_started" {
      n = split($3, a, " "); run = agent = repo = ""
      for (i = 1; i <= n; i++) {
        if (index(a[i], "run=") == 1) run = substr(a[i], 5)
        if (index(a[i], "agent=") == 1) agent = substr(a[i], 7)
        if (index(a[i], "repo=") == 1) repo = substr(a[i], 6)
      }
      if (run == r) { print agent "\t" repo; exit }
    }' "$d/events.log")
  [ -n "$source" ] || die "handoff: source run $from does not belong to task '$id'"
  IFS=$TAB read -r source_agent source_repo <<<"$source"
  case $source_agent in claude | codex) ;; *) die "handoff: source run must use claude or codex" ;; esac
  [ "$source_agent" != "$agent" ] || die "handoff: destination agent must be different from source"
  repo=${repo:-$source_repo}
  while IFS=$TAB read -r name c b path; do
    [ "$name" != "$repo" ] || selected=$path
  done <"$d/repos.tsv"
  [ -n "$selected" ] || die "repo '$repo' is not part of task '$id'"
  [ -d "$selected" ] || die "missing worktree $selected"
  command -v "$agent" >/dev/null || die "agent command '$agent' not found"

  # Unique directories preserve earlier attempts too. Read-only permissions
  # prevent accidental edits, not deliberate changes by the file owner.
  mkdir -p "$d/handoffs"
  packet=$(mktemp -d "$d/handoffs/from-$from-to-$agent.XXXXXX")
  cp "$note" "$packet/NOTE.md"
  cp "$d/TASK.md" "$packet/TASK.md"
  [ ! -f "$d/REPORT.md" ] || cp "$d/REPORT.md" "$packet/REPORT.md"
  {
    printf '# Handoff context\n\nsource_run=%s source_agent=%s destination_agent=%s repo=%s\n\n' "$from" "$source_agent" "$agent" "$repo"
    printf 'Read NOTE.md and the TASK.md snapshot in this directory, and REPORT.md if present.\n'
    printf 'Then read the current task contract at %s/TASK.md; it remains authoritative.\n' "$d"
    printf 'The note is context, not a replacement for the task contract.\n'
    printf 'This is a fresh conversation. The source agent has not been stopped.\n'
    printf 'Continue in the existing task worktrees; preserve all previous runs.\n'
  } >"$packet/HANDOFF.md"
  chmod a-w "$packet/"* "$packet"
  prompt="Task $id. Continue $source_agent run $from as $agent. Read the handoff packet at $packet/HANDOFF.md and the current task contract at $d/TASK.md before continuing. If its Objective is empty, ask what to do. When finished, write a short report to $d/REPORT.md."
  # A failed launch leaves the packet for diagnosis, but no success event.
  cmd_run "$id" --agent "$agent" -r "$repo" -p "$prompt"
  log_event "$id" run_handoff "from=$from to=$RUN_STARTED source=$source_agent agent=$agent repo=$repo packet=${packet##*/}"
  printf '%s\n' "$packet"
}

# Restarts an agent started by hand in the task's session as a `collie run`
# that resumes its conversation, so its hooks report state and notify.
cmd_adopt() {
  local id="" yes=0 info agent wid pane pid path repo a i sid args
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
  AGENT_RESUME=() AGENT_RESUME_ID=() AGENT_REQUIRE_SESSION=0
  unset -f agent_session
  # shellcheck source=/dev/null
  [ ! -f "$PLUGIN_DIR/agents/$agent.sh" ] || . "$PLUGIN_DIR/agents/$agent.sh"
  [ ${#AGENT_RESUME[@]} -gt 0 ] || die "adopt: collie cannot resume $agent sessions"
  # its own conversation if the adapter can tell it from the pid, else the latest
  sid=""
  ! declare -F agent_session >/dev/null || sid=$(agent_session "$pid")
  [ "$AGENT_REQUIRE_SESSION" = 0 ] || [ -n "$sid" ] || die "adopt: cannot identify the active $agent conversation; use a dedicated Codex process (--no-daemon), or run with an explicit resume id"
  if [ -n "$sid" ] && [ ${#AGENT_RESUME_ID[@]} -gt 0 ]; then
    args=("${AGENT_RESUME_ID[@]}" "$sid")
  else
    args=("${AGENT_RESUME[@]}")
  fi
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
  cmd_run "$id" -r "$repo" --agent "$agent" -p '' -- "${args[@]}"
}

# Runs of a task lost with their tmux server as "run<TAB>agent<TAB>repo<TAB>
# conversation id" (id "-" if none was logged): started, never seen exiting or
# restored, no window, and started by another server than the current one
# (runs logged without a server: only when the task has no session). Runs
# with a window come first, with id "=".
lost_runs() { # id current-server-pid
  local wins="" up=0
  if has_session "$1"; then
    up=1
    wins=$(win_states -t "=$1" | cut -f3)
  fi
  awk -F'\t' -v srv="$2" -v up="$up" '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    FNR == NR { seen[$1] = 1; next }
    $2 == "run_started" { r = kv("run"); agent[r] = kv("agent"); repo[r] = kv("repo"); server[r] = kv("server"); order[++n] = r }
    $2 == "run_exited" || $2 == "run_restored" { ended[kv("run")] = 1 }
    $2 == "agent_session" { sid[kv("run")] = kv("id") }
    END {
      for (i = 1; i <= n; i++) {
        r = order[i]
        if (r in seen) print r "\t" agent[r] "\t" repo[r] "\t=\t" sid[r]
        else if (!(r in ended) && (server[r] == "" ? !up : server[r] != srv)) lost[++m] = r
      }
      for (i = 1; i <= m; i++) {
        r = lost[i]
        print r "\t" agent[r] "\t" repo[r] "\t" (r in sid ? sid[r] : "-")
      }
    }' - "$TASKS_DIR/$1/events.log" <<<"$wins"
}

# Restarts the agents lost with the tmux server under `collie run`, each
# resuming its own conversation (AGENT_RESUME_ID + the logged id), else the
# latest one in its worktree (AGENT_RESUME, unless another run of that agent
# there is live or resumes it already). Restored runs
# are logged, so running it again starts nothing.
cmd_restore() {
  local dry=0 ids="" id d server run agent repo sid used args out live_sid used_sids
  while [ $# -gt 0 ]; do
    case $1 in
      -n) dry=1 ;;
      -*) die "restore: unknown option $1" ;;
      *) [ -z "$ids" ] || die "restore: too many arguments"; task_id "$1"; ids=$1 ;;
    esac
    shift
  done
  if [ -z "$ids" ]; then
    for d in "$TASKS_DIR"/*; do
      [ -f "$d/TASK.md" ] || continue
      fm_get "$d/TASK.md" status
      case $FM in done | archived) continue ;; esac
      ids="$ids${d##*/}"$'\n'
    done
  fi
  server=$(tmux display-message -p '#{pid}' 2>/dev/null || true)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    used=" " used_sids=" "
    while IFS=$TAB read -r run agent repo sid live_sid; do
      if [ "$sid" = = ]; then
        used="$used$agent:$repo=$run "
        [ -z "$live_sid" ] || used_sids="$used_sids$agent:$live_sid "
        continue
      fi
      AGENT_RESUME=() AGENT_RESUME_ID=() AGENT_REQUIRE_SESSION=0
      # shellcheck source=/dev/null
      [[ $agent == */* ]] || [ ! -f "$PLUGIN_DIR/agents/$agent.sh" ] || . "$PLUGIN_DIR/agents/$agent.sh"
      out="$id run $run: $agent in $repo:"
      if [ "$sid" != - ] && [ ${#AGENT_RESUME_ID[@]} -gt 0 ]; then
        if [ "$AGENT_REQUIRE_SESSION" = 1 ] && [[ $used_sids == *" $agent:$sid "* ]]; then
          echo "$out skipped: conversation already live or scheduled"
          continue
        fi
        args=("${AGENT_RESUME_ID[@]}" "$sid")
        used_sids="$used_sids$agent:$sid "
      elif [ "$AGENT_REQUIRE_SESSION" = 1 ]; then
        echo "$out skipped: $agent conversation id missing; resume explicitly after identifying it in Codex"
        continue
      elif [ ${#AGENT_RESUME[@]} -eq 0 ]; then
        echo "$out skipped: collie cannot resume $agent sessions"
        continue
      elif [[ $used == *" $agent:$repo="* ]]; then
        out=${used#*" $agent:$repo="}
        echo "$id run $run: $agent in $repo: skipped: run ${out%% *} already resumes the latest conversation"
        continue
      else
        args=("${AGENT_RESUME[@]}")
        used="$used$agent:$repo=$run "
      fi
      if [ "$dry" -eq 1 ]; then
        echo "$out ${args[*]}"
      elif ("$BASH" "$PLUGIN_DIR/bin/collie" run "$id" -r "$repo" --agent "$agent" -p '' -- "${args[@]}"); then
        log_event "$id" run_restored "run=$run as=$(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 0 }' "$TASKS_DIR/$id/events.log")"
        echo "$out restored (${args[*]})"
      else
        echo "$out skipped: collie run failed"
      fi
    done < <(lost_runs "$id" "$server")
  done <<<"$ids"
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

# A real Codex hook proves trust/config loading for this window. Until then,
# use output-silence fallback instead of claiming reliable lifecycle hooks.
cmd__codex-hook() {
  local pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -n "$pane" ] || return 0
  tmux set-option -w -t "$pane" @collie_hooks 1 2>/dev/null || return 0
  # All Codex lifecycle payloads carry session_id, including hooks first
  # trusted after SessionStart was skipped.
  cmd__session
  case ${1:-} in
    _session) : ;;
    state)
      if [ "${2:-}" = working ]; then
        # A different tool may finish while a human prompt is still open.
        # Leave the observer authoritative until the dialog closes.
        [ -z "$(tmux show-options -wqv -t "$pane" @collie_codex_pending 2>/dev/null)" ] || return 0
      else
        tmux set-option -wu -t "$pane" @collie_codex_pending 2>/dev/null || true
      fi
      cmd_state "${2:-}" ;;
    wait)
      # PermissionRequest precedes hook/automatic review too: it does not
      # prove the user must answer. Observe the TUI before sending an alert.
      tmux set-option -w -t "$pane" @collie_codex_pending "$$" 2>/dev/null || return 0
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
    info=$(tmux display-message -p -t "$1" '#{@collie_codex_pending}|#{@collie_state}' 2>/dev/null) || return 0
    IFS='|' read -r pending st <<<"$info"
    [ "$pending" = "$2" ] && [ "$st" != exited ] || return 0
    screen=$(tmux capture-pane -p -t "$1" 2>/dev/null | awk 'NF { a[++n] = $0 } END { for (i = n - 3; i <= n; i++) if (i > 0) print a[i] }') || return 0
    case $screen in
      *'to confirm or '*'to cancel'* | *'to submit answer'* | *'to submit all'*)
        visible=$((visible + 1)) missing=0 ;;
      *) missing=$((missing + 1)) visible=0 ;;
    esac
    [ "$(tmux show-options -wqv -t "$1" @collie_codex_pending 2>/dev/null)" = "$2" ] || return 0
    if [ "$visible" -ge 2 ] && [ "$seen" = 0 ]; then
      set_state "$1" waiting "$2"
      seen=1
    elif [ "$st" = waiting ] && [ "$missing" -ge 2 ]; then
      set_state "$1" working "$2"
      seen=0
    fi
  done
}

# SessionStart hook: logs the run's conversation id (session_id in the hook's
# JSON on stdin) for `collie restore`, when it changed (new, /clear).
cmd__session() {
  local json sid info id run re='"session_id" *: *"([A-Za-z0-9_-]+)"' pane=${TMUX_PANE:-$(ancestor_pane)}
  [ -n "$pane" ] && [ ! -t 0 ] || return 0
  json=$(cat)
  [[ $json =~ $re ]] || return 0
  sid=${BASH_REMATCH[1]}
  info=$(tmux display-message -p -t "$pane" '#{@collie_task}|#{@collie_run}' 2>/dev/null) || return 0
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

# Counts every agent, including ones started by hand; with
# @collie-status-scope tasks, only those in task sessions. Each count is a
# mouse range: clicking it opens `collie _status-menu` (bound in collie.tmux).
cmd_status() {
  status_scope
  { win_states -a | cut -f5
    manual_runs -a | awk -F'\t' -v w="$STATUS_WINS" 'w == "" || index(w, " " $4 " ") { print $3 }'
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
# (collie runs to their window, agents started by hand to their pane).
cmd__status-menu() { # range client
  local st=${1#collie-} C="$PLUGIN_DIR/bin/collie" items=() s t agent x k=0
  status_scope
  while IFS=$TAB read -r s t agent x; do
    [ "$x" = "$st" ] || continue
    k=$((k + 1))
    items+=("${s//#/##}  $agent" "$([ "$k" -gt 9 ] || echo "$k")" "run-shell '$C _jump $t ${2:-}'")
  done < <(
    win_states -a | awk -F'\t' '{ a = $4; if ($3 != "-" && $3 != 1) a = a " #" $3; print $1 "\t" $2 "\t" a "\t" $5 }'
    manual_runs -a | awk -F'\t' -v w="$STATUS_WINS" '
      FNR == NR { j = index($0, "|"); ses[substr($0, 1, j - 1)] = substr($0, j + 1); next }
      w == "" || index(w, " " $4 " ") { print ses[$4] "\t" $5 "\t" $2 "\t" $3 }' \
      <(tmux list-windows -a -F '#{window_id}|#{session_name}' 2>/dev/null || true) -
  )
  if [ "$k" = 0 ]; then
    tmux display-message ${2:+-c "$2"} "collie: no $st agents"
    return 0
  fi
  tmux display-menu ${2:+-c "$2"} -T "#[align=centre] $st " -x M -y S "${items[@]}"
}
