#!/usr/bin/env bats

# These tests source only task helpers: no tmux server or user state is used.
setup() {
  source "$BATS_TEST_DIRNAME/../lib/tasks.sh"
  f="$BATS_TEST_TMPDIR/TASK.md"
  printf '%s\n' --- 'title: original' 'priority: P2' --- '' 'Body: keep me' >"$f"
  cp "$f" "$BATS_TEST_TMPDIR/original"
}

assert_clean() {
  [ ! -e "$f.lock" ]
  local leftovers
  leftovers=$(find "$BATS_TEST_TMPDIR" -name 'TASK.md.tmp*')
  [ -z "$leftovers" ]
}

@test "metadata: concurrent setters and deleters preserve every independent update" {
  local i pid failures=0 pids=()
  for i in {1..40}; do fm_set "$f" "old$i" remove; done
  # Delay after the real read/transform to expose overlapping snapshots and
  # shared-temp renames reliably, rather than relying on scheduler luck.
  awk() { command awk "$@"; sleep 0.02; }
  for i in {1..40}; do
    (while [ ! -e "$BATS_TEST_TMPDIR/go" ]; do sleep 0.01; done
      fm_set "$f" "new$i" "value$i") &
    pids+=("$!")
    (while [ ! -e "$BATS_TEST_TMPDIR/go" ]; do sleep 0.01; done
      fm_del "$f" "old$i") &
    pids+=("$!")
  done
  touch "$BATS_TEST_TMPDIR/go"
  for pid in "${pids[@]}"; do wait "$pid" || failures=$((failures + 1)); done
  [ "$failures" -eq 0 ]
  for i in {1..40}; do
    fm_get "$f" "new$i"; [ "$FM" = "value$i" ]
    fm_get "$f" "old$i"; [ -z "$FM" ]
  done
  [ "$(command awk '$0 == "---" { n++ } END { print n }' "$f")" -eq 2 ]
  grep -qx 'title: original' "$f"
  grep -qx 'priority: P2' "$f"
  grep -qx 'Body: keep me' "$f"
  assert_clean
}

@test "metadata: termination cleans partial output and releases the lock" {
  awk() { printf 'partial\n'; /bin/sh -c 'kill -TERM "$PPID"'; }
  run fm_set "$f" title changed
  [ "$status" -eq 143 ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  assert_clean
  unset -f awk
  fm_del "$f" priority
  fm_get "$f" priority; [ -z "$FM" ]
}

@test "metadata: lock timeout preserves content and never removes another writer's lock" {
  mkdir "$f.lock"
  # Exercise the bounded retry path without a ten-second wall-clock delay.
  sleep() { :; }
  run fm_set "$f" title changed
  [ "$status" -ne 0 ]
  [[ "$output" == *'timed out locking metadata'* ]]
  [ -d "$f.lock" ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  # A different task remains writable while this task is locked.
  cp "$f" "$BATS_TEST_TMPDIR/other.md"
  fm_set "$BATS_TEST_TMPDIR/other.md" title independent
  fm_get "$BATS_TEST_TMPDIR/other.md" title; [ "$FM" = independent ]
}

@test "metadata: relative paths preserve permissions, body and caller traps" {
  chmod 640 "$f"
  cd "$BATS_TEST_TMPDIR"
  local before after
  before=$(trap -p)
  fm_set TASK.md title 'a & b / c'
  fm_del TASK.md priority
  after=$(trap -p)
  [ "$before" = "$after" ]
  fm_get "$f" title; [ "$FM" = 'a & b / c' ]
  [ "$(LC_ALL=C ls -l "$f" | cut -c1-10)" = '-rw-r-----' ]
  grep -qx 'Body: keep me' "$f"
  assert_clean
}

@test "metadata: failed transform preserves original and releases lock for both operations" {
  awk() { printf 'partial output\n'; return 17; }
  run fm_set "$f" title changed
  [ "$status" -ne 0 ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  assert_clean
  run fm_del "$f" priority
  [ "$status" -ne 0 ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  assert_clean
  unset -f awk
  fm_set "$f" title recovered
  fm_get "$f" title; [ "$FM" = recovered ]
}

@test "metadata: failed rename and temporary creation preserve original and release lock" {
  mv() { return 18; }
  run fm_set "$f" title changed
  [ "$status" -ne 0 ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  assert_clean
  unset -f mv
  mktemp() { return 19; }
  run fm_del "$f" priority
  [ "$status" -ne 0 ]
  cmp "$f" "$BATS_TEST_TMPDIR/original"
  assert_clean
}
