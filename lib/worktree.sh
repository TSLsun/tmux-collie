# shellcheck shell=bash
# Sourced by bin/collie: worktree creation.

# --- worktree creation (shared by new/add) ----------------------------------

# Creates one worktree; sets CREATED_BRANCH=1 if the branch is new.
add_worktree() { # common path branch from
  local c=$1 p=$2 b=$3 from=$4 base
  CREATED_BRANCH=0
  [ -d "${p%/*}" ] || mkdir -p "${p%/*}" || return 1
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
# task <id>; all-or-nothing. Appends to repos.tsv and links on success.
create_repos() { # id default_branch from specs
  local id=$1 default_branch=$2 from=$3 specs=$4 tdir plan="" spec branch path dup n
  tdir="$TASKS_DIR/$id"

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    resolve_spec "$spec"
    branch=${SPEC_BRANCH:-$default_branch}
    path="$R_ROOT/${branch//\//-}"
    dup=0
    case $'\n'$plan in *$'\n'"$R_NAME$TAB"*) dup=1 ;; esac
    if [ -f "$tdir/repos.tsv" ]; then
      while IFS=$TAB read -r n _; do [ "$n" != "$R_NAME" ] || dup=1; done <"$tdir/repos.tsv"
    fi
    [ "$dup" -eq 0 ] || die "repo '$R_NAME' is already part of task '$id'"
    if [ "$R_FOLDER" = 1 ]; then
      warn_shared_folder "$id" "$R_ROOT"
      plan="$plan$R_NAME$TAB-$TAB-$TAB$R_ROOT"$'\n'
      continue
    fi
    checked_out "$R_COMMON" "$R_NAME" "$branch"
    [ ! -e "$path" ] || die "$path already exists"
    plan="$plan$R_NAME$TAB$R_COMMON$TAB$branch$TAB$path"$'\n'
  done <<<"$specs"

  local name c b p created=""
  while IFS=$TAB read -r name c b p; do
    [ -n "$name" ] || continue
    [ "$c" != - ] || continue
    fetch_origin "$c" "$name" || true
    if ! add_worktree "$c" "$p" "$b" "$from"; then
      rollback "$created"
      return 1
    fi
    created="$created$c$TAB$p$TAB$b$TAB$CREATED_BRANCH"$'\n'
  done <<<"$plan"

  mkdir -p "$tdir/repos"
  NEW_PATHS=""
  while IFS=$TAB read -r name c b p; do
    [ -n "$name" ] || continue
    NEW_PATHS="$NEW_PATHS${NEW_PATHS:+$'\n'}$p"
    printf '%s\t%s\t%s\t%s\n' "$name" "$c" "$b" "$p" >>"$tdir/repos.tsv"
    link_worktree "$id" "$name" "$c" "$b" "$p"
  done <<<"$plan"
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
  ln -s "$5" "$tdir/repos/$2"
  if [ "$3" = - ]; then
    # shared and unversioned: no .collie link, agents get the task dir
    log_event "$1" folder_added "repo=$2 path=$5"
    return
  fi
  ln -s "$tdir" "$5/.collie"
  [ -d "$3/info" ] || mkdir -p "$3/info"
  excluded "$3/info/exclude" || echo '/.collie' >>"$3/info/exclude"
  log_event "$1" worktree_created "repo=$2 branch=$4 path=$5 start=$(git -C "$5" rev-parse HEAD)"
}

# Whether an info/exclude file has the /.collie line.
excluded() {
  local l
  [ -f "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do [ "$l" != /.collie ] || return 0; done <"$1"
  return 1
}

rollback() {
  local c p b cb
  while IFS=$TAB read -r c p b cb; do
    [ -n "$c" ] || continue
    git --git-dir="$c" worktree remove --force "$p" 2>/dev/null || true
    [ "$cb" != 1 ] || git --git-dir="$c" branch -q -D "$b" 2>/dev/null || true
    rmdir "${p%/*}" 2>/dev/null || true
  done <<<"$1"
}
