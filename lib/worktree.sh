# shellcheck shell=bash
# Sourced by bin/collie: worktree creation.

# --- worktree creation (shared by new/add) ----------------------------------

# The caller owns the journal locals. Back up file contents before writing;
# existing symlinks are retained, including metadata files linked elsewhere.
setup_snapshot() {
  local path=$1 i=${#SETUP_FILES[@]}
  [ ! -d "$path" ] || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    cp -pL "$path" "$setup_backup/$i" || return 1
  fi
  SETUP_FILES+=("$path")
}

setup_abort() {
  local i path failed=0 m c to
  for path in ${SETUP_LINKS[@]+"${SETUP_LINKS[@]}"}; do
    rm -f "$path" || warn "could not remove setup link $path"
  done
  for m in ${SETUP_UNLINKS[@]+"${SETUP_UNLINKS[@]}"}; do
    mv "${m#*"$TAB"}" "${m%%"$TAB"*}" || { warn "could not restore link ${m%%"$TAB"*} (kept: ${m#*"$TAB"})"; failed=1; }
  done
  # staged worktrees go back in reverse order (main worktree before scratch)
  i=0
  [ -z "${SETUP_MOVES+x}" ] || i=${#SETUP_MOVES[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    IFS=$TAB read -r c path to _ <<<"${SETUP_MOVES[$i]}"
    git --git-dir="$c" worktree move "$to" "$path" ||
      { warn "could not move worktree $to back to $path"; failed=1; }
  done
  for i in "${!SETUP_FILES[@]}"; do
    path=${SETUP_FILES[$i]}
    if [ -f "$setup_backup/$i" ]; then
      cat "$setup_backup/$i" >"$path" || { warn "could not restore $path (backup: $setup_backup/$i)"; failed=1; }
    else
      rm -f "$path" || warn "could not remove setup file $path"
    fi
  done
  rollback "$created"
  [ "$setup_had_repos" = 1 ] || rmdir "$tdir/repos" 2>/dev/null || true
  [ "$failed" = 1 ] || rm -rf "$setup_backup"
}

setup_link() { # target destination
  if [ -e "$2" ] || [ -L "$2" ]; then
    # Reopen can reuse an existing, exact link, but never replace it.
    [ -L "$2" ] && [ "$(readlink "$2")" = "$1" ] && return 0
    warn "refusing metadata link collision: $2"
    return 1
  fi
  ln -s "$1" "$2" || return 1
  SETUP_LINKS+=("$2")
}

# Moves a metadata link into the backup; setup_abort moves it back. A
# missing link is fine.
setup_unlink() { # path
  local keep="$setup_backup/link.${#SETUP_UNLINKS[@]}"
  if [ -L "$1" ]; then
    mv "$1" "$keep" || return 1
    SETUP_UNLINKS+=("$1$TAB$keep")
  elif [ -e "$1" ]; then
    warn "not a symlink: $1"
    return 1
  fi
}

# Moves a worktree aside (dirty files and all) instead of removing it, so
# setup_abort can move it back; setup_commit_staged removes it once the
# transaction is committed. <force> 1 removes it even if dirty.
setup_stage() { # common path force repo
  local to="$2.collie-staged.$$"
  if [ -e "$to" ] || [ -L "$to" ]; then
    warn "staging path already exists: $to"
    return 1
  fi
  git --git-dir="$1" worktree move "$2" "$to" </dev/null || return 1
  SETUP_MOVES+=("$1$TAB$2$TAB$to$TAB$3$TAB$4")
}

# After the commit point: removes the staged worktrees, logging each. One that
# cannot be removed is kept where it was staged, with a warning: the commit
# stands, and nothing in it is lost.
setup_commit_staged() { # id
  local m c from to force name args
  for m in ${SETUP_MOVES[@]+"${SETUP_MOVES[@]}"}; do
    IFS=$TAB read -r c from to force name <<<"$m"
    args=(worktree remove)
    [ "$force" != 1 ] || args+=(--force)
    [ ! -L "$to/.collie" ] || rm -f "$to/.collie"
    if git --git-dir="$c" "${args[@]}" "$to"; then
      log_event "$1" worktree_removed "repo=$name path=$from"
    else
      warn "kept the old worktree of $name at $to; check it, then: git --git-dir='$c' worktree remove --force '$to'"
    fi
  done
}

# Creates one worktree; sets CREATED_BRANCH=1 if the branch is new.
add_worktree() { # common path branch from
  local c=$1 p=$2 b=$3 from=$4 base
  CREATED_BRANCH=0
  CREATED_PARENT=0
  if [ ! -d "${p%/*}" ]; then
    mkdir -p "${p%/*}" || return 1
    CREATED_PARENT=1
  fi
  if git --git-dir="$c" show-ref -q --verify "refs/heads/$b"; then
    [ -z "$from" ] || { warn "branch '$b' already exists; --from not applicable"; return 1; }
    git --git-dir="$c" worktree add -q "$p" "$b" </dev/null || return 1
  elif [ -z "$from" ] && git --git-dir="$c" show-ref -q --verify "refs/remotes/origin/$b"; then
    git --git-dir="$c" worktree add -q --track -b "$b" "$p" "origin/$b" </dev/null || return 1
    CREATED_BRANCH=1
  else
    if [ -n "$from" ]; then
      base=$from
    elif default_base "$c"; then
      base=$BASE
    else
      warn "cannot determine default branch; use --from"
      return 1
    fi
    git --git-dir="$c" worktree add -q --no-track -b "$b" "$p" "$base" </dev/null || return 1
    CREATED_BRANCH=1
  fi
}

# Plans, preflights and creates worktrees for SPECS (newline-separated) into
# task <id>; all-or-nothing. Appends to repos.tsv and links on success. With
# EDIT_SWITCH=1 (add), "repo:branch" of an attached repo switches it: a new
# worktree on that branch replaces the old one, which is staged aside with its
# scratch worktrees and removed only after the commit (the old branch stays;
# EDIT_FORCE=1 skips the dirty/unmerged checks). Sets NEW_PATHS, and
# OLD_PATHS to the worktrees switched away from.
create_repos() { # id default_branch from specs
  local id=$1 default_branch=$2 from=$3 specs=$4 tdir plan="" spec branch path n
  local row oc ob op busy="" busy_read=0
  tdir="$TASKS_DIR/$id"

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    resolve_spec "$spec"
    branch=${SPEC_BRANCH:-$default_branch}
    path="$R_ROOT/${branch//\//-}"
    case $'\n'$plan in *$'\n'"$R_NAME$TAB"*) die "repo '$R_NAME' is given twice" ;; esac
    row=""
    [ ! -f "$tdir/repos.tsv" ] ||
      row=$(awk -F'\t' -v n="$R_NAME" '$1 == n { print $2 "\t" $3 "\t" $4; exit }' "$tdir/repos.tsv")
    if [ -n "$row" ]; then
      { [ "${EDIT_SWITCH:-0}" = 1 ] && [ -n "$SPEC_BRANCH" ]; } ||
        die "repo '$R_NAME' is already part of task '$id'"
      IFS=$TAB read -r oc ob op <<<"$row"
      [ "$oc" != - ] || die "add: '$R_NAME' is a folder; it has no branch to switch"
      [ "$R_FOLDER" = 0 ] && [ "$oc" = "$R_COMMON" ] || die "add: '$R_NAME' in task '$id' is attached from $oc"
      [ "$ob" != "$branch" ] || die "add: repo '$R_NAME' is already on branch '$branch'"
      if [ "$busy_read" = 0 ]; then
        busy=$(busy_paths "$id")
        busy_read=1
      fi
      detach_check "$id" "$R_NAME" "$oc" "$ob" "$op" "${EDIT_FORCE:-0}" add "$busy"
    elif [ "$R_FOLDER" = 1 ]; then
      warn_shared_folder "$id" "$R_ROOT"
      plan="$plan$R_NAME$TAB-$TAB-$TAB$R_ROOT$TAB-$TAB-"$'\n'
      continue
    else
      ob=- op=-
    fi
    checked_out "$R_COMMON" "$R_NAME" "$branch"
    [ ! -e "$path" ] && [ ! -L "$path" ] || die "$path already exists"
    plan="$plan$R_NAME$TAB$R_COMMON$TAB$branch$TAB$path$TAB$ob$TAB$op"$'\n'
  done <<<"$specs"

  local name c b p created="" setup_backup setup_had_repos=0
  local -a SETUP_FILES=() SETUP_LINKS=() SETUP_UNLINKS=() SETUP_MOVES=()
  [ ! -d "$tdir/repos" ] || setup_had_repos=1
  setup_backup=$(mktemp -d) || return 1
  if ! { mkdir -p "$tdir/repos" &&
    setup_snapshot "$tdir/repos.tsv" && setup_snapshot "$tdir/events.log"; }; then
    setup_abort
    return 1
  fi
  while IFS=$TAB read -r name c b p ob op; do
    [ -n "$name" ] || continue
    [ "$c" != - ] || continue
    fetch_origin "$c" "$name" || true
    if ! add_worktree "$c" "$p" "$b" "$from"; then
      [ "$CREATED_PARENT" != 1 ] || rmdir "${p%/*}" 2>/dev/null || true
      setup_abort
      return 1
    fi
    created="$created$c$TAB$p$TAB$b$TAB$CREATED_BRANCH$TAB$CREATED_PARENT"$'\n'
  done <<<"$plan"
  # the switched-away worktrees step aside before anything links the new ones
  OLD_PATHS=""
  while IFS=$TAB read -r name c b p ob op; do
    [ -n "$name" ] && [ "$op" != - ] || continue
    OLD_PATHS="$OLD_PATHS${OLD_PATHS:+$'\n'}$op"
    if ! stage_repo "$id" "$name" "$c" "$op" "${EDIT_FORCE:-0}"; then
      setup_abort
      OLD_PATHS=""
      return 1
    fi
  done <<<"$plan"

  NEW_PATHS=""
  while IFS=$TAB read -r name c b p ob op; do
    [ -n "$name" ] || continue
    NEW_PATHS="$NEW_PATHS${NEW_PATHS:+$'\n'}$p"
    if [ "$op" = - ]; then
      link_worktree "$id" "$name" "$c" "$b" "$p" &&
        printf '%s\t%s\t%s\t%s\n' "$name" "$c" "$b" "$p" >>"$tdir/repos.tsv"
    else
      # the row keeps its place; written through, so a linked repos.tsv stays linked
      setup_unlink "$tdir/repos/$name" &&
        log_event "$id" repo_switched "repo=$name from=$ob branch=$b path=$p old=$op" &&
        link_worktree "$id" "$name" "$c" "$b" "$p" &&
        awk -F'\t' -v n="$name" -v b="$b" -v p="$p" 'BEGIN { OFS = "\t" } $1 == n { $3 = b; $4 = p } { print }' \
          "$tdir/repos.tsv" >"$setup_backup/repos.tsv" &&
        cat "$setup_backup/repos.tsv" >"$tdir/repos.tsv"
    fi || {
      setup_abort
      NEW_PATHS="" OLD_PATHS=""
      return 1
    }
  done <<<"$plan"
  if [ "$#" -gt 4 ]; then
    if ! { setup_snapshot "$tdir/TASK.md" &&
      write_task_md "$tdir" "$id" "$5" "$6" "$7" && log_event "$id" task_created; }; then
      setup_abort
      NEW_PATHS=""
      return 1
    fi
  fi
  rm -rf "$setup_backup" || warn "could not remove setup backup $setup_backup"
  # committed: only now are the old worktrees removed
  setup_commit_staged "$id"
  return 0
}

# Dies if a branch is checked out in some worktree, naming the owning task.
checked_out() { # common name branch
  local n wt="" at=""
  while IFS= read -r n; do
    case $n in
      "worktree "*) wt=${n#worktree } ;;
      "branch refs/heads/$3") at=$wt; break ;;
    esac
  done <<<"$(git --git-dir="$1" worktree list --porcelain)"
  [ -n "$at" ] || return 0
  n=$(task_owning "$at")
  [ -z "$n" ] || n=" (task '$n')"
  die "branch '$3' in $2 is checked out at $at$n"
}

