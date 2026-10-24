# shellcheck shell=bash
# shellcheck disable=SC2034  # REPO/TMP are read by the .bats files
# Shared fixtures: an isolated tmux server and throwaway git repos per test.

COLLIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_env() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TMUX_TMPDIR="$TMP/tmux"
  mkdir -p "$TMUX_TMPDIR"
  unset TMUX TMUX_PANE
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
}

teardown_env() {
  tmux kill-server 2>/dev/null || true
}

collie() {
  "${COLLIE_BASH:-bash}" "$COLLIE_ROOT/bin/collie" "$@"
}

# origin repo with one commit on main
make_origin() {
  git init -q "$TMP/origin"
  git -C "$TMP/origin" commit -q --allow-empty -m init
}

# bare layout: <root>/.bare + .git file + <root>/main worktree
make_bare_repo() {
  local name=${1:-proj}
  make_origin
  mkdir "$TMP/$name"
  git clone -q --bare "$TMP/origin" "$TMP/$name/.bare"
  echo "gitdir: ./.bare" >"$TMP/$name/.git"
  git -C "$TMP/$name" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$TMP/$name" fetch -q origin
  git -C "$TMP/$name" worktree add -q "$TMP/$name/main" main
  REPO="$TMP/$name"
}

# normal clone layout: <root> is the main worktree
make_normal_repo() {
  local name=${1:-proj}
  make_origin
  git clone -q "$TMP/origin" "$TMP/$name"
  REPO="$TMP/$name"
}

window_for() {
  tmux list-windows -a -F '#{session_name}	#{window_name}	#{@collie_path}' 2>/dev/null |
    awk -F'\t' -v p="$1" '$3 == p { print $1 ":" $2 }'
}
