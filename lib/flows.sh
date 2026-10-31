# shellcheck shell=bash
# Sourced by bin/collie: flows, multi-agent workflows from plain-line files.
# A flow's progress lives in events.log and <task>/flow/, so any trigger (a
# run's idle or exit hook, `flow continue`, restore) can advance it; no
# process watches it.

FLOW_ROLES='implement review fix ship'

# Sets FLOW_FILE and FLOW_SOURCE for a flow name, first match: repo (the
# untracked .collie/flows/ beside a repo's git dir: its main checkout),
# personal (~/.config/collie/flows), builtin (shipped with collie).
flow_find() { # name [git-common-dir]
  valid_id "$1" || die "invalid flow name '$1'"
  FLOW_SOURCE=repo FLOW_FILE=${2:+${2%/*}/.collie/flows/$1}
  if [ -z "${2:-}" ] || [ "$2" = - ] || [ ! -f "$FLOW_FILE" ]; then
    FLOW_SOURCE=personal FLOW_FILE="$CONFIG_DIR/flows/$1"
    [ -f "$FLOW_FILE" ] || FLOW_SOURCE=builtin FLOW_FILE="$PLUGIN_DIR/flows/$1"
    [ -f "$FLOW_FILE" ] || die "unknown flow '$1'"
  fi
}

flow_bad() { die "flow $FLOW_AT: $1"; }

# Parses a flow file into the step arrays FS_NAME, FS_ROLE, FS_AGENT,
# FS_MODEL, FS_EFFORT, FS_RESUME and FS_CONV (the step whose conversation a
# step continues: itself unless resume=), and the loop: FLOW_REVIEW,
# FLOW_FIX, FLOW_MAX (fix rounds). Dies on the first error.
flow_parse() { # file
  local file=$1 line n=0 name w k v role agent model effort resume conv i
  local -a words
  FS_NAME=() FS_ROLE=() FS_AGENT=() FS_MODEL=() FS_EFFORT=() FS_RESUME=() FS_CONV=()
  FLOW_REVIEW="" FLOW_FIX="" FLOW_MAX=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    FLOW_AT="$file:$n"
    line=${line%%#*}
    case $line in *[![:space:]]*) ;; *) continue ;; esac
    case $line in *:*) ;; *) flow_bad "expected '<step>: key=value...'" ;; esac
    name=${line%%:*}
    name=${name//[[:space:]]/}
    read -r -a words <<<"${line#*:}"
    if [ "$name" = loop ]; then
      [ -z "$FLOW_REVIEW" ] || flow_bad "only one loop"
      { [ "${#words[@]}" -eq 3 ] && [[ ${words[2]} =~ ^max=[0-9]+$ ]]; } ||
        flow_bad "expected 'loop: <review-step> <fix-step> max=N'"
      FLOW_REVIEW=${words[0]} FLOW_FIX=${words[1]} FLOW_MAX=${words[2]#max=}
      continue
    fi
    valid_id "$name" || flow_bad "invalid step name '$name'"
    ! flow_index "$name" || flow_bad "duplicate step '$name'"
    role="" agent="" model="" effort="" resume=""
    [ "$name" != ship ] || role=ship
    for w in ${words[@]+"${words[@]}"}; do
      k=${w%%=*} v=${w#*=}
      { [ "$k" != "$w" ] && [ -n "$v" ]; } || flow_bad "expected key=value, got '$w'"
      case $k in
        role) role=$v ;;
        agent) agent=$v ;;
        model) model=$v ;;
        effort) effort=$v ;;
        resume) resume=$v ;;
        *) flow_bad "unknown key '$k'" ;;
      esac
    done
    case " $FLOW_ROLES " in *" $role "*) ;; *) flow_bad "role must be one of: $FLOW_ROLES" ;; esac
    if [ "$name" = ship ]; then
      [ "$role" = ship ] || flow_bad "the ship step has role ship"
    elif [ "$role" = ship ]; then
      flow_bad "role ship is the 'ship:' line"
    fi
    [[ $model =~ ^[A-Za-z0-9._:/-]*$ ]] || flow_bad "invalid model '$model'"
    [[ $effort =~ ^[a-z]*$ ]] || flow_bad "invalid effort '$effort'"
    conv=$name
    if [ -n "$resume" ]; then
      flow_index "$resume" || flow_bad "resume=$resume: no earlier step '$resume'"
      [ -z "$agent$model$effort" ] || flow_bad "resume= continues $resume's agent; drop agent/model/effort"
      agent=${FS_AGENT[FI]} model=${FS_MODEL[FI]} effort=${FS_EFFORT[FI]} conv=${FS_CONV[FI]}
    elif [ -z "$agent" ]; then
      run_agent
      agent=$RUN_AGENT
    fi
    flow_check_agent "$agent" "$model" "$effort"
    FS_NAME+=("$name") FS_ROLE+=("$role") FS_AGENT+=("$agent") FS_MODEL+=("$model")
    FS_EFFORT+=("$effort") FS_RESUME+=("$resume") FS_CONV+=("$conv")
  done <"$file"
  [ "${#FS_NAME[@]}" -gt 0 ] || die "flow $file: no steps"
  if [ -n "$FLOW_REVIEW" ]; then
    flow_index "$FLOW_REVIEW" && [ "${FS_ROLE[FI]}" = review ] || die "flow $file: loop: '$FLOW_REVIEW' is not a review step"
    i=$FI
    flow_index "$FLOW_FIX" && [ "${FS_ROLE[FI]}" = fix ] || die "flow $file: loop: '$FLOW_FIX' is not a fix step"
    [ "$i" -lt "$FI" ] || die "flow $file: loop: the fix step comes after the review step"
  fi
  for i in "${!FS_ROLE[@]}"; do
    [ "${FS_ROLE[i]}" != fix ] || [ "${FS_NAME[i]}" = "$FLOW_FIX" ] || die "flow $file: fix step '${FS_NAME[i]}' is not in a loop"
  done
}

# Flows need an adapter with lifecycle hooks: a step ends when its run stops.
flow_check_agent() { # agent model effort
  local caps
  [[ $1 != */* ]] && [ -f "$PLUGIN_DIR/agents/$1.sh" ] || die "flow: agent '$1' has no collie adapter"
  # shellcheck source=/dev/null
  caps=$(AGENT_HOOKS=0 AGENT_MODELS=0; . "$PLUGIN_DIR/agents/$1.sh"; echo "$AGENT_HOOKS $AGENT_MODELS")
  [ "${caps% *}" = 1 ] || die "flow: agent '$1' has no lifecycle hooks"
  [ "${caps#* }" = 1 ] || [ -z "$2$3" ] || die "flow: collie cannot pass model/effort to $1"
}

