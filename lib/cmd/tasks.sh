# shellcheck shell=bash
# Sourced by bin/collie: new, add, ls, show, edit, go, set.

cmd_new() {
  local id="" specs="" ws="" type=feat title="" from="" edit=0 window=1
  local goal="" asked=0 t ship=${COLLIE_SHIP-$(tmux_opt @collie-ship)}
  local run=0 agent="" runargs=()
  case $ship in on | 1 | yes | true) ship=1 ;; *) ship=0 ;; esac
  while [ $# -gt 0 ]; do
    case $1 in
      -r) specs="$specs${2:?-r needs a repo}"$'\n'; shift ;;
      -w) ws=${2:?-w needs a workspace}; shift ;;
      -m) goal=${2:?-m needs text}; shift ;;
      -t) type=${2:?-t needs a type}; shift ;;
      --title) title=${2:?--title needs text}; shift ;;
      --from) from=${2:?--from needs a ref}; shift ;;
      --edit) edit=1 ;;
      --no-window) window=0 ;;
      --ship) ship=1 ;;
      --no-ship) ship=0 ;;
      --run) run=1 ;;
      --agent) agent=${2:?--agent needs a name}; run=1; shift ;;
      -p) [ $# -ge 2 ] || die "-p needs a prompt"; runargs+=(-p "$2"); run=1; shift ;;
      --) shift; runargs+=(-- "$@"); run=1; break ;;
      -*) die "new: unknown option $1" ;;
      *) [ -z "$id" ] || die "new: too many arguments"; id=$1 ;;
    esac
    shift
  done
  # no id on a terminal (e.g. the menu popup): show what will be asked, then ask
  if [ -z "$id" ] && [ -t 0 ]; then
    local where base=${from:-}
    [ -n "$agent" ] || { run_agent; agent=$RUN_AGENT; }
    if [ -n "$ws" ]; then
      where="workspace $ws"
    elif [ -n "$specs" ]; then
      where=$(printf '%s' "$specs" | tr '\n' ' ')
    elif ! repo_at .; then
      where="folder $(pwd -P) (current pane)"
    else
      where="$R_NAME (current pane)"
      if [ -z "$base" ]; then
        default_base "$R_COMMON" || true
        base=$(git --git-dir="$R_COMMON" rev-parse --abbrev-ref "$BASE" 2>/dev/null) || true
      fi
    fi
    printf 'new task in %s\n' "$where"
    printf '  %-10s %-12s %s\n' branch '<type>/<id>' "from ${base:-the default branch}" \
      id required '[a-z0-9-], max 40' \
      type "$type" 'e.g. fix, refactor, docs' \
      objective optional 'goes into TASK.md' \
      ship "$([ "$ship" = 1 ] && echo on || echo off)" 'agent pushes, opens a PR, checks CI' \
      agent "$agent" "$([ "$run" = 1 ] && echo 'starts after creation' || echo 'asked if an objective is given')"
    echo
    read -r -e -p "task id: " id
    read -r -e -p "type [$type]: " t && type=${t:-$type}
    [ -n "$goal" ] || read -r -e -p "objective (optional): " goal
    read -r -e -p "ship [$([ "$ship" = 1 ] && echo Y/n || echo y/N)]: " t
    case $t in [yY]*) ship=1 ;; [nN]*) ship=0 ;; esac
    if [ -n "$goal" ] && [ "$run" = 0 ] && command -v tmux >/dev/null; then
      read -r -e -p "start $agent now [Y/n]: " t
      case $t in [nN]*) ;; *) run=1 ;; esac
    fi
    asked=1
  fi
  [ -n "$id" ] || die "usage: collie new <id> [-r repo[:branch]]... [-w workspace] ..."
  if [ "$run" = 1 ]; then
    [ "$window" = 1 ] || die "new: --run needs a session; drop --no-window"
    command -v tmux >/dev/null || die "new: --run needs tmux"
  fi
  valid_id "$id" || die "invalid id '$id' (use [a-z0-9-], max 40, no leading '-')"
  local tdir r
  tdir="$TASKS_DIR/$id"
  [ ! -e "$tdir" ] || die "task '$id' already exists"
  if [ -n "$ws" ]; then
    r=$(workspace_repos "$ws") || exit 1
    for r in $r; do specs="$specs$r"$'\n'; done
  fi
  # the current repo, else the current directory as a folder
  [ -n "$specs" ] || specs="$(pwd -P)"$'\n'

  if ! create_repos "$id" "$type/$id" "$from" "$specs"; then
    rm -rf "$tdir"
    exit 1
  fi
  write_task_md "$tdir" "$id" "${title:-$id}" "$goal" "$ship"
  log_event "$id" task_created
  [ "$edit" -eq 0 ] || cmd_edit "$id"
  printf '%s\n' "${NEW_PATHS%%$'\n'*}"
  if [ "$window" -eq 1 ] && command -v tmux >/dev/null; then
    ensure_session "$id"
    # the task exists either way: a failed run is reported, not rolled back
    local rc=0
    [ "$run" = 0 ] || (cmd_run "$id" ${agent:+--agent "$agent"} ${runargs[@]+"${runargs[@]}"}) || rc=$?
    [ "$asked" -eq 0 ] || [ -z "${TMUX:-}" ] || tmux switch-client -t "=$id"
    if [ "$rc" -ne 0 ]; then
      warn "task '$id' created; start the agent with: collie run $id"
      # the popup closes on exit: keep the error on screen until a key
      [ "$asked" -eq 0 ] || read -rsn1 -p '[press any key]' _ || true
      exit "$rc"
    fi
  fi
}

