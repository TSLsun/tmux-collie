# shellcheck shell=bash
# Sourced by bin/collie: peek, send, and pause.

# Resolve a run target shared by send and peek, as
# "run<TAB>agent<TAB>state<TAB>window". Explicit runs resolve even when their
# state is exited; callers decide whether state matters.
run_target() { # id run repo [include_exited]
  local wins="" all=${4:-0}
  ! has_session "$1" || wins=$(win_states -t "=$1" | awk -F'\t' '$3 != "-" { print $3 "\t" $4 "\t" $5 "\t" $2 }')
  awk -F'\t' -v want="$2" -v repo="$3" -v all="$all" "$AWK_KV"'
    FNR == NR { if ($1 != "") { line[$1] = $0; st[$1] = $3; order[++m] = $1 }; next }
    $2 == "run_started" { r = kv("run"); known[r] = 1; rp[r] = kv("repo"); ag[r] = kv("agent") }
    END {
      if (want != "") {
        if (!(want in known)) print "nosuch"
        else print (want in line ? line[want] : want "\t" ag[want] "\texited\t-")
        exit
      }
      for (i = 1; i <= m; i++) {
        r = order[i]
        if (repo != "" && rp[r] != repo) continue
        if (st[r] == "exited") {
          if (all) { ec++; epick = line[r]; eruns = eruns " " r }
          continue
        }
        c++; pick = line[r]; runs = runs " " r
      }
      if (!c && all) { c = ec; pick = epick; runs = eruns }
      print (c == 1 ? pick : c ? "many" runs : "none")
    }' - "$TASKS_DIR/$1/events.log" <<<"$wins"
}


# Prints the last N joined lines from a live run pane, without logging or
# changing tmux state. Runs in any state are readable.
cmd_peek() {
  local id="" repo="" run="" lines=40 t agent st win pane
  while [ $# -gt 0 ]; do
    case $1 in
      -r) need_value peek "-r needs a repo" "${2:-}"; repo=$2; shift ;;
      --run) need_value peek "--run needs a run number" "${2:-}"; run=$2; shift ;;
      -n) need_value peek "-n needs a line count" "${2:-}"; lines=$2; shift ;;
      -*) die "peek: unknown option $1" ;;
      *) [ -z "$id" ] || die "peek: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [[ $run =~ ^[1-9][0-9]*$ ]] || [ -z "$run" ] || die "peek: --run needs a run number"
  [[ $lines =~ ^[1-9][0-9]*$ ]] || die "peek: -n needs a positive line count"
  [ "${#lines}" -le 6 ] && [ "$lines" -le 100000 ] || die "peek: -n must not exceed 100000"
  [ -z "$run" ] || [ -z "$repo" ] || die "peek: give -r or --run, not both"
  command -v tmux >/dev/null || die "peek: tmux required"
  if [ -n "$repo" ] && ! awk -F'\t' -v r="$repo" '$1 == r { f = 1 } END { exit !f }' "$TASKS_DIR/$id/repos.tsv"; then
    die "repo '$repo' is not part of task '$id'"
  fi
  t=$(run_target "$id" "$run" "$repo" 1)
  case $t in
    nosuch) die "peek: task '$id' has no run $run" ;;
    none) warn "peek: no live agent run in task '$id'${repo:+ for repo $repo}"; exit 3 ;;
    many*) t=${t#many }; die "peek: several live runs in task '$id' ($t). Choose one with --run N, e.g. collie peek $id --run ${t%% *}" ;;
  esac
  IFS=$TAB read -r run agent st win <<<"$t"
  pane=$(agent_pane "$id" "$win")
  [ -n "$pane" ] || { warn "peek: pane of run $run ($agent) is gone"; exit 3; }
  pane_tail "$pane" "$lines" || {
    warn "peek: pane of run $run ($agent) is gone"; exit 3
  }
}

