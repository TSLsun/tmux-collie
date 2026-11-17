#!/usr/bin/env bats
load helper
setup() { setup_env; }
teardown() { teardown_env; }

@test "notifications are off by default and explicit commands still work" {
  [ "$COLLIE_NOTIFY" = off ]
  source "$COLLIE_ROOT/lib/runtime.sh"
  notify title body pane
  [ ! -e "$COLLIE_TEST_NOTIFIER_LOG" ]
  export COLLIE_NOTIFY='printf "%s|%s\n" >"$COLLIE_TEST_NOTIFIER_LOG.custom"'
  notify title body pane
  [ "$(cat "$COLLIE_TEST_NOTIFIER_LOG.custom")" = 'title|body' ]
}

@test "built-in notifier guards fail and teardown detects ignored failures" {
  local notifier
  for notifier in terminal-notifier osascript notify-send; do
    run "$notifier" title body
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unexpected desktop notifier: $notifier"* ]]
  done
  [ "$(cat "$COLLIE_TEST_NOTIFIER_LOG")" = "$(printf 'terminal-notifier\nosascript\nnotify-send')" ]
  run teardown_env
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unexpected desktop notifier calls:"* ]]
  rm "$COLLIE_TEST_NOTIFIER_LOG"
}