# Links a new worktree and the task dir both ways and logs where it started.
link_worktree() { # id name common branch path
  local tdir="$TASKS_DIR/$1"
  setup_link "$5" "$tdir/repos/$2" || return 1
  if [ "$3" = - ]; then
    # shared and unversioned: no .collie link, agents get the task dir
    log_event "$1" folder_added "repo=$2 path=$5"
    return $?
  fi
  setup_link "$tdir" "$5/.collie" || return 1
  [ -d "$3/info" ] || mkdir -p "$3/info" || return 1
  if ! excluded "$3/info/exclude"; then
    setup_snapshot "$3/info/exclude" || return 1
    echo '/.collie' >>"$3/info/exclude" || return 1
  fi
  local head
  head=$(git -C "$5" rev-parse HEAD) || return 1
  log_event "$1" worktree_created "repo=$2 branch=$4 path=$5 start=$head"
}

# Whether an info/exclude file has the /.collie line.
excluded() {
  local l
  [ -f "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do [ "$l" != /.collie ] || return 0; done <"$1"
  return 1
}

rollback() {
  local c p b cb parent
  while IFS=$TAB read -r c p b cb parent; do
    [ -n "$c" ] || continue
    if ! git --git-dir="$c" worktree remove --force "$p"; then
      warn "could not remove worktree $p; keeping branch $b"
      continue
    fi
    [ "$cb" != 1 ] || git --git-dir="$c" branch -q -D "$b" || warn "could not remove new branch $b"
    [ "$parent" != 1 ] || rmdir "${p%/*}" 2>/dev/null || true
  done <<<"$1"
}

# --- worktree cleanup report (shared by done/archive/gc) --------------------

# Classifies a task's worktrees and measures them before removal. Sets
# WT_REPORT to one line per worktree, "  <repo>  <bucket>  <size>", and
# WT_KB / WT_CLEAN_KB to the total and the clean-only total in KiB.
# Buckets: wip:N (tracked files with uncommitted edits), scratch:N
# (untracked files that are not ignored), unmerged (named in the second
# argument by the caller, which already checked), else clean; then one line
# per scratch worktree (run --scratch), counted as clean: done removes them.
wt_report() { # task_dir unmerged_names
  local name c b p bucket kb
  WT_REPORT="" WT_KB=0 WT_CLEAN_KB=0
  while IFS=$TAB read -r name c b p; do
    [ -d "$p" ] || continue
    [ "$c" != - ] || continue
    bucket=$(git -C "$p" status --porcelain --untracked-files=all | awk '
      /^\?\?/ { s++; next } { w++ }
      END { if (w) printf "wip:%d ", w; if (s) printf "scratch:%d ", s }')
    case " ${2:-} " in *" $name "*) bucket="${bucket}unmerged " ;; esac
    bucket=${bucket% }
    kb=$(du -sk "$p" 2>/dev/null | cut -f1) || true
    kb=${kb:-0}
    WT_KB=$((WT_KB + kb))
    [ -n "$bucket" ] || { bucket=clean; WT_CLEAN_KB=$((WT_CLEAN_KB + kb)); }
    WT_REPORT="$WT_REPORT  $name  $bucket  $(human_kb "$kb")"$'\n'
  done <"$1/repos.tsv"
  # scratch worktrees are removed whatever they hold
  local r
  while IFS=$TAB read -r r name p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    kb=$(du -sk "$p" 2>/dev/null | cut -f1) || true
    kb=${kb:-0}
    WT_KB=$((WT_KB + kb)) WT_CLEAN_KB=$((WT_CLEAN_KB + kb))
    WT_REPORT="$WT_REPORT  $name  run $r scratch worktree  $(human_kb "$kb")"$'\n'
  done < <(scratch_list "$1")
}

# KiB as a short size: 512K, 3.4M, 1.2G.
human_kb() {
  awk -v k="$1" 'BEGIN {
    if (k < 1024) printf "%dK\n", k
    else if (k < 1048576) printf "%.1fM\n", k / 1024
    else printf "%.1fG\n", k / 1048576 }'
}