# Sets FI to the index of a step; fails if there is none.
flow_index() { # step
  local i
  for i in ${FS_NAME[@]+"${!FS_NAME[@]}"}; do
    [ "${FS_NAME[i]}" != "$1" ] || { FI=$i; return 0; }
  done
  return 1
}

# Sets FLOW_STATUS (none, running, stopped, done), FLOW_NAME, and for the
# latest step: FLOW_N (its number, 0 before the first), FLOW_STEP,
# FLOW_ROUND, FLOW_RUN (followed through restores), FLOW_PACKET; FLOW_FIXES
# (fix steps started), FLOW_REASON (why it stopped), FLOW_RETRY (1: its
# artifact was sent back once), FLOW_CONT (1: continued, no step since).
flow_state() { # id
  local out
  out=$(awk -F'\t' '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    BEGIN { name = step = run = pk = reason = "-" }
    $2 == "flow_started" { st = "running"; name = kv("flow"); n = round = fixes = retry = cont = 0; step = run = pk = reason = "-" }
    $2 == "flow_step" { n = kv("n") + 0; step = kv("step"); round = kv("round"); run = kv("run"); pk = kv("packet"); retry = cont = 0; if (kv("role") == "fix") fixes++ }
    $2 == "flow_retry" && kv("n") + 0 == n { retry = 1 }
    $2 == "flow_stopped" { st = "stopped"; reason = kv("reason") }
    $2 == "flow_continued" { st = "running"; cont = 1 }
    $2 == "flow_done" { st = "done" }
    $2 == "run_restored" { as[kv("run")] = kv("as") }
    END {
      while (run in as) run = as[run]
      print (st == "" ? "none" : st) "\t" name "\t" n + 0 "\t" step "\t" round + 0 "\t" run "\t" pk "\t" fixes + 0 "\t" reason "\t" retry + 0 "\t" cont + 0
    }' "$TASKS_DIR/$1/events.log")
  IFS=$TAB read -r FLOW_STATUS FLOW_NAME FLOW_N FLOW_STEP FLOW_ROUND FLOW_RUN FLOW_PACKET FLOW_FIXES FLOW_REASON FLOW_RETRY FLOW_CONT <<<"$out"
}

# Whether a task has a flow that is neither stopped nor done.
flow_running() { # id
  [ -f "$TASKS_DIR/$1/flow/FLOW" ] &&
    awk -F'\t' '$2 ~ /^flow_(started|continued|stopped|done)$/ { s = $2 }
      END { exit !(s == "flow_started" || s == "flow_continued") }' "$TASKS_DIR/$1/events.log"
}

# The run that holds a conversation: the latest step in it, after restores.
flow_conv_run() { # id conv
  awk -F'\t' -v c="$2" '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    $2 == "flow_started" { r = "" }
    $2 == "flow_step" && kv("conv") == c { r = kv("run") }
    $2 == "run_restored" { as[kv("run")] = kv("as") }
    END { while (r in as) r = as[r]; print r }' "$TASKS_DIR/$1/events.log"
}

# The packet of the latest step with a role in the current flow, or "".
flow_last_packet() { # id role
  awk -F'\t' -v r="role=$2 " '
    $2 == "flow_started" { p = "" }
    $2 == "flow_step" && index($3, r) { p = $3; sub(/.*packet=/, "", p); sub(/ .*/, "", p) }
    END { print p }' "$TASKS_DIR/$1/events.log"
}

# Sets RUN_STATE (working, idle, waiting, else gone) and RUN_WIN of a run.
run_state() { # id run
  local l
  # no early exit: task_runs would die of SIGPIPE under pipefail
  l=$(task_runs "$1" | awk -F'\t' -v r="$2" '$1 == r && !f { print $3 "\t" $4; f = 1 }')
  RUN_STATE=${l%%"$TAB"*} RUN_WIN=${l#*"$TAB"}
  case $RUN_STATE in working | idle | waiting) ;; *) RUN_STATE=gone RUN_WIN=- ;; esac
}

