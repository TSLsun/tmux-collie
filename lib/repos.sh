# shellcheck shell=bash
# Sourced by bin/collie: repo discovery and specs.

# --- repos ------------------------------------------------------------------

# Sets R_COMMON (git common dir), R_ROOT (worktree parent), R_NAME for a dir.
# The last dir is remembered: `new` resolves the current repo twice.
repo_at() {
  local dir=$1
  [ "$dir" != . ] || dir=$PWD
  [ "$dir" != "${R_AT:-}" ] || return 0
  R_AT=""
  R_COMMON=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  if [ "$(git config --file "$R_COMMON/config" --bool core.bare 2>/dev/null)" = true ]; then
    R_ROOT=${R_COMMON%/*}
    R_NAME=${R_ROOT##*/}
  else
    local main
    main=${R_COMMON%/*}
    R_NAME=${main##*/}
    R_ROOT="${main%/*}/$R_NAME.worktrees"
  fi
  R_AT=$dir
}

# Sets REPOS to "name<TAB>dir" lines for every repo matching the root globs
# (':'-separated).
discover() {
  local IFS=: pat d n roots
  if [ -n "${COLLIE_REPO_ROOTS+x}" ]; then
    roots=$COLLIE_REPO_ROOTS
  else
    roots=$(tmux_opt @collie-repo-roots)
  fi
  REPOS=""
  for pat in $roots; do
    pat=${pat/#\~/$HOME}
    for d in $pat; do
      [ -d "$d/.bare" ] || [ -d "$d/.git" ] || continue
      n=${d%/}
      REPOS="$REPOS${n##*/}$TAB$d"$'\n'
    done
  done
}

# Resolves "repo[:branch]" into R_* plus SPEC_BRANCH.
resolve_spec() {
  local ref=${1%%:*} dir="" n d
  SPEC_BRANCH=""
  [ "$ref" = "$1" ] || SPEC_BRANCH=${1#*:}
  case $ref in
    */* | .* | "~"*) dir=${ref/#\~/$HOME} ;;
    *)
      discover
      while IFS=$TAB read -r n d; do
        if [ "$n" = "$ref" ]; then
          dir=$d
          break
        fi
      done <<<"$REPOS"
      [ -n "$dir" ] || die "unknown repo '$ref' (check @collie-repo-roots)"
      ;;
  esac
  R_FOLDER=0
  repo_at "$dir" && return
  # a plain directory given by path is a folder, used in place
  { [ -z "$SPEC_BRANCH" ] && [ -d "$dir" ]; } || die "not a git repository: $dir"
  R_FOLDER=1
  R_ROOT=$(cd "$dir" && pwd -P)
  R_NAME=$(printf '%s' "${R_ROOT##*/}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
  R_NAME=${R_NAME:-folder}
}

# Warns about other unfinished tasks using this folder, a parent or a child.
warn_shared_folder() { # id path
  local f t
  for f in "$TASKS_DIR"/*/repos.tsv; do
    [ -f "$f" ] || continue
    t=${f%/*}
    t=${t##*/}
    [ "$t" != "$1" ] || continue
    fm_get "${f%/*}/TASK.md" status
    case $FM in done | archived) continue ;; esac
    if awk -F'\t' -v p="$2" '$2 == "-" && ($4 == p || index($4, p "/") == 1 || index(p, $4 "/") == 1) { f = 1 } END { exit !f }' "$f"; then
      warn "folder $2 is also used by task '$t'"
    fi
  done
}

workspace_repos() {
  local file="$CONFIG_DIR/workspaces" hit
  [ -f "$file" ] || die "unknown workspace '$1' (no $file)"
  hit=$(awk -v w="$1" '/^[[:space:]]*#/ { next } { n = index($0, ":") } n && substr($0, 1, n - 1) == w { print substr($0, n + 1); exit }' "$file")
  [ -n "$hit" ] || die "unknown workspace '$1'"
  printf '%s\n' "$hit"
}

# Sets BASE: origin/HEAD, else origin's copy of the HEAD branch (git < 2.48
# fetch does not create origin/HEAD), else the HEAD branch.
default_base() {
  local head
  BASE=""
  if git --git-dir="$1" rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null; then
    BASE=origin/HEAD
    return
  fi
  head=$(git --git-dir="$1" symbolic-ref -q HEAD) || return 1
  if git --git-dir="$1" rev-parse -q --verify "refs/remotes/origin/${head#refs/heads/}" >/dev/null; then
    BASE="origin/${head#refs/heads/}"
  else
    BASE=$head
  fi
}

# Branch is merged when its tip is in base, or when merging it into base would
# not change base's tree (squash merges). Needs git >= 2.38 for the latter.
merged_into() { # common branch base
  local tree
  git --git-dir="$1" merge-base --is-ancestor "refs/heads/$2" "$3" && return 0
  tree=$(git --git-dir="$1" merge-tree --write-tree "$3" "refs/heads/$2" 2>/dev/null) || return 1
  [ "${tree%%$'\n'*}" = "$(git --git-dir="$1" rev-parse "$3^{tree}")" ]
}

# Updates origin's refs so merges done on the remote count; no-op without an
# origin remote. Never prompts for credentials. Reports progress on stderr.
# Once per repo and command: tasks of one repo share its refs.
fetch_origin() { # common name
  local out base
  case $'\n'${FETCHED:-} in *$'\n'"$1"$'\n'*) return 0 ;; esac
  FETCHED="${FETCHED:-}$1"$'\n'
  git --git-dir="$1" remote get-url origin >/dev/null 2>&1 || return 0
  warn "$2: fetching origin…"
  if ! out=$(GIT_TERMINAL_PROMPT=0 git --git-dir="$1" fetch -q origin </dev/null 2>&1); then
    warn "$2: git fetch origin failed (${out%%$'\n'*}); checking against local refs"
    return 1
  fi
  default_base "$1" || BASE=HEAD
  base=$BASE
  warn "$2: fetched (base ${base#refs/heads/} @ $(git --git-dir="$1" rev-parse --short "$base" 2>/dev/null))"
}