# --- scratch worktrees (run --scratch) --------------------------------------

# Adds a detached worktree at the task branch's head for one run, next to the
# task worktree as <worktree>.scratch-<n> and linked to the task dir like it,
# so a reviewer can run repros without touching the task worktree. Sets
# SCRATCH to its path.
scratch_add() { # task_dir common branch worktree
  local n=1 p
  while p="$4.scratch-$n" && { [ -e "$p" ] || [ -L "$p" ]; }; do n=$((n + 1)); done
  git --git-dir="$2" worktree add -q --detach "$p" "refs/heads/$3" </dev/null || return 1
  if ! ln -s "$1" "$p/.collie"; then
    git --git-dir="$2" worktree remove --force "$p" || warn "could not remove scratch worktree $p"
    return 1
  fi
  SCRATCH=$p
}

# A task's scratch worktrees, one "run<TAB>repo<TAB>path" line each, from
# its scratch_created events (removed ones included: callers check the path).
scratch_list() { # task_dir
  awk -F'\t' '
    function kv(k,  a, i, n) {
      n = split($3, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    $2 == "scratch_created" { print kv("run") "\t" kv("repo") "\t" kv("path") }' "$1/events.log"
}

# Removes a task's scratch worktrees: disposable, so uncommitted changes go
# with them. Logs each removal.
scratch_remove() { # id
  local d="$TASKS_DIR/$1" r name p c
  while IFS=$TAB read -r r name p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    c=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$d/repos.tsv")
    [ ! -L "$p/.collie" ] || rm -f "$p/.collie"
    if git --git-dir="$c" worktree remove --force "$p"; then
      log_event "$1" worktree_removed "repo=$name path=$p run=$r"
    else
      warn "could not remove scratch worktree $p"
    fi
  done < <(scratch_list "$d")
}

# --- detaching a repo (drop, add -r repo:branch) ----------------------------

# Where the task's working or waiting agent runs are: their windows'
# @collie_path, one per line.
busy_paths() { # id
  local st wid
  while IFS=$TAB read -r _ _ st wid; do
    case $st in working | waiting) ;; *) continue ;; esac
    [ -n "$wid" ] && [ "$wid" != - ] || continue
    tmux show-option -wqv -t "$wid" @collie_path 2>/dev/null || true
  done < <(task_runs "$1")
}

