#!/usr/bin/env bats
load helper
setup() { setup_env; }
teardown() { teardown_env; }

@test "fixture: clears ambient collie settings but preserves suite inputs" {
  (
    export COLLIE_RUN=1 COLLIE_TASK=x COLLIE_UNKNOWN='ambient value'
    export COLLIE_BASH=/bin/bash COLLIE_TEST_DIAGNOSTICS_DIR="$TMP/diagnostics"
    setup_env
    [ -z "${COLLIE_RUN+x}" ]
    [ -z "${COLLIE_TASK+x}" ]
    [ -z "${COLLIE_UNKNOWN+x}" ]
    [ "$COLLIE_BASH" = /bin/bash ]
    [ "$COLLIE_TEST_DIAGNOSTICS_DIR" = "$TMP/diagnostics" ]
    [ -d "$COLLIE_TEST_DIAGNOSTICS_DIR" ]
    [ "$COLLIE_STATE_DIR" = "$TMP/state" ]
    [ -f "$COLLIE_ROOT/bin/collie" ]
  )
}

@test "readiness: retries until a delayed completion signal" {
  (sleep 0.2; touch "$TMP/ready") &
  writer=$!
  wait_for '[ -f "$TMP/ready" ]'
  wait "$writer"
}

@test "readiness: timeout names the unsuccessful predicate" {
  run wait_for '[ -f "$TMP/never" ]' 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'readiness timed out after 1s:'* ]]
  [[ "$output" == *'$TMP/never'* ]]
}

@test "readiness: diagnostics preserve panes and task events before cleanup" {
  export COLLIE_TEST_DIAGNOSTICS_DIR="$TMP/diagnostics"
  mkdir -p "$COLLIE_TEST_DIAGNOSTICS_DIR" "$COLLIE_STATE_DIR/tasks/x"
  echo event >"$COLLIE_STATE_DIR/tasks/x/events.log"
  tmux -f /dev/null new-session -d -s diagnostic 'echo diagnostic-pane; sleep 300'
  wait_for 'tmux capture-pane -p -t =diagnostic: | grep -q diagnostic-pane'
  capture_test_failure
  grep -q diagnostic-pane "$TMP"/diagnostics/*/state.log
  grep -q event "$TMP"/diagnostics/*/tasks/x/events.log
  tmux has-session -t =diagnostic
}
