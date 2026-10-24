# shellcheck shell=bash
# shellcheck disable=SC2034  # REPO/TMP are read by the .bats files
# Shared fixtures: an isolated tmux server, state dir and throwaway git repos per test.

COLLIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_env() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TMUX_TMPDIR="$TMP/tmux"
  mkdir -p "$TMUX_TMPDIR" "$TMP/repos"
  unset TMUX TMUX_PANE COLLIE_TASK COLLIE_TASK_DIR
  export COLLIE_STATE_DIR="$TMP/state"
  export XDG_CONFIG_HOME="$TMP/config"
  export COLLIE_REPO_ROOTS="$TMP/repos/*"
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
  git init -q "$TMP/origin-$1"
  git -C "$TMP/origin-$1" commit -q --allow-empty -m init
}

# bare layout: <root>/.bare + .git file + <root>/main worktree
make_bare_repo() {
  local name=${1:-proj} root="$TMP/repos/${1:-proj}"
  make_origin "$name"
  mkdir "$root"
  git clone -q --bare "$TMP/origin-$name" "$root/.bare"
  echo "gitdir: ./.bare" >"$root/.git"
  git -C "$root" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$root" fetch -q origin
  git -C "$root" worktree add -q "$root/main" main
  REPO="$root"
}

# normal clone layout: <root> is the main worktree
make_normal_repo() {
  local name=${1:-proj}
  make_origin "$name"
  git clone -q "$TMP/origin-$name" "$TMP/repos/$name"
  REPO="$TMP/repos/$name"
}

task_dir() { echo "$COLLIE_STATE_DIR/tasks/$1"; }

fm() { awk -v k="$2" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$(task_dir "$1")/TASK.md"; }

window_path() { tmux display -p -t "=$1:$2" '#{pane_current_path}'; }

# pane of run <n> (default 1) in task <id>
run_pane() { tmux list-windows -t "=$1" -F '#{@collie_run} #{pane_id}' | awk -v r="${2:-1}" '$1 == r { print $2 }'; }

# simulate an agent hook firing inside run <n> of task <id>
hook() { TMUX_PANE=$(run_pane "$1" "${3:-1}") collie state "$2"; }

# aggregated agent column of `collie ls -a`
agent_of() { collie ls -a | awk -F'\t' -v id="$1" '$1 == id { print $5 }'; }

# retry a condition for up to 5s (`if` keeps bats' ERR trap out of the eval)
wait_for() {
  local i
  for i in $(seq 1 50); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}
