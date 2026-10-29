# shellcheck shell=bash
# Sourced by bin/collie: agent runtime.

# --- agent runtime ----------------------------------------------------------

DEFAULT_PROMPT='Your task contract is .collie/TASK.md. Read it first; if its Objective is empty, ask me what to do. When you finish, write a short report to .collie/REPORT.md.'

# Agent windows as "session<TAB>window<TAB>run<TAB>agent<TAB>state". Agents
# without hooks count as idle after @collie-silence seconds (30) of no output.
win_states() { # list-windows target args
  local silence=${COLLIE_SILENCE:-$(tmux_opt @collie-silence)}
  stamp %s
  { tmux list-windows "$@" -F '#{session_name}|#{window_id}|#{@collie_run}|#{@collie_agent}|#{@collie_state}|#{@collie_hooks}|#{window_activity}' 2>/dev/null || true; } |
    awk -F'|' -v now="$NOW" -v s="${silence:-30}" '
      $5 == "" { next }
      { st = $5 }
      st == "working" && $6 == "0" && now - $7 >= s { st = "idle" }
      { print $1 "\t" $2 "\t" ($3 == "" ? "-" : $3) "\t" ($4 == "" ? "-" : $4) "\t" st }'
}

# Agents started by hand in a session (not via `collie run`) as
# "-<TAB>agent<TAB>state<TAB>window<TAB>pane<TAB>pid<TAB>path": panes with a
# known agent among their process or its descendants (up to 6 levels; agents
# inside another agent don't count). Without hooks the state is working until
# @collie-silence seconds without output, then idle.
manual_runs() { # session
  local silence=${COLLIE_SILENCE:-$(tmux_opt @collie-silence)}
  stamp %s
  awk -v now="$NOW" -v s="${silence:-30}" '
    function base(p) { sub(/.*\//, "", p); sub(/\.(js|mjs|ts)$/, "", p); return p }
    BEGIN { n = split("claude codex gemini omp aider", k, " "); for (i = 1; i <= n; i++) known[k[i]] = 1 }
    FNR == NR {
      par[$1] = $2
      a = base($3)
      if ((a == "node" || a == "bun") && $4 != "") a = base($4)
      if (a in known) ag[$1] = a
      next
    }
    FNR == 1 {
      # each outermost agent marks its ancestors as the panes it may run in
      for (p in ag) {
        for (q = par[p]; q + 0 > 1 && !(q in ag); q = par[q]) if (++up[p] > 6) break
        if (q in ag) continue
        for (q = p; q + 0 > 1 && dn[p]++ <= 6; q = par[q]) if (!(q in at)) { at[q] = ag[p]; atp[q] = p }
      }
    }
    { split($0, f, "|"); a = at[f[1]]; pid = atp[f[1]] }
    f[3] != "" { next }
    a != "" { print "-\t" a "\t" (now - f[4] >= s ? "idle" : "working") "\t" f[2] "\t" f[5] "\t" pid "\t" f[6] }' \
    <(ps -ww -A -o pid=,ppid=,args=) \
    <(tmux list-panes -s -t "$1" -F '#{pane_pid}|#{window_id}|#{@collie_state}|#{window_activity}|#{pane_id}|#{pane_current_path}' 2>/dev/null || true)
}

# Runs of a task as "run<TAB>agent<TAB>state<TAB>window": agent windows (also
# agents started by hand, run "-"), then
# runs started but never seen exiting (exited if the session is up, unknown if
# it is gone).
task_runs() {
  local id=$1 wins="" fallback=unknown
  fm_get "$TASKS_DIR/$id/TASK.md" status
  case $FM in done | archived) fallback=exited ;; esac
  if has_session "$id"; then
    fallback=exited
    wins=$(win_states -t "=$id" | awk -F'\t' '{ print $3 "\t" $4 "\t" $5 "\t" $2 }'; manual_runs "=$id" | cut -f1-4)
  fi
  [ -z "$wins" ] || printf '%s\n' "$wins"
  awk -F'\t' -v fb="$fallback" '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    FNR == NR { seen[$1] = 1; next }
    $2 == "run_started" { r = kv("run"); agent[r] = kv("agent"); order[++n] = r }
    $2 == "run_exited" || $2 == "run_restored" { ended[kv("run")] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        r = order[i]
        if (!(r in ended) && !(r in seen)) print r "\t" agent[r] "\t" fb "\t-"
      }
    }' - "$TASKS_DIR/$id/events.log" <<<"$wins"
}

