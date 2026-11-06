# shellcheck shell=bash
# shellcheck disable=SC2034  # REPO/TMP are read by the .bats files
# Shared fixtures: an isolated tmux server, state dir and throwaway git repos per test.

COLLIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_env() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export TMUX_TMPDIR="$TMP/tmux"
  [ -z "${COLLIE_TEST_DIAGNOSTICS_DIR:-}" ] || mkdir -p "$COLLIE_TEST_DIAGNOSTICS_DIR"
  mkdir -p "$TMUX_TMPDIR" "$TMP/repos" "$TMP/home"
  unset TMUX TMUX_PANE COLLIE_TASK COLLIE_TASK_DIR COLUMNS FZF_COLUMNS
  # the test tmux server must not load the user's ~/.tmux.conf (and plugins)
  export HOME="$TMP/home"
  # State assertions must not age into idle while a loaded runner schedules
  # other tests. Silence behavior tests opt into their own short threshold.
  export COLLIE_SILENCE=999
  # idle notifications at once; grace tests set their own
  export COLLIE_IDLE_GRACE=0
  export COLLIE_STATE_DIR="$TMP/state"
  export XDG_CONFIG_HOME="$TMP/config"
  export COLLIE_REPO_ROOTS="$TMP/repos/*"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  # gh without a GitHub remote: tests must not reach the user's gh
  mkdir -p "$TMP/stub"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/stub/gh"
  chmod +x "$TMP/stub/gh"
  export PATH="$TMP/stub:$PATH"
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
  if [ -z "${BATS_TEST_COMPLETED:-}" ]; then
    capture_test_failure || true
  fi
  # the fifo writers of attach_client would otherwise keep bats waiting
  # shellcheck disable=SC2086
  [ -z "${CLIENT_PIDS:-}" ] || kill $CLIENT_PIDS 2>/dev/null || true
  # name the test socket: a bare kill-server could reach the user's server
  tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
}

collie() {
  "${COLLIE_BASH:-bash}" "$COLLIE_ROOT/bin/collie" "$@"
}

# Publish one immutable template per suite, then copy it into each test's
# private directory. Concurrent builders publish only after completion;
# `ln -sn` lets exactly one win. Unused candidates go with the suite tempdir.
repo_template() {
  local cache=${BATS_SUITE_TMPDIR:-$BATS_FILE_TMPDIR}
  TPL="$cache/tpl"
  [ -e "$TPL" ] && return
  local t
  t="$(mktemp -d "$cache/tpl.XXXXXX")"
  # Sample hooks are inactive and expensive to copy into every fixture.
  # Tests that exercise hooks explicitly configure core.hooksPath.
  git init -q --template= "$t/origin"
  git -C "$t/origin" commit -q --allow-empty -m init
  # bare layout: <root>/.bare + .git file + <root>/main worktree
  git clone -q --template= --bare "$t/origin" "$t/bare/.bare"
  echo "gitdir: ./.bare" >"$t/bare/.git"
  git -C "$t/bare" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$t/bare" fetch -q origin
  git -C "$t/bare" worktree add -q "$t/bare/main" main
  # normal clone layout: <root> is the main worktree
  git clone -q --template= "$t/origin" "$t/normal"
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

# cwd of the pane in window <name> of session <id>. On Linux tmux reads it from
# /proc of the pane's foreground process, which until it execs the pane command
# is tmux's forked child (no cwd yet, or the server's); wait for the exec first.
window_path() {
  local t="=$1:$2" cmd deadline=$((SECONDS + 5))
  while cmd=$(tmux display -p -t "$t" '#{pane_current_command}') &&
    { [ -z "$cmd" ] || [ "$cmd" = tmux ]; } && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
  done
  tmux display -p -t "$t" '#{pane_current_path}'
}

# pane of run <n> (default 1) in task <id>
run_pane() { tmux list-windows -t "=$1" -F '#{@collie_run} #{pane_id}' | awk -v r="${2:-1}" '$1 == r { print $2 }'; }

# simulate an agent hook firing inside run <n> of task <id>
hook() { TMUX_PANE=$(run_pane "$1" "${3:-1}") collie state "$2"; }

# an agent started by hand: link $1 (named like the agent) to bash and run it
# as `$1 -c "read -t 300"`; not to sleep, which uutils (Ubuntu 25.10+) runs
# only under its own name
fake_agent() { ln -s "$(command -v bash)" "$1"; }

# aggregated agent column of `collie ls -a`
agent_of() { collie ls -a | awk -F'\t' -v id="$1" '$1 == id { print $5 }'; }

# A wall-clock deadline includes time spent evaluating the predicate. The Bats
# test deadline also bounds a predicate that hangs rather than returning.
wait_for() {
  local deadline=$((SECONDS + ${2:-15}))
  while :; do
    if eval "$1"; then return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.1
  done
  printf 'readiness timed out after %ss: %s\n' "${2:-15}" "$1" >&2
  return 1
}

# Capture before teardown destroys panes and event logs. Every command names
# the fixture socket explicitly, including when setup did not start a server.
capture_test_failure() {
  local dest socket pane
  dest=$(mktemp -d "${COLLIE_TEST_DIAGNOSTICS_DIR:-$BATS_TEST_TMPDIR}/failure-${BATS_TEST_NUMBER}.XXXXXX")
  socket="$TMUX_TMPDIR/tmux-$(id -u)/default"
  {
    printf 'test=%s\nsocket=%s\n' "$BATS_TEST_DESCRIPTION" "$socket"
    tmux -V
    for pane in $(tmux -S "$socket" list-panes -a -F '#{pane_pid}'); do
      ps -p "$pane" -o pid=,ppid=,stat=,comm= || true
    done
    tmux -S "$socket" list-sessions
    tmux -S "$socket" list-windows -a
    tmux -S "$socket" list-panes -a -F '#{pane_id} #{pane_pid} #{pane_current_command} #{@collie_state}'
    for pane in $(tmux -S "$socket" list-panes -a -F '#{pane_id}'); do
      printf '\npane %s:\n' "$pane"
      tmux -S "$socket" capture-pane -p -t "$pane"
    done
  } >"$dest/state.log" 2>&1
  [ ! -d "$COLLIE_STATE_DIR/tasks" ] || cp -R "$COLLIE_STATE_DIR/tasks" "$dest/tasks"
  printf 'test diagnostics: %s\n' "$dest" >&2
}

# a control-mode client stands in for a terminal attached to session $1
attach_client() {
  mkfifo "$TMP/client-$1"
  tmux -C attach -t "=$1" <"$TMP/client-$1" >/dev/null 2>&1 3>&- &
  sleep 600 >"$TMP/client-$1" 2>/dev/null 3>&- & # keeps the client's stdin open
  CLIENT_PIDS="${CLIENT_PIDS:-} $!"
  wait_for "[ -n \"\$(tmux list-clients -t '=$1')\" ]"
}
