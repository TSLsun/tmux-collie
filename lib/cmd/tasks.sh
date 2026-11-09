# shellcheck shell=bash
# Sourced by bin/collie: new, add, ls, show, log, edit, go, set.

# Asks for a name (task id or type) until it is valid: re-asks on the spot
# with the reason, offering the lowercased name when case is the only
# problem; with check "id", also re-asks for an existing task. Sets ASK.
ask_slug() { # label default [id]
  local def=$2 low
  while :; do
    read -r -e -p "$1${def:+ [$def]}: " ASK || die "new: no $1 given"
    ASK=${ASK:-$def}
    if [ -z "$ASK" ]; then
      echo "  $1 is required"
    elif ! valid_id "$ASK"; then
      low=$(printf '%s' "$ASK" | tr '[:upper:]' '[:lower:]')
      if [ "$low" != "$ASK" ] && valid_id "$low"; then
        def=$low
        echo "  must be lowercase: Enter accepts $low"
        continue
      fi
      echo "  invalid $1 '$ASK': use [a-z0-9-], max 40, no leading '-'"
    elif [ "${3:-}" = id ] && { [ -e "$TASKS_DIR/$ASK" ] || [ -L "$TASKS_DIR/$ASK" ]; }; then
      echo "  task '$ASK' already exists"
    else
      return 0
    fi
    def=""
  done
}

# EXIT trap of an interactive new that did not create its task: says where
# the typed input waits (the next collie new offers it).
NEW_DRAFT=""
new_draft_note() {
  [ -n "$NEW_DRAFT" ] && [ -f "$NEW_DRAFT" ] || return 0
  printf 'collie: what you typed is kept in %s; collie new offers it again\n' "$NEW_DRAFT" >&2
}

