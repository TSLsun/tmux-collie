# shellcheck shell=bash
# shellcheck disable=SC2034  # REPO/TMP are read by the .bats files
# Shared fixtures: an isolated tmux server, state dir and throwaway git repos per test.

COLLIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_env() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TMUX_TMPDIR="$TMP/tmux"
  mkdir -p "$TMUX_TMPDIR" "$TMP/repos" "$TMP/home"
  unset TMUX TMUX_PANE COLLIE_TASK COLLIE_TASK_DIR
  # the test tmux server must not load the user's ~/.tmux.conf (and plugins)
  export HOME="$TMP/home"
  export COLLIE_STATE_DIR="$TMP/state"
  export XDG_CONFIG_HOME="$TMP/config"
  export COLLIE_REPO_ROOTS="$TMP/repos/*"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = test
	email = test@example.com
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF
}

teardown_env() {
  # the fifo writers of attach_client would otherwise keep bats waiting
  # shellcheck disable=SC2086
  [ -z "${CLIENT_PIDS:-}" ] || kill $CLIENT_PIDS 2>/dev/null || true
  # name the test socket: a bare kill-server could reach the user's server
  tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
}

collie() {
  "${COLLIE_BASH:-bash}" "$COLLIE_ROOT/bin/collie" "$@"
}

# Repos are built once per test file and copied per test: git is slow to spawn
# on macOS. Parallel tests may race to build; `ln -sn` lets exactly one win.
repo_template() {
  TPL="$BATS_FILE_TMPDIR/tpl"
  [ -e "$TPL" ] && return
  local t
  t="$(mktemp -d "$BATS_FILE_TMPDIR/tpl.XXXXXX")"
  # origin repo with one commit on main
  git init -q "$t/origin"
  git -C "$t/origin" commit -q --allow-empty -m init
  # bare layout: <root>/.bare + .git file + <root>/main worktree
  git clone -q --bare "$t/origin" "$t/bare/.bare"
  echo "gitdir: ./.bare" >"$t/bare/.git"
  git -C "$t/bare" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$t/bare" fetch -q origin
  git -C "$t/bare" worktree add -q "$t/bare/main" main
  # normal clone layout: <root> is the main worktree
  git clone -q "$t/origin" "$t/normal"
  ln -sn "$t" "$TPL" 2>/dev/null || true
}

make_origin() {
  repo_template
  cp -R "$TPL/origin" "$TMP/origin-$1"
}

make_bare_repo() {
  local name=${1:-proj} root="$TMP/repos/${1:-proj}"
  make_origin "$name"
  cp -R "$TPL/bare" "$root"
  git -C "$root" config remote.origin.url "$TMP/origin-$name"
  git -C "$root" worktree repair "$root/main"
  REPO="$root"
}

make_normal_repo() {
  local name=${1:-proj}
  make_origin "$name"
  cp -R "$TPL/normal" "$TMP/repos/$name"
  git -C "$TMP/repos/$name" config remote.origin.url "$TMP/origin-$name"
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

# a control-mode client stands in for a terminal attached to session $1
attach_client() {
  mkfifo "$TMP/client-$1"
  tmux -C attach -t "=$1" <"$TMP/client-$1" >/dev/null 2>&1 3>&- &
  sleep 600 >"$TMP/client-$1" 2>/dev/null 3>&- & # keeps the client's stdin open
  CLIENT_PIDS="${CLIENT_PIDS:-} $!"
  wait_for "[ -n \"\$(tmux list-clients -t '=$1')\" ]"
}