# The agent's pane in window $2 of task $1 while it is still there, or
# nothing: @collie_pane of a `collie run` window, the pane of an agent
# started by hand, or the only pane of a run window from before @collie_pane.
# Never the window's active pane: in a split window that may be a shell.
agent_pane() { # id window
  local panes pane
  panes=$(tmux list-panes -t "$2" -F '#{pane_id}' 2>/dev/null) || return 0
  pane=$(tmux show-options -wqv -t "$2" @collie_pane 2>/dev/null || true)
  if [ -z "$pane" ]; then
    if [ -z "$(tmux show-options -wqv -t "$2" @collie_run 2>/dev/null || true)" ]; then
      pane=$(manual_runs "=$1" | awk -F'\t' -v w="$2" '$4 == w { print $5; exit }')
    elif [ "$(wc -l <<<"$panes")" -eq 1 ]; then
      pane=$panes
    fi
  fi
  [ -z "$pane" ] || ! grep -qxF -- "$pane" <<<"$panes" || echo "$pane"
}

# Most urgent run of a task as "state<TAB>window<TAB>live agents", or
# "-<TAB>-<TAB>"; live agents are the distinct agents not exited, each
# followed by a space.
task_top() {
  task_runs "$1" | awk -F'\t' '
    BEGIN { n = split("waiting idle working exited unknown", o, " "); for (i = 1; i <= n; i++) r[o[i]] = i; b = n + 1; best = "-"; w = "-" }
    ($3 in r) && r[$3] < b { b = r[$3]; best = $3; w = $4 }
    $3 != "exited" && $3 != "unknown" && !s[$2]++ { ag = ag $2 " " }
    END { print best "\t" w "\t" ag }'
}