cmd_new() {
  local id="" specs="" ws="" type=feat title="" from="" edit=0 window=1
  local goal="" asked=0 t ship=${COLLIE_SHIP-$(tmux_opt @collie-ship)}
  local run=0 agent="" runargs=() after=""
  case $ship in on | 1 | yes | true) ship=1 ;; *) ship=0 ;; esac
  while [ $# -gt 0 ]; do
    case $1 in
      -r) need_value new "-r needs a repo" "${2:-}"; specs="$specs$2"$'\n'; shift ;;
      -w) need_value new "-w needs a workspace" "${2:-}"; ws=$2; shift ;;
      -m) need_value new "-m needs text" "${2:-}"; goal=$2; shift ;;
      -t) need_value new "-t needs a type" "${2:-}"; type=$2; shift ;;
      --title) need_value new "--title needs text" "${2:-}"; title=$2; shift ;;
      --from) need_value new "--from needs a ref" "${2:-}"; from=$2; shift ;;
      --after) need_value new "--after needs task ids" "${2:-}"; after="$after $2"; shift ;;
      --edit) edit=1 ;;
      --no-window) window=0 ;;
      --ship) ship=1 ;;
      --no-ship) ship=0 ;;
      --run) run=1 ;;
      --agent) need_value new "--agent needs a name" "${2:-}"; agent=$2; run=1; shift ;;
      -p) [ $# -ge 2 ] || die "new: -p needs a prompt"; runargs+=(-p "$2"); run=1; shift ;;
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
      objective optional "goes into TASK.md; e: \$EDITOR" \
      ship "$([ "$ship" = 1 ] && echo on || echo off)" 'agent pushes, opens a PR, checks CI' \
      agent "$agent" "$([ "$run" = 1 ] && echo 'starts after creation' || echo 'asked if an objective is given')"
    echo
    # what an earlier interactive new could not create: offered as defaults
    local draft="$STATE_DIR/new-draft" did="" dtype="" dgoal=""
    if [ -f "$draft" ]; then
      { IFS= read -r did; IFS= read -r dtype; IFS= read -r dgoal; } <"$draft" || true
      printf 'draft from an earlier collie new: %s\n' "$draft"
      [ -z "$dgoal" ] || printf '  draft objective: %s\n' "$dgoal"
    fi
    ask_slug "task id" "$did" id
    id=$ASK
    ask_slug type "${dtype:-$type}"
    type=$ASK
    if [ -z "$goal" ]; then
      if [ -n "$dgoal" ]; then
        read -r -e -p "objective [Enter: the draft, -: none, e: \$EDITOR]: " goal || goal=""
        case $goal in "") goal=$dgoal ;; -) goal="" ;; e) goal=$dgoal edit=1 ;; esac
      else
        read -r -e -p "objective (optional, e: \$EDITOR): " goal || goal=""
        [ "$goal" != e ] || goal="" edit=1
      fi
    fi
    # from here on a failure keeps what was typed (see new_draft_note)
    mkdir -p "$STATE_DIR"
    printf '%s\n%s\n%s\n' "$id" "$type" "$goal" >"$draft"
    NEW_DRAFT=$draft
    trap new_draft_note EXIT
    read -r -e -p "ship [$([ "$ship" = 1 ] && echo Y/n || echo y/N)]: " t || t=""
    case $t in [yY]*) ship=1 ;; [nN]*) ship=0 ;; esac
    if { [ -n "$goal" ] || [ "$edit" = 1 ]; } && [ "$run" = 0 ] && [ "$window" = 1 ] && command -v tmux >/dev/null; then
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
  [ ! -e "$tdir" ] && [ ! -L "$tdir" ] || die "task '$id' already exists"
  [ -z "$after" ] || check_after "$id" "$after"
  if [ -n "$ws" ]; then
    r=$(workspace_repos "$ws") || exit 1
    for r in $r; do specs="$specs$r"$'\n'; done
  fi
  # the current repo, else the current directory as a folder
  [ -n "$specs" ] || specs="$(pwd -P)"$'\n'

  if ! create_repos "$id" "$type/$id" "$from" "$specs" "${title:-$id}" "$goal" "$ship"; then
    rm -rf "$tdir"
    exit 1
  fi
  if [ -n "$after" ]; then
    fm_set "$tdir/TASK.md" after "$AFTER"
    log_event "$id" field_set "after=$AFTER"
  fi
  if [ -n "$NEW_DRAFT" ]; then
    rm -f "$NEW_DRAFT"
    NEW_DRAFT=""
    trap - EXIT
  fi
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
  local id="" specs="" from="" window=1 EDIT_FORCE=0 EDIT_SWITCH=1
  while [ $# -gt 0 ]; do
    case $1 in
      -r) need_value add "-r needs a repo" "${2:-}"; specs="$specs$2"$'\n'; shift ;;
      --from) need_value add "--from needs a ref" "${2:-}"; from=$2; shift ;;
      --no-window) window=0 ;;
      --force) EDIT_FORCE=1 ;;
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
  create_repos "$id" "$branch" "$from" "$specs" || return 1
  if [ "$window" -eq 1 ] && has_session "$id"; then
    local name c b p
    while IFS=$TAB read -r name c b p; do
      case $'\n'$NEW_PATHS$'\n' in *$'\n'"$p"$'\n'*) open_window "$id" "$name" "$p" ;; esac
    done <"$TASKS_DIR/$id/repos.tsv"
  fi
  [ -z "$OLD_PATHS" ] || close_windows "$id" "$OLD_PATHS"
}

