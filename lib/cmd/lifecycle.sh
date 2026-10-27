# shellcheck shell=bash
# Sourced by bin/collie: done/archive, review, spike, gc, sync.

# Shared by done/archive: safety checks, then remove worktrees and session.
finish_task() { # final_status args...
  local final=$1 id="" force=0
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --force) force=1 ;;
      -*) die "$final: unknown option $1" ;;
      *) [ -z "$id" ] || die "$final: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  local d name c b p problems="" n base here own=0
  d="$TASKS_DIR/$id"

  # folders are used in place: nothing to check or remove
  while IFS=$TAB read -r name c b p; do
    [ -d "$p" ] || continue
    [ "$c" != - ] || continue
    if [ -e "$p/.collie" ] && [ ! -L "$p/.collie" ]; then
      die "refusing to $final '$id': $p/.collie is not a symlink to the task dir; move it aside first"
    fi
    [ -z "$(git -C "$p" status --porcelain)" ] || problems="$problems  dirty: $name ($p)"$'\n'
    # Abandoned work is unmerged by definition and branches are kept anyway.
    [ "$final" = archived ] && continue
    fetch_origin "$c" "$name" || true
    default_base "$c"
    base=$BASE
    if git --git-dir="$c" show-ref -q --verify "refs/heads/$b" && ! merged_into "$c" "$b" "$base"; then
      n=$(git --git-dir="$c" rev-list --count "$base..refs/heads/$b")
      problems="$problems  unmerged: $name has $n commit(s) on $b not in ${base#refs/heads/}"$'\n'
    fi
  done <"$d/repos.tsv"
  if [ -n "$problems" ] && [ "$force" -eq 0 ]; then
    die "refusing to $final '$id':"$'\n'"$problems"'(branches are kept; --force discards uncommitted changes)'
  fi

  if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#S')" = "$id" ]; then own=1; fi
  here=$(pwd -P)
  if [ "$own" -eq 0 ]; then
    while IFS=$TAB read -r name c b p; do
      [ "$c" != - ] || continue
      case "$here/" in "$p"/*) die "currently inside $p; cd elsewhere first" ;; esac
    done <"$d/repos.tsv"
  fi

  # what the task committed, kept for history once its branches are deleted
  while IFS=$TAB read -r name c b p; do
    repo_commits "$d" "$name" "$c" "$b"
  done <"$d/repos.tsv" >"$d/commits.txt"
  while IFS=$TAB read -r name c b p; do
    rm -f "$d/repos/$name"
    [ -d "$p" ] || continue
    [ "$c" != - ] || continue
    rm -f "$p/.collie"
    if [ "$force" -eq 1 ]; then
      git --git-dir="$c" worktree remove --force "$p"
    else
      git --git-dir="$c" worktree remove "$p"
    fi
    log_event "$id" worktree_removed "repo=$name path=$p"
  done <"$d/repos.tsv"
  fm_set "$d/TASK.md" status "$final"
  log_event "$id" "task_$final" "force=$force"
  if has_session "$id"; then
    leave_session "$id"
    tmux kill-session -t "=$id"
  fi
}

cmd_done() { finish_task "done" "$@"; }
cmd_archive() { finish_task archived "$@"; }

# Moves clients off a session about to be killed, so they land in another
# session instead of detaching: the client's last session, else the most
# recently used other one. Without another session, they detach as before.
leave_session() { # id
  local other client
  other=$(tmux list-sessions -F "#{session_last_attached} #{session_activity}$TAB#{session_name}" |
    awk -F'\t' -v s="$1" '$2 != s' | sort -k1,1nr -k2,2nr | head -n 1 | cut -f2)
  [ -n "$other" ] || return 0
  tmux list-clients -t "=$1" -F '#{client_name}' | while IFS= read -r client; do
    tmux switch-client -c "$client" -l 2>/dev/null || true
    [ "$(tmux display-message -c "$client" -p '#{client_session}')" != "$1" ] ||
      tmux switch-client -c "$client" -t "=$other"
  done
}

# Undoes done/archive: worktrees back on the kept branches, stored status
# cleared, session rebuilt. All-or-nothing, like new.
cmd_reopen() {
  local id="" window=1
  while [ $# -gt 0 ]; do
    case $1 in
      --no-window) window=0 ;;
      -*) die "reopen: unknown option $1" ;;
      *) [ -z "$id" ] || die "reopen: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  local d st name c b p created="" first=""
  d="$TASKS_DIR/$id"
  fm_get "$d/TASK.md" status
  st=$FM
  case $st in done | archived) ;; *) die "task '$id' is not done or archived" ;; esac

  # folders were left in place: they only need to still exist
  while IFS=$TAB read -r name c b p; do
    if [ "$c" = - ]; then
      [ -d "$p" ] || die "folder $p no longer exists"
      continue
    fi
    git --git-dir="$c" show-ref -q --verify "refs/heads/$b" ||
      die "branch '$b' in $name no longer exists"
    checked_out "$c" "$name" "$b"
    [ ! -e "$p" ] || die "$p already exists"
  done <"$d/repos.tsv"

  while IFS=$TAB read -r name c b p; do
    [ "$c" != - ] || continue
    if ! { mkdir -p "${p%/*}" && git --git-dir="$c" worktree add -q "$p" "$b" </dev/null; }; then
      rollback "$created"
      exit 1
    fi
    created="$created$c$TAB$p$TAB$b${TAB}0"$'\n'
  done <"$d/repos.tsv"
  while IFS=$TAB read -r name c b p; do
    rm -f "$d/repos/$name"
    link_worktree "$id" "$name" "$c" "$b" "$p"
    [ -n "$first" ] || first=$p
  done <"$d/repos.tsv"
  fm_del "$d/TASK.md" status
  log_event "$id" task_reopened "from=$st"
  printf '%s\n' "$first"
  if [ "$window" -eq 1 ] && command -v tmux >/dev/null; then ensure_session "$id"; fi
}

cmd_review() {
  local id="" patch=0 d name c b p base
  while [ $# -gt 0 ]; do
    case $1 in
      -p) patch=1 ;;
      -*) die "review: unknown option $1" ;;
      *) [ -z "$id" ] || die "review: too many arguments"; id=$1 ;;
    esac
    shift
  done
  task_id "$id"
  d="$TASKS_DIR/$id"
  while IFS=$TAB read -r name c b p; do
    if [ "$c" = - ]; then
      printf '== %s  folder  %s\n' "$name" "$p"
      folder_changes "$d" "$p"
      echo
      continue
    fi
    default_base "$c"
    base=$BASE
    printf '== %s  %s  %s ahead of %s\n' "$name" "$b" \
      "$(git --git-dir="$c" rev-list --count "$base..refs/heads/$b")" "${base#refs/heads/}"
    git --git-dir="$c" log --oneline "$base..refs/heads/$b"
    if [ "$patch" -eq 1 ]; then
      git --git-dir="$c" diff "$base...refs/heads/$b"
    else
      git --git-dir="$c" diff --stat "$base...refs/heads/$b"
    fi
    if [ -d "$p" ]; then git -C "$p" status --short; else echo "(worktree missing: $p)"; fi
    echo
  done <"$d/repos.tsv"
  if [ -f "$d/REPORT.md" ]; then
    echo "== REPORT.md"
    cat "$d/REPORT.md"
  fi
}

# A folder has no history: list the files modified since the task's first run.
folder_changes() { # task_dir path
  local since
  since=$(awk -F'\t' '$2 == "run_started" { print $1; exit }' "$1/events.log")
  if [ -z "$since" ]; then
    echo "(no runs yet)"
  elif [ ! -d "$2" ]; then
    echo "(folder missing: $2)"
  else
    echo "changed since $since:"
    # BSD find does not parse ISO 8601 "T...Z"
    since=${since/T/ }
    find "$2" -type f -newermt "${since%Z} UTC" ! -path '*/.git/*' | sort |
      awk -v p="$2/" 'index($0, p) == 1 { print "  " substr($0, length(p) + 1) }'
  fi
}

# Branch off the current worktree into a new exp/<id> task, carrying its
# uncommitted tracked changes (-u: and untracked, non-ignored files, copied
# as-is); the source worktree is not modified.
cmd_spike() {
  local id="" args=() untracked=0 src head stash owner path
  while [ $# -gt 0 ]; do
    case $1 in
      -u | --include-untracked) untracked=1 ;;
      --no-window) args+=("$1") ;;
      --title) args+=("$1" "${2:?--title needs text}"); shift ;;
      -*) die "spike: unknown option $1" ;;
      *) [ -z "$id" ] || die "spike: too many arguments"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || die "usage: collie spike <id> [-u] [--title text] [--no-window]"
  src=$(git rev-parse --show-toplevel 2>/dev/null) || die "spike: run it inside a worktree"
  head=$(git -C "$src" rev-parse HEAD)
  stash=$(git -C "$src" stash create)
  if [ "$untracked" = 0 ] && git -C "$src" status --porcelain | grep -q '^??'; then
    warn "untracked files are not carried over (use -u)"
  fi
  owner=$(task_owning "$src")
  cmd_new "$id" -t exp -r "$src" --from "$head" ${args[@]+"${args[@]}"}
  path=${NEW_PATHS%%$'\n'*}
  if [ -n "$stash" ]; then
    git -C "$path" stash apply -q --index "$stash" || warn "could not apply changes in $path (stash $stash)"
  fi
  if [ "$untracked" = 1 ]; then
    git -C "$src" ls-files -z --others --exclude-standard |
      tar -C "$src" --null -T - -cf - | tar -C "$path" -xf - ||
      warn "could not copy untracked files to $path"
  fi
  log_event "$id" spiked_from "task=${owner:--} path=$src head=$head"
}

# A task is merged when every branch moved past where its worktree started
# and that tip is merged into the base branch (see merged_into).
cmd_gc() {
  local dry=0 d id name c b p start tip merged err
  [ "${1:-}" != -n ] || dry=1
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    fm_get "$d/TASK.md" status
    case $FM in done | archived) continue ;; esac
    id=${d##*/}
    # folders have no branch: a task needs at least one merged repo
    merged=0
    while IFS=$TAB read -r name c b p; do
      [ "$c" != - ] || continue
      merged=1
      repo_start "$d" "$name"
      start=$START
      tip=$(git --git-dir="$c" rev-parse -q --verify "refs/heads/$b") || { merged=0; break; }
      fetch_origin "$c" "$name" || true
      if [ -z "$start" ] || [ "$tip" = "$start" ] || ! { default_base "$c" || true; merged_into "$c" "$b" "$BASE"; }; then
        merged=0
        break
      fi
    done <"$d/repos.tsv"
    [ "$merged" -eq 1 ] || continue
    if [ "$dry" -eq 1 ]; then
      echo "$id"
    elif err=$("$BASH" "$PLUGIN_DIR/bin/collie" "done" "$id" 2>&1 >/dev/null); then
      echo "done $id"
    else
      # First problem under "refusing to …:", else done's last message.
      err=$(printf '%s\n' "$err" | awk '
        /^collie: refusing to .*:$/ { getline; sub(/^ +/, ""); r = $0; exit }
        { r = $0; sub(/^collie: /, "", r) }
        END { print r }')
      echo "skipped $id: $err (see: collie done $id)"
    fi
  done
}

