#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  export COLLIE_TASK=x
  EVENTS="$(task_dir x)/events.log"
}
teardown() { teardown_env; }

@test "note: no note is a successful empty read" {
  before=$(cat "$EVENTS")
  run collie note
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$EVENTS")" = "$before" ]
}

@test "note: joins words and latest event wins" {
  collie note first checkpoint
  collie note the latest checkpoint
  [ "$(awk -F'\t' '$2 == "note" { print $3 }' "$EVENTS" | tail -n 1)" = "run=- text=the latest checkpoint" ]
  run collie note
  [ "$status" -eq 0 ]
  [[ "$output" == *"the latest checkpoint"* ]]
  run collie show x
  [[ "$output" == *"the latest checkpoint"* ]]
  run collie _preview x
  [[ "$output" == *"the latest checkpoint"* ]]
}

@test "note: sanitizes tabs, newlines and ESC; strips carriage return" {
  collie note $'alpha\tbeta\nline2\rlast\033hidden'
  [ "$(awk -F'\t' '$2 == "note" { print $3 }' "$EVENTS")" = "run=- text=alpha beta line2lasthidden" ]
  run collie note
  [[ "$output" == *"alpha beta line2lasthidden"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "note: caps text at 200 characters" {
  text=$(printf '%0205d' 0 | tr 0 x)
  collie note "$text"
  stored=$(awk -F'\t' '$2 == "note" { print $3 }' "$EVENTS")
  [ "${#stored}" -eq 211 ]
  [ "${stored#run=- text=}" = "${text:0:200}" ]
}

@test "note: accepts explicit task outside its context; unknown task fails" {
  collie new y --no-window
  COLLIE_TASK= collie note -t y explicit task
  [ "$(awk -F'\t' '$2 == "note" { print $3 }' "$(task_dir y)/events.log")" = "run=- text=explicit task" ]
  run collie note -t missing nope
  [ "$status" -ne 0 ]
}

@test "note: no task context and no -t fails" {
  COLLIE_TASK= run collie note checkpoint
  [ "$status" -ne 0 ]
}
