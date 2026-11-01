#!/usr/bin/env bats

load helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "fixtures: files reuse the suite template without sharing writable repositories" {
  make_bare_repo A
  local template=$TPL head
  head=$(git -C "$TMP/origin-A" rev-parse HEAD)
  git -C "$REPO" config test.marker first-copy
  git -C "$REPO" branch only-in-a
  echo changed >"$TMP/origin-A/change"
  git -C "$TMP/origin-A" add change
  git -C "$TMP/origin-A" commit -q -m changed

  # Simulate the next Bats file while retaining the same suite lifetime.
  BATS_FILE_TMPDIR="$TMP/next-file"
  mkdir -p "$BATS_FILE_TMPDIR"
  make_normal_repo B
  [ "$TPL" = "$template" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$TMP/origin-B" rev-parse HEAD)" = "$head" ]
  [ ! -e "$TMP/origin-B/change" ]
  ! git -C "$REPO" config --get test.marker
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/only-in-a
  [ "$(git -C "$REPO" remote get-url origin)" = "$TMP/origin-B" ]
}

@test "fixtures: concurrent files publish a complete template and repair only their own copies" {
  local BATS_SUITE_TMPDIR="$TMP/suite" worker pid template='' pids=()
  mkdir -p "$BATS_SUITE_TMPDIR"
  for worker in 1 2 3 4; do
    (
      BATS_FILE_TMPDIR="$BATS_SUITE_TMPDIR/file-$worker"
      BATS_TEST_TMPDIR="$BATS_FILE_TMPDIR/test"
      mkdir -p "$BATS_TEST_TMPDIR"
      setup_env
      make_bare_repo A
      printf '%s\n' "$TPL" >"$BATS_SUITE_TMPDIR/template-$worker"
      git -C "$REPO/main" config test.marker "$worker"
      [ "$(git -C "$REPO/main" rev-parse --path-format=absolute --git-common-dir)" = "$REPO/.bare" ]
      git -C "$REPO/main" status --porcelain >"$BATS_SUITE_TMPDIR/status-$worker"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  for worker in 1 2 3 4; do
    [ -n "$template" ] || template=$(cat "$BATS_SUITE_TMPDIR/template-$worker")
    [ "$(cat "$BATS_SUITE_TMPDIR/template-$worker")" = "$template" ]
    [ ! -s "$BATS_SUITE_TMPDIR/status-$worker" ]
    [ "$(git -C "$BATS_SUITE_TMPDIR/file-$worker/test/repos/A/main" config test.marker)" = "$worker" ]
  done
}