# Dies unless a repo (its worktree and scratch worktrees) can leave the task:
# no busy agent run or current directory in it, nothing locked; without
# <force>, also a clean worktree and a branch merged into the default base.
# <busy> is busy_paths' output; <verb> prefixes messages.
detach_check() { # id name common branch path force verb busy
  local id=$1 name=$2 c=$3 b=$4 p=$5 force=$6 v=$7 busy=$'\n'$8$'\n' here r sn sp gd
  here=$(pwd -P)/
  case $here in "$p/"*) die "currently inside $p; cd elsewhere first" ;; esac
  case $busy in *$'\n'"$p"$'\n'*) die "$v: an agent run is working or waiting in '$name'" ;; esac
  [ "$c" != - ] || return 0
  [ -d "$p" ] || die "$v: missing worktree $p"
  [ ! -e "$p/.collie" ] || [ -L "$p/.collie" ] || die "$v: $p/.collie is not a symlink"
  gd=$(git -C "$p" rev-parse --absolute-git-dir) || die "$v: not a git worktree: $p"
  [ ! -e "$gd/locked" ] || die "$v: worktree is locked: $p"
  while IFS=$TAB read -r r sn sp; do
    [ "$sn" = "$name" ] && [ -n "$sp" ] && [ -d "$sp" ] || continue
    case $here in "$sp/"*) die "currently inside $sp; cd elsewhere first" ;; esac
    case $busy in *$'\n'"$sp"$'\n'*) die "$v: run $r is working or waiting in scratch worktree $sp" ;; esac
    gd=$(git -C "$sp" rev-parse --absolute-git-dir) || die "$v: invalid scratch worktree $sp"
    [ ! -e "$gd/locked" ] || die "$v: scratch worktree is locked: $sp"
  done < <(scratch_list "$TASKS_DIR/$id")
  [ "$force" != 1 ] || return 0
  [ -z "$(git -C "$p" status --porcelain)" ] || die "$v: refusing dirty worktree $p (use --force)"
  git --git-dir="$c" show-ref -q --verify "refs/heads/$b" || return 0
  fetch_origin "$c" "$name" || true
  default_base "$c" || true
  merged_into "$c" "$b" "$BASE" || die "$v: refusing unmerged branch '$b' in $name (use --force; the branch is kept)"
}

# Stages a repo's scratch worktrees (always removable), then its worktree;
# see setup_stage.
stage_repo() { # id name common path force
  local r sn sp
  while IFS=$TAB read -r r sn sp; do
    [ "$sn" = "$2" ] && [ -n "$sp" ] && [ -d "$sp" ] || continue
    setup_stage "$3" "$sp" 1 "$2" || return 1
  done < <(scratch_list "$TASKS_DIR/$1")
  setup_stage "$3" "$4" "$5" "$2"
}

# Closes the task's plain (non-agent) windows at the given paths.
close_windows() { # id paths
  local wid wp r
  has_session "$1" || return 0
  tmux list-windows -t "=$1" -F '#{window_id}|#{@collie_path}|#{@collie_run}' |
    while IFS='|' read -r wid wp r; do
      [ -n "$wp" ] && [ -z "$r" ] || continue
      case $'\n'$2$'\n' in *$'\n'"$wp"$'\n'*) tmux kill-window -t "$wid" ;; esac
    done
}