# Removes repos from a task, all-or-nothing: each worktree (staged aside with
# its scratch worktrees, removed after the commit; the branch stays), its
# links and repos.tsv row. A folder only loses its row and link.
cmd_drop() {
  local id="" names="" force=0 n
  while [ $# -gt 0 ]; do
    case $1 in
      -r) n=${2:?-r needs a repo}; names="$names$n"$'\n'; shift ;;
      --force) force=1 ;;
      -*) die "drop: unknown option $1" ;;
      *) [ -z "$id" ] || die "drop: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  [ -n "$names" ] || die "usage: collie drop [<id>] -r repo... [--force]"
  local d="$TASKS_DIR/$id" name c b p plan="" busy left
  busy=$(busy_paths "$id")
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case $'\n'$plan in *$'\n'"$n$TAB"*) die "drop: repo '$n' is given twice" ;; esac
    IFS=$TAB read -r name c b p < <(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$d/repos.tsv") || name=""
    [ "$name" = "$n" ] || die "drop: repo '$n' is not part of task '$id'"
    detach_check "$id" "$name" "$c" "$b" "$p" "$force" drop "$busy"
    plan="$plan$name$TAB$c$TAB$b$TAB$p"$'\n'
  done <<<"$names"
  left=$(awk -F'\t' -v drop="${names//$'\n'/ }" 'BEGIN { split(drop, a, " "); for (i in a) gone[a[i]] = 1 } !($1 in gone) { n++ } END { print n + 0 }' "$d/repos.tsv")
  [ "$left" -gt 0 ] || die "drop: cannot remove the last repo; use done or archive"

  local tdir=$d created="" setup_backup setup_had_repos=1 old=""
  local -a SETUP_FILES=() SETUP_LINKS=() SETUP_UNLINKS=() SETUP_MOVES=()
  setup_backup=$(mktemp -d) || return 1
  if ! { setup_snapshot "$d/repos.tsv" && setup_snapshot "$d/events.log"; }; then
    setup_abort
    die "drop: nothing changed"
  fi
  while IFS=$TAB read -r name c b p; do
    [ -n "$name" ] || continue
    old="$old${old:+$'\n'}$p"
    if [ "$c" = - ]; then
      setup_unlink "$d/repos/$name" && log_event "$id" repo_dropped "repo=$name path=$p"
    else
      stage_repo "$id" "$name" "$c" "$p" "$force" &&
        setup_unlink "$d/repos/$name" && log_event "$id" repo_dropped "repo=$name path=$p branch=$b"
    fi || {
      setup_abort
      die "drop: failed; every repo, link and record restored"
    }
  done <<<"$plan"
  if ! { awk -F'\t' -v drop="${names//$'\n'/ }" 'BEGIN { split(drop, a, " "); for (i in a) gone[a[i]] = 1 } !($1 in gone)' \
    "$d/repos.tsv" >"$setup_backup/repos.tsv" && cat "$setup_backup/repos.tsv" >"$d/repos.tsv"; }; then
    setup_abort
    die "drop: failed; every repo, link and record restored"
  fi
  rm -rf "$setup_backup" || warn "could not remove setup backup $setup_backup"
  setup_commit_staged "$id"
  close_windows "$id" "$old"
}


# Whether a task's REVIEW.md has open findings: it was written after
# REPORT.md (the implementer's last turn; or there is none) and has an
# unticked "- [ ] ..." line. Collie does not judge the findings themselves.
open_findings() { # task_dir
  [ -f "$1/REVIEW.md" ] || return 1
  [ ! -f "$1/REPORT.md" ] || [ "$1/REVIEW.md" -nt "$1/REPORT.md" ] || return 1
  grep -qE '^[[:space:]]*[-*] \[ \]' "$1/REVIEW.md"
}

# What a task needs from you, first match: answer (an agent waits for
# permission or input), - (an agent is working, or the task is finished),
# findings (REVIEW.md has open findings, see open_findings), review (status
# review), reply (an agent finished its turn without a fresh report), start
# (todo), else stalled (active, no live agent). Sets NEEDS.
# ls turns a todo task's start into blocked:<ids> while its after: deps are
# unsatisfied (see task_blocked).
task_needs() { # status top_state [task_dir]
  case $1:$2 in
    done:* | archived:*) NEEDS=- ;;
    *:waiting) NEEDS=answer ;;
    *:working) NEEDS=- ;;
    *)
      if [ -n "${3:-}" ] && open_findings "$3"; then
        NEEDS=findings
        return
      fi
      case $1:$2 in
        review:*) NEEDS=review ;;
        *:idle) NEEDS=reply ;;
        todo:*) NEEDS=start ;;
        *) NEEDS=stalled ;;
      esac
      ;;
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
    task_needs "$STATUS" "$top" "$d"
    if [ "$NEEDS" = start ]; then
      task_blocked "$d"
      [ -z "$BLOCKED" ] || NEEDS="blocked:${BLOCKED// /,}"
    fi
    fm_get "$d/TASK.md" priority
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$STATUS" "$FM" "$mark" \
      "$top" "$repos" "$NEEDS"
  done
}