# Notifies about a flow, jumping to the agent pane of a run if it is up.
flow_notify() { # id run message
  local pane=""
  run_state "$1" "$2"
  [ "$RUN_WIN" = - ] || pane=$(agent_pane "$1" "$RUN_WIN")
  notify "collie: $1" "flow $FLOW_NAME: $3" "$pane"
}

flow_stop() { # id reason message
  log_event "$1" flow_stopped "n=$FLOW_N step=$FLOW_STEP reason=$2"
  flow_notify "$1" "$FLOW_RUN" "stopped at $FLOW_STEP: $3"
}

# Each worktree's HEAD and a checksum of its status: a read-only step must
# leave them as they were.
flow_trees() { # id
  local name c b p
  while IFS=$TAB read -r name c b p; do
    [ "$c" != - ] && [ -d "$p" ] || continue
    printf '%s %s %s\n' "$name" "$(git -C "$p" rev-parse -q --verify HEAD)" "$(git -C "$p" status --porcelain | cksum)"
  done <"$TASKS_DIR/$1/repos.tsv"
}

# Each repo's changes since it forked from its base (else since its worktree
# was created), uncommitted ones included.
flow_diff() { # id
  local d="$TASKS_DIR/$1" name c b p from
  while IFS=$TAB read -r name c b p; do
    [ "$c" != - ] && [ -d "$p" ] || continue
    from=""
    ! default_base "$c" || from=$(git -C "$p" merge-base "$BASE" HEAD 2>/dev/null) || from=""
    [ -n "$from" ] || { repo_start "$d" "$name"; from=$START; }
    [ -n "$from" ] || continue
    printf '== %s (%s, since %s)\n' "$name" "$b" "$(git -C "$p" rev-parse --short "$from")"
    git -C "$p" diff --stat "$from"
    git -C "$p" diff "$from"
  done <"$d/repos.tsv"
}

