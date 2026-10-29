# shellcheck shell=bash
# Opt in locally with COLLIE_TEST_DIAGNOSTICS_DIR=/absolute/path.
# Keep artifacts outside Bats' temporary tree, which is deleted after the run.
setup_tmux_diagnostics() {
  [ -n "${COLLIE_TEST_DIAGNOSTICS_DIR:-}" ] || return 0
  mkdir -p "$COLLIE_TEST_DIAGNOSTICS_DIR"
  local root
  root=$(cd "$COLLIE_TEST_DIAGNOSTICS_DIR" && pwd -P)
  TMUX_DIAGNOSTICS_DIR=$(mktemp -d "$root/restore-${BATS_TEST_NUMBER}.XXXXXX")
  TMUX_DIAGNOSTICS_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
  printf 'test=%s\nsocket=%s\n' "$BATS_TEST_DESCRIPTION" "$TMUX_DIAGNOSTICS_SOCKET" >"$TMUX_DIAGNOSTICS_DIR/lifecycle.log"
}

tmux_diagnostic_event() {
  [ -n "${TMUX_DIAGNOSTICS_DIR:-}" ] || return 0
  printf 'elapsed=%ss %s\n' "$SECONDS" "$*" >>"$TMUX_DIAGNOSTICS_DIR/lifecycle.log"
}

# -vv writes into the current directory: preserve the command's cwd and copy
# those logs out before Bats deletes the fixtures. Do not retry a failed spawn.
tmux_with_diagnostics() {
  if [ -z "${TMUX_DIAGNOSTICS_DIR:-}" ]; then
    tmux "$@"
    return
  fi
  local rc
  tmux_diagnostic_event "start: tmux $*"
  # -L lets tmux create its socket directory on a first start; TMUX_TMPDIR
  # already isolates this test. An explicit -S requires that directory to exist.
  if tmux -L default -vv "$@"; then rc=0; else rc=$?; fi
  tmux_diagnostic_event "exit=$rc: tmux $*"
  return "$rc"
}

# Run before cleanup, so the snapshot describes the failure, not teardown.
capture_tmux_diagnostics() {
  [ -n "${TMUX_DIAGNOSTICS_DIR:-}" ] || return 0
  local pid
  {
    tmux -V
    uname -a
    printf '\nprivate socket:\n'
    ls -ldi "$TMUX_DIAGNOSTICS_SOCKET" 2>&1 || true
    for pid in ${TMUX_DIAGNOSTICS_PIDS:-}; do
      printf '\nsignalled server pid=%s:\n' "$pid"
      ps -p "$pid" -o pid=,ppid=,stat=,comm= || true
    done
    printf '\ncurrent server and sessions:\n'
    tmux -S "$TMUX_DIAGNOSTICS_SOCKET" display-message -p '#{pid}' 2>&1 || true
    tmux -S "$TMUX_DIAGNOSTICS_SOCKET" list-sessions 2>&1 || true
  } >"$TMUX_DIAGNOSTICS_DIR/state.log" 2>&1
  printf 'tmux diagnostics: %s\n' "$TMUX_DIAGNOSTICS_DIR"
}

# Run after cleanup to include shutdown output in any verbose server logs.
save_tmux_diagnostics() {
  [ -n "${TMUX_DIAGNOSTICS_DIR:-}" ] || return 0
  local task
  find "$TMP" -type f -name 'tmux-*.log' -exec cp {} "$TMUX_DIAGNOSTICS_DIR/" \;
  for task in "$COLLIE_STATE_DIR/tasks/"*; do
    [ -f "$task/events.log" ] || continue
    cp "$task/events.log" "$TMUX_DIAGNOSTICS_DIR/events-${task##*/}.log"
  done
}