# What waits on you: one line per task that needs you (answer, reply,
# findings, review, stalled), most urgent first, then by priority and id:
# what it waits on and the command that acts on it. Reads local state and the
# cached PRs (pr.tsv) only: never gh or the network.
cmd_brief() {
  local all rows id pri top needs what act d head pr n=0 _
  all=$(cmd_ls)
  rows=$(printf '%s\n' "$all" | awk -F'\t' '
    BEGIN { split("answer reply findings review stalled", o, " "); for (i in o) r[o[i]] = i }
    $7 in r { print r[$7] "\t" $0 }' | sort -t "$TAB" -k1,1n -k4,4 -k2,2)
  while IFS=$TAB read -r _ id _ pri _ top _ needs; do
    [ -n "$id" ] || continue
    d="$TASKS_DIR/$id"
    case $needs in
      answer) what="an agent waits for your answer" act="collie go $id" ;;
      reply) what="an agent finished its turn without a REPORT.md" act="collie go $id" ;;
      findings) what="the review has open findings" act="collie review $id" ;;
      review)
        # the report's first line of prose, then its PR (link from REPORT.md,
        # state and CI from the cache)
        head=$(awk -v re="$PR_RE" 'NF && !/^#/ && $0 !~ re { sub(/^[-*>] /, ""); print; exit }' "$d/REPORT.md")
        [ "${#head}" -le 100 ] || head="${head:0:97}..."
        pr=$(grep -oE -m1 "$PR_RE" "$d/REPORT.md") || pr=""
        pr=$(awk -F'\t' -v url="$pr" '
          NF >= 3 {
            n++; details[n] = $3 ($4 != "" && $4 != "-" ? ", CI " $4 : "")
            numbers[n] = $2
          }
          END {
            if (url != "" && n <= 1) print "PR " url (n ? " (" details[1] ")" : "")
            else {
              for (i = 1; i <= n; i++) s = s (s == "" ? "" : "; ") "#" numbers[i] " " details[i]
              if (url != "") print "PR " url "; " s
              else if (s != "") print "PR " s
            }
          }' "$d/pr.tsv" 2>/dev/null) || pr=""
        what="${head:-REPORT.md written}${pr:+ | $pr}" act="collie review $id"
        ;;
      stalled)
        if [ "$top" = unknown ]; then
          what="its agents were lost with the tmux server" act="collie restore $id"
        else
          what="no agent running and no REPORT.md since the last run" act="collie run $id"
        fi
        ;;
    esac
    printf '%-8s %s (%s): %s  ->  %s\n' "$needs" "$id" "$pri" "$what" "$act"
    n=$((n + 1))
  done <<<"$rows"
  # open PRs with failing CI, after the rows above and whatever the task needs
  while IFS=$TAB read -r id _ pri _; do
    [ -n "$id" ] || continue
    pr=$(awk -F'\t' '($3 == "open" || $3 == "draft") && $4 == "fail" { s = s (s == "" ? "" : ", ") "#" $2 }
      END { print s }' "$TASKS_DIR/$id/pr.tsv" 2>/dev/null) || pr=""
    [ -n "$pr" ] || continue
    printf '%-8s %s (%s): PR %s has failing CI  ->  collie ci %s --send\n' ci "$id" "$pri" "$pr" "$id"
    n=$((n + 1))
  done < <(printf '%s\n' "$all" | sort -t "$TAB" -k3,3 -k1,1)
  [ "$n" -gt 0 ] || echo "nothing waits on you"
}

latest_note() { # id; sets NOTE_AT and NOTE_TEXT, if present
  local row
  NOTE_AT="" NOTE_TEXT=""
  row=$(awk -F'\t' '$2 == "note" { at = $1; text = $3; sub(/^run=[^ ]* text=/, "", text) }
    END { if (at != "") print at "\t" text }' "$TASKS_DIR/$1/events.log")
  [ -n "$row" ] || return 0
  NOTE_AT=${row%%"$TAB"*}
  NOTE_TEXT=${row#*"$TAB"}
}

note_age() { # UTC timestamp; prints short age
  stamp %s
  awk -v t="$1" -v now="$NOW" "$DASH_AWK_TIME"' BEGIN { a = age(now - epoch(t)); print (a == "now" ? a : a " ago") }'
}

cmd_note() {
  local id="" text="" run=${COLLIE_RUN:--}
  while [ $# -gt 0 ]; do
    case $1 in
      -t) need_value note "-t needs a task id" "${2:-}"; id=$2; shift ;;
      -*) die "note: unknown option $1" ;;
      *) break ;;
    esac
    shift
  done
  text="$*"
  task_id "$id"
  if [ -z "$text" ]; then
    latest_note "$id"
    [ -z "$NOTE_AT" ] || printf '%s (%s)\n' "$NOTE_TEXT" "$(note_age "$NOTE_AT")"
    return 0
  fi
  text=$(printf '%s' "$text" | tr '\t\n' '  ' | LC_ALL=C tr -d '\000-\010\013-\037\177')
  text=${text:0:200}
  log_event "$id" note "run=$run text=$text"
}

