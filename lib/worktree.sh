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
  local i path failed=0
  for path in ${SETUP_LINKS[@]+"${SETUP_LINKS[@]}"}; do
    rm -f "$path" || warn "could not remove setup link $path"
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
    [ ! -e "$path" ] && [ ! -L "$path" ] || die "$path already exists"
    plan="$plan$R_NAME$TAB$R_COMMON$TAB$branch$TAB$path"$'\n'
  done <<<"$specs"

  local name c b p created="" setup_backup setup_had_repos=0
  local -a SETUP_FILES=() SETUP_LINKS=()
  [ ! -d "$tdir/repos" ] || setup_had_repos=1
  setup_backup=$(mktemp -d) || return 1
  if ! { mkdir -p "$tdir/repos" &&
    setup_snapshot "$tdir/repos.tsv" && setup_snapshot "$tdir/events.log"; }; then
    setup_abort
    return 1
  fi
  while IFS=$TAB read -r name c b p; do
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

  NEW_PATHS=""
  while IFS=$TAB read -r name c b p; do
    [ -n "$name" ] || continue
    NEW_PATHS="$NEW_PATHS${NEW_PATHS:+$'\n'}$p"
    if ! { link_worktree "$id" "$name" "$c" "$b" "$p" &&
      printf '%s\t%s\t%s\t%s\n' "$name" "$c" "$b" "$p" >>"$tdir/repos.tsv"; }; then
      setup_abort
      NEW_PATHS=""
      return 1
    fi
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