cmd_add() {
  local id="" specs="" from="" window=1
  while [ $# -gt 0 ]; do
    case $1 in
      -r) specs="$specs${2:?-r needs a repo}"$'\n'; shift ;;
      --from) from=${2:?--from needs a ref}; shift ;;
      --no-window) window=0 ;;
      -*) die "add: unknown option $1" ;;
      *) [ -z "$id" ] || die "add: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [ -n "$specs" ] || die "usage: collie add [<id>] -r repo[:branch]..."
  local branch
  IFS=$TAB read -r _ _ branch _ <"$TASKS_DIR/$id/repos.tsv"
  [ "$branch" != - ] || branch=feat/$id
  create_repos "$id" "$branch" "$from" "$specs"
  if [ "$window" -eq 1 ] && has_session "$id"; then
    local name c b p
    while IFS=$TAB read -r name c b p; do
      case $'\n'$NEW_PATHS$'\n' in *$'\n'"$p"$'\n'*) open_window "$id" "$name" "$p" ;; esac
    done <"$TASKS_DIR/$id/repos.tsv"
  fi
}

# What a task needs from you, first match: answer (an agent waits for
# permission or input), review (status review), reply (an agent finished its
# turn without a fresh report), - (an agent is working, or the task is
# finished), start (todo), else stalled (active, no live agent). Sets NEEDS.
task_needs() { # status top_state
  case $1:$2 in
    done:* | archived:*) NEEDS=- ;;
    *:waiting) NEEDS=answer ;;
    review:*) NEEDS=review ;;
    *:idle) NEEDS=reply ;;
    *:working) NEEDS=- ;;
    todo:*) NEEDS=start ;;
    *) NEEDS=stalled ;;
  esac
}

# shellcheck disable=SC2120  # -a comes from the CLI; internal callers pass none
# Columns: id, status, priority, session (*|-), agent, repos, needs.
cmd_ls() {
  local all=0 d id st top mark repos name _
  [ "${1:-}" != -a ] || all=1
  load_tmux_state
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    id=${d##*/}
    fm_get "$d/TASK.md" status
    st=$FM
    case $st in done | archived) [ "$all" -eq 1 ] || continue ;; esac
    mark=-
    if has_session "$id"; then mark='*'; fi
    top=$(task_top "$id")
    top=${top%%"$TAB"*}
    repos=""
    while IFS=$TAB read -r name _ || [ -n "$name" ]; do repos="$repos${repos:+,}$name"; done <"$d/repos.tsv"
    task_status "$id" "$top" "$st"
    task_needs "$STATUS" "$top"
    fm_get "$d/TASK.md" priority
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$STATUS" "$FM" "$mark" \
      "$top" "$repos" "$NEEDS"
  done
}

cmd_show() {
  local id d name c b p mark top gone=missing fin=0
  task_id "${1:-}"
  d="$TASKS_DIR/$id"
  awk 'NR == 1 { next } $0 == "---" { exit } /^(status|next):/ { next } { print }' "$d/TASK.md"
  top=$(task_top "$id")
  task_status "$id" "${top%%"$TAB"*}"
  printf 'status: %s%s\n' "$STATUS" "${STATUS_NOTE:+ ($STATUS_NOTE)}"
  case $STATUS in done | archived)
    fin=1 gone=removed
    printf 'finished: %s\n' "$(finished_at "$id")"
    ;;
  esac
  echo
  # the contract: TASK.md after its frontmatter
  awk 'NR == 1 && $0 == "---" { f = 1; next }
    f == 1 { if ($0 == "---") f = 2; next }
    !s && !NF { next }
    { s = 1; print }' "$d/TASK.md"
  echo
  echo "repos:"
  while IFS=$TAB read -r name c b p; do
    mark=""
    [ -d "$p" ] || mark=" ($gone)"
    printf '  %s\t%s\t%s%s\n' "$name" "$b" "$p" "$mark"
  done <"$d/repos.tsv"
  echo
  echo "runs:"
  task_runs "$id" | sed 's/^/  /'
  echo
  echo "events:"
  tail -n 5 "$d/events.log" | sed 's/^/  /'
  [ "$fin" -eq 1 ] || return 0
  echo
  echo "commits:"
  task_commits "$id" | sed 's/^/  /'
  if [ -f "$d/REPORT.md" ]; then
    echo
    echo "report:"
    sed 's/^/  /' "$d/REPORT.md"
  fi
}