# Merges base into each active task branch, so PRs stay mergeable after
# another one lands. Clean merges are committed and pushed (if the branch has
# an upstream); a conflicting merge is started and handed to the task's agent:
# typed into it if idle, else a new run if it exited; else left untouched.
# Tasks with an agent working or waiting are skipped. -n only predicts.
cmd_sync() {
  local dry=0 ids="" id d runs busy win pane agent name c b p bname n files msg out
  while [ $# -gt 0 ]; do
    case $1 in
      -n) dry=1 ;;
      -*) die "sync: unknown option $1" ;;
      *) task_id "$1"; ids="$ids$1"$'\n' ;;
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
  load_tmux_state
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    d="$TASKS_DIR/$id"
    runs=$(task_runs "$id")
    busy=$(awk -F'\t' '$3 == "working" || $3 == "waiting" { print "busy"; exit }' <<<"$runs")
    win=$(awk -F'\t' '$3 == "idle" { print $4; exit }' <<<"$runs")
    agent=$(awk -F'\t' '$2 != "-" { a = $2 } END { print a }' <<<"$runs")
    while IFS=$TAB read -r name c b p; do
      [ -d "$p" ] || continue
      # folders have no branch to sync
      [ "$c" != - ] || continue
      fetch_origin "$c" "$name" || true
      default_base "$c" || { echo "$id $name: skipped: no base branch"; continue; }
      bname=$BASE
      [ "$bname" != origin/HEAD ] || bname=$(git --git-dir="$c" symbolic-ref -q --short refs/remotes/origin/HEAD) || bname=$BASE
      if ! git --git-dir="$c" show-ref -q --verify "refs/heads/$b"; then
        echo "$id $name: skipped: no branch $b"
      elif git --git-dir="$c" merge-base --is-ancestor "$BASE" "refs/heads/$b"; then
        echo "$id $name: up to date"
      elif git --git-dir="$c" merge-base --is-ancestor "refs/heads/$b" "$BASE"; then
        # moving it would make gc take an untouched task for a merged one
        echo "$id $name: skipped: no commits beyond $bname"
      elif merged_into "$c" "$b" "$BASE"; then
        echo "$id $name: skipped: merged into $bname (clean up with: collie gc)"
      elif [ "$dry" -eq 0 ] && [ -n "$busy" ]; then
        echo "$id $name: skipped: agent busy"
      elif [ "$dry" -eq 0 ] && [ -n "$(git -C "$p" status --porcelain)" ]; then
        echo "$id $name: skipped: uncommitted changes"
      elif [ "$dry" -eq 0 ] && [ "$(git -C "$p" symbolic-ref -q --short HEAD)" != "$b" ]; then
        echo "$id $name: skipped: worktree not on $b"
      else
        n=$(git --git-dir="$c" rev-list --count "refs/heads/$b..$BASE")
        if files=$(git --git-dir="$c" merge-tree --write-tree --name-only --no-messages "$BASE" "refs/heads/$b" 2>/dev/null); then
          if [ "$dry" -eq 1 ]; then
            echo "$id $name: would merge $n commit(s) from $bname"
          elif git -C "$p" merge -q -m "Merge $bname into $b" "$BASE" >/dev/null 2>&1; then
            msg="merged $n commit(s) from $bname"
            if git -C "$p" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
              if out=$(GIT_TERMINAL_PROMPT=0 git -C "$p" push -q </dev/null 2>&1); then
                msg="$msg, pushed"
              else
                msg="$msg; push failed (${out%%$'\n'*})"
              fi
            fi
            log_event "$id" synced "repo=$name base=$(git --git-dir="$c" rev-parse --short "$BASE") commits=$n"
            echo "$id $name: $msg"
          else
            git -C "$p" merge --abort >/dev/null 2>&1 || true
            echo "$id $name: merge of $bname failed; worktree left as it was"
          fi
          continue
        fi
        [ -n "$files" ] || { echo "$id $name: skipped: git merge-tree failed (needs git 2.38+)"; continue; }
        files=$(sed -n '2,$p' <<<"$files" | paste -sd ' ' -)
        if [ "$dry" -eq 1 ]; then
          echo "$id $name: conflict in $files"
          continue
        fi
        if [ -z "$win" ] && [ -z "$agent" ]; then
          echo "$id $name: conflict in $files; no agent to resolve it"
          continue
        fi
        git -C "$p" merge -q -m "Merge $bname into $b" "$BASE" >/dev/null 2>&1 || true
        msg="collie sync merged $bname into $b in $p and stopped on conflicts in: $files. Resolve them keeping the intent of both sides, run the Verify checks from .collie/TASK.md, commit the merge (do not rebase or abort it), and push if the branch has an upstream."
        if [ -n "$win" ]; then
          pane=$(agent_pane "$id" "$win")
          if [ -n "$pane" ]; then
            # a pause before Enter, so agents that detect pastes still submit
            tmux send-keys -t "$pane" -l "$msg"
            sleep 0.3
            tmux send-keys -t "$pane" Enter
            out="sent to the agent in $win"
          else
            out="agent pane not found, resolve it in $p"
          fi
        elif "$BASH" "$PLUGIN_DIR/bin/collie" run "$id" -r "$name" --agent "$agent" \
          -p "Your task contract is .collie/TASK.md. $msg" >/dev/null 2>&1; then
          out="started a $agent run"
        else
          out="could not start $agent; resolve it in $p"
        fi
        log_event "$id" sync_conflict "repo=$name base=$(git --git-dir="$c" rev-parse --short "$BASE") files=${files// /,}"
        echo "$id $name: conflict in $files; $out"
      fi
    done <"$d/repos.tsv"
  done <<<"$ids"
}