# A role's prompt (~/.config/collie/roles/<role>.md, else the shipped one)
# with {{NAME}} replaced by $FV_NAME.
flow_prompt() { # role
  local t="$CONFIG_DIR/roles/$1.md"
  [ -f "$t" ] || t="$PLUGIN_DIR/templates/roles/$1.md"
  awk '{
    out = ""
    while (match($0, /\{\{[A-Z_]+\}\}/)) {
      out = out substr($0, 1, RSTART - 1) ENVIRON["FV_" substr($0, RSTART + 2, RLENGTH - 4)]
      $0 = substr($0, RSTART + RLENGTH)
    }
    print out $0
  }' "$t"
}

# The PR summary of a flow: a step table, then each review and the
# implementer's responses (the "## Review response" sections of REPORT.md).
flow_summary() { # id
  local d="$TASKS_DIR/$1" n step role round run packet am res
  printf '## Flow: %s\n\n| step | agent | run | result |\n|---|---|---|---|\n' "$FLOW_NAME"
  while IFS=$TAB read -r n step role round run packet; do
    flow_index "$step" || continue
    am=${FS_AGENT[FI]}
    [ -z "${FS_MODEL[FI]}${FS_EFFORT[FI]}" ] || am="$am (${FS_MODEL[FI]:-default}${FS_EFFORT[FI]:+, ${FS_EFFORT[FI]}})"
    [ "$round" = 0 ] || step="$step r$round"
    case $role in
      review)
        res=$(awk 'NF { sub(/[ \t\r]+$/, ""); print; exit }' "$d/flow/$packet/REVIEW.md" 2>/dev/null)
        res="${res#verdict: }, $(grep -cE '^[0-9]+[.)] ' "$d/flow/$packet/REVIEW.md" 2>/dev/null || true) findings" ;;
      fix) res="see review response r$round" ;;
      ship) continue ;;
      *) res="REPORT.md" ;;
    esac
    printf '| %s | %s | %s | %s |\n' "$step" "$am" "$run" "$res"
  done < <(flow_steps "$1")
  while IFS=$TAB read -r n step role round run packet; do
    [ "$role" = review ] && [ -f "$d/flow/$packet/REVIEW.md" ] || continue
    printf '\n### Review r%s (%s)\n\n' "$round" "$step"
    cat "$d/flow/$packet/REVIEW.md"
  done < <(flow_steps "$1")
  [ -f "$d/REPORT.md" ] || return 0
  awk '/^## Review response/ { f = 1; print "\n#" $0; next } /^## / { f = 0 } f' "$d/REPORT.md"
}

# Steps of the current flow, oldest first: n, step, role, round, run, packet.
flow_steps() { # id
  awk -F'\t' '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    $2 == "flow_started" { m = 0 }
    $2 == "flow_step" { s[++m] = kv("n") "\t" kv("step") "\t" kv("role") "\t" kv("round") "\t" kv("run") "\t" kv("packet") }
    END { for (i = 1; i <= m; i++) print s[i] }' "$TASKS_DIR/$1/events.log"
}

