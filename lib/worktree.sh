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
  local id=$1 default_branch=$2 from=$3 specs=$4 tdir plan="" spec branch path line dup n wt
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
    # worktree path that has the branch checked out
    line="" wt=""
    while IFS= read -r n; do
      case $n in
        "worktree "*) wt=${n#worktree } ;;
        "branch refs/heads/$branch") line=$wt; break ;;
      esac
    done <<<"$(git --git-dir="$R_COMMON" worktree list --porcelain)"
    if [ -n "$line" ]; then
      local owner
      owner=$(task_owning "$line")
      [ -z "$owner" ] || owner=" (task '$owner')"
      die "branch '$branch' in $R_NAME is checked out at $line$owner"
    fi
    [ ! -e "$path" ] || die "$path already exists"
    plan="$plan$R_NAME$TAB$R_COMMON$TAB$branch$TAB$path"$'\n'
  done <<<"$specs"

  local name c b p created=""
  while IFS=$TAB read -r name c b p; do
    [ -n "$name" ] || continue
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
    ln -s "$p" "$tdir/repos/$name"
    ln -s "$tdir" "$p/.collie"
    [ -d "$c/info" ] || mkdir -p "$c/info"
    excluded "$c/info/exclude" || echo '/.collie' >>"$c/info/exclude"
    log_event "$id" worktree_created "repo=$name branch=$b path=$p start=$(git -C "$p" rev-parse HEAD)"
  done <<<"$plan"
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
