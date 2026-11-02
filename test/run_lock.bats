#!/usr/bin/env bats

# Exercise the allocator's lock boundary without starting a tmux server.
@test "run allocation: false-success mkdir cannot enter or remove another writer's lock" {
  source "$BATS_TEST_DIRNAME/../lib/cmd/agents.sh"
  TASKS_DIR="$BATS_TEST_TMPDIR/tasks"
  mkdir -p "$TASKS_DIR/x/run.lock"
  printf 'existing events\n' >"$TASKS_DIR/x/events.log"
  cp "$TASKS_DIR/x/events.log" "$BATS_TEST_TMPDIR/original"
  # Model uutils mkdir returning success after losing a creation race.
  # Real mkdir still emits a verbose receipt only when it creates the lock.
  mkdir() { command mkdir "$@" || return 0; }
  sleep() { :; }
  die() { printf 'collie: %s\n' "$*" >&2; exit 1; }
  ensure_session() { touch "$BATS_TEST_TMPDIR/entered"; return 1; }

  run start_run x stub A "$BATS_TEST_TMPDIR" stub
  [ "$status" -ne 0 ]
  [[ "$output" == *'timed out waiting for'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/entered" ]
  [ -d "$TASKS_DIR/x/run.lock" ]
  cmp "$TASKS_DIR/x/events.log" "$BATS_TEST_TMPDIR/original"
}