# Starts a step: a fresh run, or for resume= the run holding that
# conversation: typed into its pane while it is up and idle (busy: the flow
# waits for its next stop), else relaunched with its conversation id.
flow_start_step() { # id step
  local id=$1 step=$2 d="$TASKS_DIR/$1" role agent model effort conv n packet round=0
  local rid="" sid via=new pane="" run line ship="$CONFIG_DIR/SHIP.md"
  local -a resume=()
  flow_index "$step"
  role=${FS_ROLE[FI]} agent=${FS_AGENT[FI]} model=${FS_MODEL[FI]} effort=${FS_EFFORT[FI]} conv=${FS_CONV[FI]}
  if [ -n "${FS_RESUME[FI]}" ]; then
    rid=$(flow_conv_run "$id" "$conv")
    run_state "$id" "${rid:--}"
    case $RUN_STATE in
      working | waiting) return 0 ;;
      idle)
        via=pane
        pane=$(agent_pane "$id" "$RUN_WIN")
        [ -n "$pane" ] || { flow_stop "$id" launch-failed "no agent pane in run $rid"; return 0; } ;;
      *)
        via=resume
        sid=$(awk -F'\t' -v r="run=$rid id=" '$2 == "agent_session" && index($3, r) == 1 { s = substr($3, length(r) + 1) } END { print s }' "$d/events.log")
        [ -n "$sid" ] || { flow_stop "$id" no-session-id "run $rid logged no conversation id to resume"; return 0; }
        # shellcheck source=/dev/null
        read -r -a resume <<<"$(. "$PLUGIN_DIR/agents/$agent.sh"; echo "${AGENT_RESUME_ID[*]}")"
        resume+=("$sid") ;;
    esac
  fi
  n=$((FLOW_N + 1))
  case $role in review | fix) round=$((FLOW_FIXES + 1)) ;; esac
  packet=$(printf '%02d-%s' "$n" "$step")
  mkdir -p "$d/flow/$packet"
  cp "$d/TASK.md" "$d/flow/$packet/TASK.md"
  case $role in
    review)
      [ ! -f "$d/REPORT.md" ] || cp "$d/REPORT.md" "$d/flow/$packet/REPORT.md"
      line=$(flow_last_packet "$id" review)
      [ -z "$line" ] || [ ! -f "$d/flow/$line/REVIEW.md" ] || cp "$d/flow/$line/REVIEW.md" "$d/flow/$packet/PRIOR-REVIEW.md"
      flow_diff "$id" >"$d/flow/$packet/DIFF.patch"
      flow_trees "$id" >"$d/flow/$packet/TREES" ;;
    fix)
      line=$(flow_last_packet "$id" review)
      cp "$d/flow/$line/REVIEW.md" "$d/flow/$packet/REVIEW.md" ;;
    ship) flow_summary "$id" >"$d/flow/$packet/SUMMARY.md" ;;
  esac
  [ -f "$ship" ] || ship="$PLUGIN_DIR/templates/SHIP.md"
  FV_TASK=$id FV_TASK_DIR=$d FV_FLOW=$FLOW_NAME FV_STEP=$step FV_ROUND=$round \
    FV_PACKET="$d/flow/$packet" FV_SHIP=$(cat "$ship") flow_prompt "$role" >"$d/flow/$packet/PROMPT.md"
  line="Task $id, flow $FLOW_NAME, step $step"
  [ "$round" = 0 ] || line="$line (round $round)"
  line="$line: read $d/flow/$packet/PROMPT.md and follow it."
  if [ "$via" = pane ]; then
    run=$rid
    send_prompt "$pane" "$line"
  elif ! run=$(cmd_run "$id" --agent "$agent" ${model:+--model "$model"} ${effort:+--effort "$effort"} \
    -p "$line" ${resume[@]+-- "${resume[@]}"} >&2 && echo "$RUN_STARTED"); then
    flow_stop "$id" launch-failed "could not start $agent for $step"
    return 0
  fi
  log_event "$id" flow_step "n=$n step=$step role=$role round=$round run=$run via=$via conv=$conv packet=$packet"
}

# Whether a finished step left what its role must produce. Sets FLOW_BAD to
# what is missing ("" if nothing) and FLOW_VERDICT for a review.
flow_check() { # id role packet
  local d="$TASKS_DIR/$1" v
  FLOW_BAD="" FLOW_VERDICT=""
  case $2 in
    implement) [ -s "$d/REPORT.md" ] || FLOW_BAD="write your report to $d/REPORT.md" ;;
    review)
      v=$(awk 'NF { sub(/[ \t\r]+$/, ""); print; exit }' "$d/flow/$3/REVIEW.md" 2>/dev/null) || v=""
      case $v in
        "verdict: ok") FLOW_VERDICT=ok ;;
        "verdict: changes-needed") FLOW_VERDICT=changes-needed ;;
        *) FLOW_BAD="$d/flow/$3/REVIEW.md must start with the line 'verdict: ok' or 'verdict: changes-needed'" ;;
      esac ;;
    fix) grep -q '^## Review response' "$d/REPORT.md" 2>/dev/null || FLOW_BAD="add a '## Review response' section to $d/REPORT.md" ;;
    ship) grep -qE "$PR_RE" "$d/REPORT.md" 2>/dev/null || FLOW_BAD="put the pull request URL in $d/REPORT.md" ;;
  esac
}