# Types text into a collie run, normally only while idle or waiting, and
# logs the first line. Exit 2: working without --force or a startup trust
# dialog; 3: no live run.
cmd_send() {
  local id="" repo="" run="" file="" wait=0 force=0 text="" args=() t agent st win pane first force_field="" rc=0
  while [ $# -gt 0 ]; do
    case $1 in
      -r) need_value send "-r needs a repo" "${2:-}"; repo=$2; shift ;;
      --run) need_value send "--run needs a run number" "${2:-}"; run=$2; shift ;;
      -f) need_value send "-f needs a file" "${2:-}"; file=$2; shift ;;
      --wait) wait=1 ;;
      --force) force=1 ;;
      --) shift; args+=("$@"); break ;;
      -*) die "send: unknown option $1" ;;
      *) if [ -z "$id" ]; then id=$1; else args+=("$1"); fi ;;
    esac
    shift
  done
  [ -n "$id" ] || die "usage: collie send <id> [-r repo | --run N] [--wait] [--force] <text>... | -f file"
  task_id "$id"
  [ -z "$run" ] || [[ $run =~ ^[1-9][0-9]*$ ]] || die "send: --run needs a run number"
  [ -z "$run" ] || [ -z "$repo" ] || die "send: give -r or --run, not both"
  if [ -n "$file" ]; then
    [ ${#args[@]} -eq 0 ] || die "send: give text or -f, not both"
    if [ "$file" = - ]; then
      text=$(cat)
    else
      [ -f "$file" ] && [ -r "$file" ] || die "send: cannot read $file"
      text=$(cat -- "$file")
    fi
  else
    text=${args[*]-}
  fi
  [[ $text == *[![:space:]]* ]] || die "send: nothing to send"
  command -v tmux >/dev/null || die "send: tmux required"
  if [ -n "$repo" ] && ! awk -F'\t' -v r="$repo" '$1 == r { f = 1 } END { exit !f }' "$TASKS_DIR/$id/repos.tsv"; then
    die "repo '$repo' is not part of task '$id'"
  fi

  while :; do
    t=$(run_target "$id" "$run" "$repo")
    case $t in
      nosuch) die "send: task '$id' has no run $run" ;;
      none) warn "send: no live agent run in task '$id'${repo:+ for repo $repo}; not sent"; exit 3 ;;
      many*) die "send: several live runs in task '$id' (${t#many }); pick one with --run" ;;
    esac
    IFS=$TAB read -r run agent st win <<<"$t"
    [ "$st" = working ] && [ "$wait" = 1 ] && [ "$force" = 0 ] || break
    sleep 1
  done
  case $st in
    idle | waiting) ;;
    working) if [ "$force" != 1 ]; then
      warn "send: run $run ($agent) is working; not sent (--wait waits for its turn to end; --force sends anyway)"; exit 2
    fi ;;
    *) warn "send: run $run ($agent) has exited; not sent"; exit 3 ;;
  esac
  pane=$(agent_pane "$id" "$win")
  [ -n "$pane" ] || { warn "send: the pane of run $run ($agent) is gone; not sent"; exit 3; }
  type_into "$pane" "$text" || rc=$?
  if [ "$rc" = 2 ]; then
    warn "send: run $run ($agent) is at a startup dialog that needs a human; not sent (answer it in $win)"
    exit 2
  fi
  [ "$rc" = 0 ] || return "$rc"
  first=${text%%$'\n'*}
  first=${first//$'\t'/ }
  [ "$force" = 0 ] || force_field=" force=1"
  log_event "$id" sent "run=$run${force_field} text=${first:0:80}"
  echo "$id: sent to run $run ($agent) in $win"
}

# Asks the idle agent of a collie run to pause, through send. How to pause
# and pick up (safe boundary, wip commit, note contents) is the collie-lead
# skill's, not collie's. Exit 2: the agent is working or waiting.
cmd_pause() {
  local id="" repo="" run="" text="" file="" t agent st
  while [ $# -gt 0 ]; do
    case $1 in
      -r) need_value pause "-r needs a repo" "${2:-}"; repo=$2; shift ;;
      --run) need_value pause "--run needs a run number" "${2:-}"; run=$2; shift ;;
      -p) [ $# -ge 2 ] || die "pause: -p needs a request"; text=$2; shift ;;
      -f) need_value pause "-f needs a file" "${2:-}"; file=$2; shift ;;
      -*) die "pause: unknown option $1" ;;
      *) [ -z "$id" ] || die "pause: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [ -z "$text" ] || [ -z "$file" ] || die "pause: give -p or -f, not both"
  [ -n "$text$file" ] || text=${PAUSE_PROMPT//.collie\//$TASKS_DIR/$id/}
  # send reports a missing, ambiguous or exited run; pause also spares a
  # waiting one, whose prompt the request would answer
  t=$(run_target "$id" "$run" "$repo")
  case $t in
    nosuch | none | many*) ;;
    *)
      IFS=$TAB read -r run agent st _ <<<"$t"
      case $st in working | waiting)
        warn "pause: run $run ($agent) is $st, not idle; not sent (collie wait $id --run $run)"
        exit 2
        ;;
      esac
      repo=""
      ;;
  esac
  if [ -n "$file" ]; then
    cmd_send "$id" ${repo:+-r "$repo"} ${run:+--run "$run"} -f "$file"
  else
    cmd_send "$id" ${repo:+-r "$repo"} ${run:+--run "$run"} -- "$text"
  fi
}


 
