# shellcheck shell=bash
# Sourced by bin/collie: run, handoff, adopt, restore.

# Sets RUN_AGENT, the agent `collie run` starts without --agent.
run_agent() {
  RUN_AGENT=${COLLIE_AGENT:-$(tmux_opt @collie-agent)}
  RUN_AGENT=${RUN_AGENT:-claude}
}

# The agents a run key offers, one per line: the default (run_agent) first,
# then the bundled adapters. A name a menu command cannot quote is left out.
run_agents() {
  local a
  run_agent
  for a in "$RUN_AGENT" claude codex gemini omp; do
    [[ $a =~ ^[A-Za-z0-9._/-]+$ ]] || continue
    printf '%s\n' "$a"
  done | awk '!seen[$0]++'
}

# Allocate and record a run in one per-task critical section. A subshell
# keeps cleanup traps local to this launch, including callers like handoff.
start_run() ( # task agent repo path argv...
  local id=$1 agent=$2 repo=$3 path=$4 lock receipt run wid server pane i=0
  shift 4
  lock="$TASKS_DIR/$id/run.lock"
  # As with metadata locks, require a creation receipt: some mkdir versions
  # can report success after losing a race to create an existing directory.
  while ! receipt=$(mkdir -v "$lock" 2>/dev/null) || [ -z "$receipt" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || die "run: timed out waiting for $lock"
    sleep 0.05
  done
  # Bash 3.2 unwinds function locals before EXIT on an explicit exit.
  # Capture the quoted path now so failures still release the lock.
  # shellcheck disable=SC2064
  trap "rmdir $(printf '%q' "$lock")" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  run=$(awk -F'\t' '$2 == "run_started" { n++ } END { print n + 1 }' "$TASKS_DIR/$id/events.log") || exit
  ensure_session "$id" || exit
  wid=$(tmux_spawn new-window -d -P -F '#{window_id} #{pid} #{pane_id}' -t "=$id:" -n "$agent" -c "$path" \
    "$BASH" "$PLUGIN_DIR/bin/collie" _exec "$id" "$run" "$@") || exit
  read -r wid server pane <<<"$wid"
  log_event "$id" run_started "run=$run agent=$agent repo=$repo window=$wid server=$server" || exit
  printf '%s %s %s %s\n' "$run" "$wid" "$server" "$pane"
)

cmd_run() {
  local id="" agent="" repo="" prompt=$DEFAULT_PROMPT custom=0 extra=() switch=0 client="" scratch=0
  local RUN_MODEL="" RUN_EFFORT=""
  while [ $# -gt 0 ]; do
    case $1 in
      --agent) need_value run "--agent needs a name" "${2:-}"; agent=$2; shift ;;
      --model) need_value run "--model needs a name" "${2:-}"; RUN_MODEL=$2; shift ;;
      --effort) need_value run "--effort needs a level" "${2:-}"; RUN_EFFORT=$2; shift ;;
      -r) need_value run "-r needs a repo" "${2:-}"; repo=$2; shift ;;
      -s) switch=1 ;;
      --scratch) scratch=1 ;;
      -c) need_value run "-c needs a client" "${2:-}"; client=$2; shift ;;
      -p) [ $# -ge 2 ] || die "run: -p needs a prompt"; prompt=$2 custom=1; shift ;;
      --) shift; extra=("$@"); break ;;
      -*) die "run: unknown option $1" ;;
      *) [ -z "$id" ] || die "run: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  command -v tmux >/dev/null || die "run: tmux required"
  # a todo task whose after: deps are unsatisfied: ask on a terminal, else warn
  task_status "$id" ""
  if [ "$STATUS" = todo ]; then
    task_blocked "$TASKS_DIR/$id"
    if [ -n "$BLOCKED" ]; then
      warn "run: $id is blocked on: $BLOCKED (not done or merged)"
      if [ -t 0 ]; then
        local yn
        read -r -p "run anyway? (y/n) " yn || yn=""
        case $yn in [yY]*) ;; *) die "run: cancelled" ;; esac
      fi
    fi
  fi
  local empty
  empty=$(contract_empty "$TASKS_DIR/$id/TASK.md")
  if [ -n "$empty" ]; then
    warn "run: $id has empty sections: $empty"
    if [ -t 0 ]; then
      local yn
      read -r -p "run anyway? (y/n) " yn || yn=""
      case $yn in [yY]*) ;; *) die "run: cancelled" ;; esac
    fi
  fi
  [ -n "$agent" ] || { run_agent; agent=$RUN_AGENT; }
  # passed into agent config (codex -c): no quotes or spaces
  [[ $RUN_MODEL =~ ^[A-Za-z0-9._:/-]*$ ]] || die "run: invalid model '$RUN_MODEL'"
  [[ $RUN_EFFORT =~ ^[a-z]*$ ]] || die "run: invalid effort '$RUN_EFFORT'"

  local d name c b p rname="" rc="" rb="" path=""
  d="$TASKS_DIR/$id"
  while IFS=$TAB read -r name c b p; do
    if [ -z "$rname" ] && { [ -z "$repo" ] || [ "$name" = "$repo" ]; }; then rname=$name rc=$c rb=$b path=$p; fi
  done <"$d/repos.tsv"
  [ -n "$rname" ] || die "repo '$repo' is not part of task '$id'"
  [ -d "$path" ] || die "missing worktree $path"
  [ "$scratch" = 0 ] || [ "$rc" != - ] || die "run: --scratch needs a git repo; '$rname' is a folder"
  # a paused run's resume note (collie pause) is for whoever picks the task up
  [ "$custom" = 1 ] || [ ! -f "$d/RESUME.md" ] || prompt="$prompt $RESUME_PROMPT"
  # a folder has no .collie link
  [ "$rc" != - ] || [ "$custom" = 1 ] || prompt=${prompt//.collie\//$d/}

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
  AGENT_HOOKS=0 AGENT_HOOKS_PENDING=0 AGENT_EXTRA_HANDLED=0 AGENT_SESSION_ID="" AGENT_MODELS=0
  unset -f agent_startup_dialog
  if [[ $agent != */* ]] && [ -f "$PLUGIN_DIR/agents/$agent.sh" ]; then
    # shellcheck source=/dev/null
    . "$PLUGIN_DIR/agents/$agent.sh"
    agent_argv ${extra[@]+"${extra[@]}"}
  else
    AGENT_ARGV=("$agent")
  fi
  [ "$AGENT_MODELS" = 1 ] || [ -z "$RUN_MODEL$RUN_EFFORT" ] || die "run: collie cannot pass --model/--effort to $agent"
  command -v "$agent" >/dev/null || die "agent command '$agent' not found"
  [ "$AGENT_EXTRA_HANDLED" = 1 ] || AGENT_ARGV+=(${extra[@]+"${extra[@]}"})

  # an agent with hooks and no prompt sits at its input box
  local st=working run wid server pane
  [ "$AGENT_HOOKS" = 0 ] || [ -n "$prompt" ] || st=idle
  # --scratch: the run works in its own worktree at the branch head; RUN_DIRS
  # above already leaves the task worktree out
  if [ "$scratch" = 1 ]; then
    scratch_add "$d" "$rc" "$rb" "$path" || die "run: could not add a scratch worktree for $rname"
    path=$SCRATCH
  fi
  # the server pid tells `restore` a run lost with its server from a closed
  # window; the pane is the agent's, for `sync` to type into once it is split
  if ! wid=$(start_run "$id" "$agent" "$rname" "$path" "${AGENT_ARGV[@]}"); then
    [ "$scratch" = 0 ] || git --git-dir="$rc" worktree remove --force "$path" || true
    return 1
  fi
  read -r run wid server pane <<<"$wid"
  if [ "$scratch" = 1 ]; then
    log_event "$id" scratch_created "run=$run repo=$rname path=$path head=$(git -C "$path" rev-parse HEAD)" || return
  fi
  [ "$AGENT_HOOKS_PENDING" = 0 ] || AGENT_HOOKS=0
  # @collie_run last: the wrapper starts the agent once it is set
  stamp %s
  local watch=""
  if declare -F agent_startup_dialog >/dev/null; then
    watch=$NOW.$$
    tmux set-option -w -t "$wid" @collie_startup "$watch" || return
  fi
  tmux set-option -w -t "$wid" @collie_task "$id" \; set-option -w -t "$wid" @collie_path "$path" \; \
    set-option -w -t "$wid" @collie_agent "$agent" \; set-option -w -t "$wid" @collie_hooks "$AGENT_HOOKS" \; \
    set-option -w -t "$wid" @collie_pane "$pane" \; set-option -w -t "$wid" @collie_state "$st" \; \
    set-option -w -t "$wid" @collie_state_at "$NOW" \; set-option -w -t "$wid" @collie_run "$run" || return
  if [ -n "$AGENT_SESSION_ID" ]; then
    log_agent_session "$id" "$run" "$AGENT_SESSION_ID" || return
  fi
  [ -z "$RUN_MODEL$RUN_EFFORT" ] || log_event "$id" run_model "run=$run model=${RUN_MODEL:--} effort=${RUN_EFFORT:--}" || return
  # nohup: outlives a menu or popup that started the run; 3>&-: not bats' fd
  if [ -n "$watch" ]; then
    nohup "$BASH" "$PLUGIN_DIR/bin/collie" _startup-watch "$pane" "$watch" "$st" </dev/null >/dev/null 2>&1 3>&- &
  fi
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
  case $agent in claude | codex | omp) ;; *) die "handoff: --agent must be claude, codex, or omp" ;; esac
  if [ ! -f "$note" ] || [ ! -r "$note" ] || ! grep -q '[^[:space:]]' "$note"; then
    die "handoff: --note needs a readable, nonempty note file"
  fi
  d="$TASKS_DIR/$id"
  source=$(awk -F'\t' -v r="$from" "$AWK_KV"'
    $2 == "run_started" && kv("run") == r { print kv("agent") "\t" kv("repo"); exit }' "$d/events.log")
  [ -n "$source" ] || die "handoff: source run $from does not belong to task '$id'"
  IFS=$TAB read -r source_agent source_repo <<<"$source"
  case $source_agent in claude | codex | omp) ;; *) die "handoff: source run must use claude, codex, or omp" ;; esac
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
  [ ! -f "$d/RESUME.md" ] || prompt="$prompt ${RESUME_PROMPT//.collie\//$d/}"
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
  a=""
  [ ! -f "$TASKS_DIR/$id/RESUME.md" ] || a="Task $id. ${RESUME_PROMPT//.collie\//$TASKS_DIR/$id/}"
  cmd_run "$id" -r "$repo" --agent "$agent" -p "$a" -- "${args[@]}"
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
  awk -F'\t' -v srv="$2" -v up="$up" "$AWK_KV"'
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
      # a resumed run would land in the task worktree, not its scratch one
      if scratch_list "$TASKS_DIR/$id" | awk -F'\t' -v r="$run" '$1 == r { f = 1 } END { exit !f }'; then
        echo "$id run $run: $agent in $repo: skipped: scratch run; start a new one with run --scratch"
        continue
      fi
      # a run whose repo was since dropped (maybe re-added under its name) or
      # switched to another branch belongs to a removed worktree
      if ! awk -F'\t' -v r="$run" -v n="$repo" '
        { count = split($3, fields, " "); for (i = 1; i <= count; i++) {
            if ($2 == "run_started" && fields[i] == "run=" r) started = 1
            if (started && ($2 == "repo_dropped" || $2 == "repo_switched") && fields[i] == "repo=" n) dropped = 1
          } }
        END { exit dropped ? 1 : 0 }' "$TASKS_DIR/$id/events.log" ||
        ! awk -F'\t' -v n="$repo" '$1 == n { found = 1 } END { exit !found }' "$TASKS_DIR/$id/repos.tsv"; then
        echo "$id run $run: $agent in $repo: skipped: repo removed or switched since"
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
      elif (cmd_run "$id" -r "$repo" --agent "$agent" -p '' -- "${args[@]}" &&
        log_event "$id" run_restored "run=$run as=$RUN_STARTED"); then
        echo "$out restored (${args[*]})"
      else
        echo "$out skipped: collie run failed"
      fi
    done < <(lost_runs "$id" "$server")
  done <<<"$ids"
}