# Advances a task's flow by at most one step, under flow/lock. trigger: the
# run whose hook called (an idle step run without the done signal notifies
# then), or "restore"/"continue" (notifies too).
flow_advance() ( # id [trigger]
  local id=$1 trig=${2:-} d="$TASKS_DIR/$1" lock i=0 role next="" pane
  [ -f "$d/flow/FLOW" ] || return 0
  lock="$d/flow/lock"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 600 ] || die "flow: timed out waiting for $lock"
    sleep 0.05
  done
  # shellcheck disable=SC2064
  trap "rmdir $(printf '%q' "$lock")" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  flow_parse "$d/flow/FLOW"
  flow_state "$id"
  [ "$FLOW_STATUS" = running ] || return 0
  if [ "$FLOW_N" = 0 ]; then
    flow_start_step "$id" "${FS_NAME[0]}"
    return 0
  fi
  # continued after the loop limit: one more review of what is there now
  if [ "$FLOW_CONT" = 1 ] && [ "$FLOW_REASON" = limit ]; then
    flow_start_step "$id" "$FLOW_REVIEW"
    return 0
  fi
  flow_index "$FLOW_STEP"
  role=${FS_ROLE[FI]}
  run_state "$id" "$FLOW_RUN"
  # done means signalled and stopped: a step still at work is not finished
  case $RUN_STATE in working | waiting) return 0 ;; esac
  if [ ! -f "$d/flow/$FLOW_PACKET/DONE" ]; then
    case $RUN_STATE in
      gone)
        if [ "$FLOW_CONT" = 1 ]; then
          flow_start_step "$id" "$FLOW_STEP"
        else
          flow_stop "$id" run-exited "run $FLOW_RUN ended without the done signal"
        fi ;;
      idle)
        case $trig in "$FLOW_RUN" | restore | continue)
          flow_notify "$id" "$FLOW_RUN" "$FLOW_STEP stopped without the done signal; answer it or tell it to finish" ;;
        esac ;;
    esac
    return 0
  fi
  if [ "$role" = review ] && [ "$(flow_trees "$id")" != "$(cat "$d/flow/$FLOW_PACKET/TREES")" ]; then
    flow_stop "$id" worktree-changed "the reviewer changed a worktree"
    return 0
  fi
  flow_check "$id" "$role" "$FLOW_PACKET"
  if [ -n "$FLOW_BAD" ]; then
    rm -f "$d/flow/$FLOW_PACKET/DONE"
    pane=""
    [ "$FLOW_RETRY" = 1 ] || [ "$RUN_STATE" != idle ] || pane=$(agent_pane "$id" "$RUN_WIN")
    if [ -n "$pane" ]; then
      log_event "$id" flow_retry "n=$FLOW_N"
      send_prompt "$pane" "Step $FLOW_STEP is not complete: $FLOW_BAD. Then run collie flow done again."
    else
      flow_stop "$id" invalid-artifact "$FLOW_BAD"
    fi
    return 0
  fi
  if [ "$role" = review ]; then
    grep -q "${TAB}flow_verdict${TAB}n=$FLOW_N " "$d/events.log" ||
      log_event "$id" flow_verdict "n=$FLOW_N step=$FLOW_STEP round=$FLOW_ROUND verdict=$FLOW_VERDICT"
    if [ "$FLOW_VERDICT" = changes-needed ]; then
      if [ "$FLOW_STEP" != "$FLOW_REVIEW" ]; then
        flow_stop "$id" changes-needed "the review asks for changes"
      elif [ "$FLOW_FIXES" -lt "$FLOW_MAX" ]; then
        flow_start_step "$id" "$FLOW_FIX"
      else
        flow_stop "$id" limit "still changes-needed after $FLOW_MAX fix rounds"
      fi
      return 0
    fi
  fi
  if [ "$FLOW_STEP" = "$FLOW_FIX" ]; then
    next=$FLOW_REVIEW
  else
    for ((i = FI + 1; i < ${#FS_NAME[@]}; i++)); do
      [ "${FS_NAME[i]}" = "$FLOW_FIX" ] || { next=${FS_NAME[i]}; break; }
    done
  fi
  if [ -n "$next" ]; then
    flow_start_step "$id" "$next"
    return 0
  fi
  next=$(grep -oE -m1 "$PR_RE" "$d/REPORT.md" 2>/dev/null) || next=""
  log_event "$id" flow_done "n=$FLOW_N${next:+ pr=$next}"
  flow_notify "$id" "$FLOW_RUN" "finished${next:+: $next}"
)