show_latest_note() { # id
  latest_note "$1"
  [ -z "$NOTE_AT" ] || printf 'latest note (%s): %s\n' "$(note_age "$NOTE_AT")" "$NOTE_TEXT"
}

cmd_show() {
  local id d name c b p mark top a gone=missing fin=0
  task_id "${1:-}"
  d="$TASKS_DIR/$id"
  awk 'NR == 1 { next } $0 == "---" { exit } /^(status|next|after):/ { next } { print }' "$d/TASK.md"
  top=$(task_top "$id")
  task_status "$id" "${top%%"$TAB"*}"
  printf 'status: %s%s\n' "$STATUS" "${STATUS_NOTE:+ ($STATUS_NOTE)}"
  [ ! -f "$d/RESUME.md" ] || printf 'resume note: %s\n' "$d/RESUME.md"
  case $STATUS in done | archived)
    fin=1 gone=removed
    printf 'finished: %s\n' "$(finished_at "$id")"
    ;;
  esac
  a=$(dep_lines "$id")
  [ -z "$a" ] || printf '%s\n' "$a"
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
  show_latest_note "$id"
  echo
  a=$(verify_results "$id")
  [ -z "$a" ] || printf 'verify:\n%s\n\n' "$a"
  last_decision "$d"
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

# Finished tasks, newest first, tab-separated: finish date, status, id, title,
# branches, PR (#n of the first pull/merge request URL in REPORT.md). A pattern
# keeps the tasks whose TASK.md, REPORT.md or decisions.tsv contains it,
# ignoring case.
history_rows() { # [pattern]
  local d st title bs name b rep fin _
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    fm_get "$d/TASK.md" status
    st=$FM
    case $st in done | archived) ;; *) continue ;; esac
    [ -z "${1:-}" ] || grep -qsiF -- "$1" "$d/TASK.md" "$d/REPORT.md" "$d/decisions.tsv" || continue
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

# history_rows aligned for reading: each column but the last (PR) padded to its
# widest cell, two blanks apart. When the rows are wider than <width> (0: no
# limit), titles then branches give way, down to 12 columns, cut with "…". <keyed> 1 starts
# each row with the id and a tab, for fzf.
history_table() { # width keyed
  awk -F'\t' -v width="$1" -v keyed="$2" '
    function max(a, b) { return a > b ? a : b }
    { n++; for (i = 1; i <= 6; i++) { c[n, i] = $i; w[i] = max(w[i], length($i)) } }
    END {
      t = w[6]; for (i = 1; i <= 5; i++) t += w[i] + 2
      for (i = 4; i <= 5 && width > 0 && t > width; i++) {
        m = w[i] - max(w[i] < 12 ? w[i] : 12, w[i] - (t - width)); w[i] -= m; t -= m
      }
      for (r = 1; r <= n; r++) {
        s = keyed ? c[r, 3] "\t" : ""
        for (i = 1; i <= 5; i++) {
          v = c[r, i]; l = length(v)
          # "…" is one column, though awk may count its bytes
          if (l > w[i]) { v = substr(v, 1, w[i] - 1) "…"; l = w[i] }
          s = s v sprintf("%" (w[i] - l + 2) "s", "")
        }
        print s c[r, 6]
      }
    }'
}