# Finished tasks, newest first: finish date, status, id, title, branches, PR
# (#n of the first pull/merge request URL in REPORT.md). A pattern keeps the
# tasks whose TASK.md or REPORT.md contains it, ignoring case.
history_rows() { # [pattern]
  local d st title bs name b rep fin _
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    fm_get "$d/TASK.md" status
    st=$FM
    case $st in done | archived) ;; *) continue ;; esac
    [ -z "${1:-}" ] || grep -qsiF -- "$1" "$d/TASK.md" "$d/REPORT.md" || continue
    fm_get "$d/TASK.md" title
    title=$FM
    bs=""
    while IFS=$TAB read -r name _ b _ || [ -n "$name" ]; do bs="$bs${bs:+,}$b"; done <"$d/repos.tsv"
    rep=""
    [ ! -f "$d/REPORT.md" ] || rep="$d/REPORT.md"
    fin=$(awk -F'\t' -v re="$PR_RE" '
      FNR == NR { if ($2 == "task_done" || $2 == "task_archived") t = substr($1, 1, 10); next }
      pr == "" && match($0, re) {
        pr = substr($0, RSTART, RLENGTH); sub(/.*\//, "#", pr)
      }
      END { print (t == "" ? "-" : t) "\t" (pr == "" ? "-" : pr) }' "$d/events.log" ${rep:+"$rep"})
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${fin%%"$TAB"*}" "$st" "${d##*/}" "$title" "$bs" "${fin#*"$TAB"}"
  done | sort -t "$TAB" -k1,1r -k3,3
}

cmd_history() {
  local list=0 pat="" rows self
  while [ $# -gt 0 ]; do
    case $1 in
      -n) list=1 ;;
      -*) die "history: unknown option $1" ;;
      *) [ -z "$pat" ] || die "history: too many arguments"; pat=$1 ;;
    esac
    shift
  done
  if [ "$list" -eq 1 ] || [ ! -t 1 ] || ! command -v fzf >/dev/null; then
    history_rows "$pat"
    return
  fi
  rows=$(history_rows "$pat")
  [ -n "$rows" ] || die "history: no finished tasks${pat:+ matching $pat}"
  self="'$BASH' '$PLUGIN_DIR/bin/collie'"
  printf '%s\n' "$rows" | fzf --delimiter='\t' --no-sort --prompt='history> ' --header='enter: show' \
    --preview="$self _preview {3}" --preview-window=right,50% \
    --bind="enter:execute($self show {3} | sh -c \"\${PAGER:-less}\")" >/dev/null || true
}

# $EDITOR may carry arguments (EDITOR='code --wait'); like git, let sh split it.
cmd_edit() {
  local id
  task_id "${1:-}"
  sh -c "${EDITOR:-vi} \"\$1\"" "${EDITOR:-vi}" "$TASKS_DIR/$id/TASK.md"
}

cmd_go() {
  local id=${1:-}
  if [ -z "$id" ]; then
    command -v fzf >/dev/null || die "go: fzf required when no task is given"
    id=$(cmd_ls | fzf --delimiter='\t' --prompt='task> ' | cut -f1)
    [ -n "$id" ] || exit 1
  fi
  task_id "$id"
  ensure_session "$id"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$id"
  elif [ -t 1 ]; then
    exec tmux attach-session -t "=$id"
  else
    local p
    IFS=$TAB read -r _ _ _ p <"$TASKS_DIR/$id/repos.tsv"
    printf '%s\n' "$p"
  fi
}

cmd_set() {
  local id="" a keys=() vals=() k v i re='^P[0-3]$'
  for a in "$@"; do
    case $a in
      *=* | priority | title) keys+=("${a%%=*}") ;;
      *) [ -z "$id" ] || die "set: too many arguments"; id=$a ;;
    esac
  done
  task_id "$id"
  [ ${#keys[@]} -gt 0 ] || die "usage: collie set [<id>] field=value... (priority, title)"
  # validate everything before writing anything
  i=0
  for a in "$@"; do
    case $a in
      *=*) v=${a#*=} ;;
      priority | title)
        [ ! -t 0 ] || printf '%s: ' "$a" >&2
        IFS= read -r v || true
        ;;
      *) continue ;;
    esac
    k=${keys[$i]}
    case $k in
      priority) [[ $v =~ $re ]] || die "priority must be P0..P3" ;;
      title) ;;
      *) die "set: unknown field '$k' (priority, title)" ;;
    esac
    case $v in *$'\n'*) die "set: $k must be a single line" ;; esac
    vals+=("$v")
    i=$((i + 1))
  done
  for i in "${!keys[@]}"; do
    fm_set "$TASKS_DIR/$id/TASK.md" "${keys[$i]}" "${vals[$i]}"
    log_event "$id" field_set "${keys[$i]}=${vals[$i]}"
  done
}