# Task status: done/archived as written by done/archive/gc, else derived:
# todo (no run yet), review (no agent working or waiting, and REPORT.md
# written since the last run started), else active. Other stored values
# (old records: todo, blocked, ...) are ignored. Sets STATUS, LAST_EVENT
# (the last event's time, empty for done/archived), and STATUS_NOTE when
# agents are quiet but the last run left no REPORT.md (stays active).
task_status() { # id top_state [stored_status]
  local d st last runs
  d="$TASKS_DIR/$1"
  STATUS_NOTE=""
  LAST_EVENT=""
  if [ $# -ge 3 ]; then
    st=$3
  else
    fm_get "$d/TASK.md" status
    st=$FM
  fi
  case $st in done | archived) STATUS=$st; return ;; esac
  last=$(awk -F'\t' '$2 == "run_started" { t = $1; n++ } END { print n + 0 "\t" t "\t" $1 }' "$d/events.log")
  runs=${last%%"$TAB"*}
  last=${last#*"$TAB"}
  LAST_EVENT=${last#*"$TAB"}
  last=${last%%"$TAB"*}
  if [ -z "$last" ]; then
    STATUS=todo
  elif [ "$2" = working ] || [ "$2" = waiting ]; then
    STATUS=active
  elif [ -f "$d/REPORT.md" ] &&
    ! [[ $(date -u -r "$d/REPORT.md" +%Y-%m-%dT%H:%M:%SZ) < $last ]]; then
    STATUS=review
  else
    STATUS=active
    STATUS_NOTE="no REPORT.md since run $runs"
  fi
}

# When a task was finished (done/archive), from its last task_done or
# task_archived event; "" if never.
finished_at() { # id
  awk -F'\t' '$2 == "task_done" || $2 == "task_archived" { t = $1 } END { print t }' "$TASKS_DIR/$1/events.log"
}

# Sets START to the commit a repo's worktree was created at ("" if unknown).
repo_start() { # dir name
  START=$(awk -F'\t' -v n="repo=$2 " '
    $2 == "worktree_created" && index($3, n) == 1 {
      k = split($3, a, " "); for (i = 1; i <= k; i++) if (index(a[i], "start=") == 1) s = substr(a[i], 7)
    }
    END { print s }' "$1/events.log")
}

# A repo's branch commits, then their diff stat: since it forked from the
# default base (squash-merged or unmerged: a rebase onto base is not counted),
# or, once its tip is in base, since its worktree was created. Prints nothing
# once the branch is gone.
repo_commits() { # dir name common branch
  local tip from=""
  [ "$3" != - ] || return 0
  tip=$(git --git-dir="$3" rev-parse -q --verify "refs/heads/$4") || return 0
  printf '== %s  %s  %s\n' "$2" "$4" "$(git --git-dir="$3" rev-parse --short "$tip")"
  if default_base "$3" && ! git --git-dir="$3" merge-base --is-ancestor "$tip" "$BASE"; then
    from=$(git --git-dir="$3" merge-base "$BASE" "$tip") || from=""
  fi
  if [ -z "$from" ]; then
    repo_start "$1" "$2"
    from=$START
  fi
  [ -n "$from" ] || return 0
  git --git-dir="$3" log --oneline "$from..$tip"
  git --git-dir="$3" diff --stat "$from" "$tip"
}

# A task's commits: the snapshot done/archive took, else read from its
# branches; with neither, a pointer to the PR named in REPORT.md.
task_commits() { # id
  local d="$TASKS_DIR/$1" name c b out _
  if [ -f "$d/commits.txt" ]; then
    out=$(cat "$d/commits.txt")
  else
    out=$(while IFS=$TAB read -r name c b _; do repo_commits "$d" "$name" "$c" "$b"; done <"$d/repos.tsv")
  fi
  if [ -z "$out" ] && [ -f "$d/REPORT.md" ]; then
    out=$(grep -oE -m1 "$PR_RE" "$d/REPORT.md") && out="(branches gone; see $out)"
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# @collie-notify / $COLLIE_NOTIFY: on (default), off, or a command that gets
# title and body as arguments.
# With terminal-notifier installed and a pane given, clicking the notification
# focuses the terminal (@collie-terminal bundle id) and jumps to that pane.
notify() { # title body [pane]
  local how=${COLLIE_NOTIFY-$(tmux_opt @collie-notify)} app
  case $how in
    off) ;;
    "" | on)
      if [ -n "${3:-}" ] && command -v terminal-notifier >/dev/null; then
        app=$(tmux_opt @collie-terminal)
        terminal-notifier -title "$1" -message "$2" -group "collie-$3" \
          -activate "${app:-${__CFBundleIdentifier:-com.apple.Terminal}}" \
          -execute "$(printf 'PATH=%q TMUX=%q %q %q _jump %q' "$PATH" "${TMUX:-}" "$BASH" "$PLUGIN_DIR/bin/collie" "$3")"
      elif command -v osascript >/dev/null; then
        osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' "$1" "$2"
      elif command -v notify-send >/dev/null; then
        notify-send "$1" "$2"
      fi
      ;;
    *) sh -c "$how \"\$1\" \"\$2\"" sh "$1" "$2" ;;
  esac
}

# Records a state change for the window of a pane; ignores non-collie windows.
set_state() { # pane state [expected-codex-pending-token]
  local info id run old wid agent active attached msg applied
  info=$(tmux display-message -p -t "$1" '#{@collie_task}|#{@collie_run}|#{@collie_state}|#{window_id}|#{@collie_agent}|#{window_active}|#{session_attached}' 2>/dev/null) || return 0
  IFS='|' read -r id run old wid agent active attached <<<"$info"
  [ -n "$id" ] && [ -f "$TASKS_DIR/$id/TASK.md" ] || return 0
  [ "$2" != "$old" ] || return 0
  if [ -n "${3:-}" ]; then
    # Compare and update on the tmux server: Stop cannot invalidate an
    # observer between its token check and a stale waiting state write.
    applied=$(tmux if-shell -F -t "$1" "#{==:#{@collie_codex_pending},$3}" \
      "set-option -w -t $wid @collie_state $2 ; display-message -p changed" 2>/dev/null) || return 0
    [ "$applied" = changed ] || return 0
  else
    tmux set-option -w -t "$wid" @collie_state "$2" 2>/dev/null || return 0
  fi
  log_event "$id" agent_state "run=${run:--} state=$2"
  # no popup for the window you are looking at
  [ "$active" = 1 ] && [ "${attached:-0}" -gt 0 ] && return 0
  case $2:$old in
    waiting:*) msg="is waiting for you" ;;
    idle:working) msg="finished its turn" ;;
    *) return 0 ;;
  esac
  # target of `collie _jump` (menu: jump to alert)
  tmux set-option -g @collie-last-pane "$1" 2>/dev/null || true
  (
    # A hook may have resolved this state before notification delivery.
    [ "$(tmux show-options -wqv -t "$wid" @collie_state 2>/dev/null)" = "$2" ] || exit 0
    [ -z "${3:-}" ] || [ "$(tmux show-options -wqv -t "$wid" @collie_codex_pending 2>/dev/null)" = "$3" ] || exit 0
    notify "collie: $id" "${agent:-agent} $msg" "$1"
  ) >/dev/null 2>&1 &
}

# Switches a client to a pane (default "-": the last one that notified).
cmd__jump() { # [pane|-] [client]
  local pane=${1:--}
  [ "$pane" != - ] || pane=$(tmux_opt @collie-last-pane)
  if [ -z "$pane" ] || ! tmux display-message -p -t "$pane" '' >/dev/null 2>&1; then
    tmux display-message "collie: no agent pane to jump to" 2>/dev/null || true
    die "no agent pane to jump to"
  fi
  tmux switch-client ${2:+-c "$2"} -t "$pane" \; select-window -t "$pane" \; select-pane -t "$pane"
}