cmd_history() {
  local list=0 pat="" rows self w COLUMNS=${COLUMNS:-}
  while [ $# -gt 0 ]; do
    case $1 in
      -n) list=1 ;;
      -*) die "history: unknown option $1" ;;
      *) [ -z "$pat" ] || die "history: too many arguments"; pat=$1 ;;
    esac
    shift
  done
  # rows fit the terminal (or COLUMNS); piped elsewhere they keep whole titles
  [ -n "$COLUMNS" ] || [ ! -t 1 ] || { COLUMNS=$(stty size </dev/tty 2>/dev/null) && COLUMNS=${COLUMNS#* }; } || COLUMNS=""
  if [ "$list" -eq 1 ] || [ ! -t 1 ] || ! command -v fzf >/dev/null; then
    history_rows "$pat" | history_table "${COLUMNS:-0}" 0
    return
  fi
  rows=$(history_rows "$pat")
  [ -n "$rows" ] || die "history: no finished tasks${pat:+ matching $pat}"
  w=$(history_table 0 0 <<<"$rows" | awk '{ w = length > w ? length : w } END { print w + 0 }')
  preview_layout "$w"
  rows=$(history_table "$WIDTH" 1 <<<"$rows")
  self="'$BASH' '$PLUGIN_DIR/bin/collie'"
  printf '%s\n' "$rows" | fzf --delimiter='\t' --with-nth=2.. --no-sort --prompt='history> ' --header='enter: show' \
    --preview="$self _preview {1}" --preview-window="$PREVIEW" \
    --bind="enter:execute($self show {1} | sh -c \"\${PAGER:-less}\")" >/dev/null || true
}

# Append a row to the task's decision trail, decisions.tsv in the record:
# ts, run, phase, decision, why, evidence, result. Never rewritten; a
# correction is a new row. Cells lose tabs and newlines, and a leading
# = + - @ gets a ' so spreadsheets don't read a formula.
cmd_log() {
  local id f row="" cell info run=- tmp
  [ $# -eq 5 ] || die "usage: collie log <phase> <decision> <why> <evidence> <result>"
  task_id ""
  f="$TASKS_DIR/$id/decisions.tsv"
  # the run: the agent window's own, if this pane is one of the task's
  if [ -n "${TMUX_PANE:-}" ]; then
    info=$(tmux display-message -p -t "$TMUX_PANE" '#{@collie_task}|#{@collie_run}' 2>/dev/null) || info=""
    [ "${info%%|*}" != "$id" ] || [ -z "${info#*|}" ] || run=${info#*|}
  fi
  for cell in "$@"; do
    cell=${cell//$'\t'/ }
    cell=${cell//$'\r'/ }
    cell=${cell//$'\n'/ }
    case $cell in [-=+@]*) cell="'$cell" ;; esac
    row="$row$TAB$cell"
  done
  # the header lands whole or not at all: ln refuses to replace a racing one
  if [ ! -e "$f" ]; then
    tmp="$f.$$"
    printf 'ts\trun\tphase\tdecision\twhy\tevidence\tresult\n' >"$tmp" &&
      { ln "$tmp" "$f" 2>/dev/null || true; }
    rm -f "$tmp"
  fi
  stamp_utc %Y-%m-%dT%H:%M:%SZ
  printf '%s\t%s%s\n' "$NOW" "$run" "$row" >>"$f"
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
      *=* | priority | title | after) keys+=("${a%%=*}") ;;
      *) [ -z "$id" ] || die "set: too many arguments"; id=$a ;;
    esac
  done
  task_id "$id"
  [ ${#keys[@]} -gt 0 ] || die "usage: collie set [<id>] field=value... (priority, title, after)"
  # validate everything before writing anything
  i=0
  for a in "$@"; do
    case $a in
      *=*) v=${a#*=} ;;
      priority | title | after)
        [ ! -t 0 ] || printf '%s: ' "$a" >&2
        IFS= read -r v || true
        ;;
      *) continue ;;
    esac
    k=${keys[$i]}
    case $k in
      priority) [[ $v =~ $re ]] || die "priority must be P0..P3" ;;
      title) ;;
      after) check_after "$id" "$v"; v=$AFTER ;;
      *) die "set: unknown field '$k' (priority, title, after)" ;;
    esac
    case $v in *$'\n'*) die "set: $k must be a single line" ;; esac
    vals+=("$v")
    i=$((i + 1))
  done
  for i in "${!keys[@]}"; do
    # an empty after clears the field
    if [ "${keys[$i]}" = after ] && [ -z "${vals[$i]}" ]; then
      fm_del "$TASKS_DIR/$id/TASK.md" after
    else
      fm_set "$TASKS_DIR/$id/TASK.md" "${keys[$i]}" "${vals[$i]}"
    fi
    log_event "$id" field_set "${keys[$i]}=${vals[$i]}"
  done
}
