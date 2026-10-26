#!/usr/bin/env bats

load helper

# Folder tasks: a plain (non-git) directory used in place. collie never
# creates, checks or removes anything inside it.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  F="$TMP/notes/Trip 2027"
  mkdir -p "$F"
  echo plan >"$F/plan.md"
  touch -t 202001010000 "$F/plan.md"
}
teardown() { teardown_env; }

@test "new: a non-git cwd becomes a folder task, used in place" {
  cd "$F"
  run collie new trip
  [ "$status" -eq 0 ]
  [ "$output" = "$F" ]
  [ "$(cat "$(task_dir trip)/repos.tsv")" = "trip-2027	-	-	$F" ]
  [ "$(window_path trip trip-2027)" = "$F" ]
  [ ! -e "$F/.collie" ]
  [ "$(readlink "$(task_dir trip)/repos/trip-2027")" = "$F" ]
  grep -q "folder_added	repo=trip-2027 path=$F" "$(task_dir trip)/events.log"
  [ "$(collie ls | cut -f1,2,6)" = "trip	todo	trip-2027" ]
}

@test "new: -r takes a folder path; a branch on a folder is refused" {
  cd "$TMP"
  collie new trip -r "$F" --no-window
  [ "$(cut -f4 "$(task_dir trip)/repos.tsv")" = "$F" ]
  run collie new other -r "$F:main" --no-window
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
  [ ! -e "$(task_dir other)" ]
}

@test "new: a folder another active task uses (or contains) only warns" {
  cd "$TMP"
  collie new trip -r "$F" --no-window
  run collie new trip2 -r "$F" --no-window
  [ "$status" -eq 0 ]
  [[ "$output" == *"also used by task 'trip'"* ]]
  run collie new all-notes -r "$TMP/notes" --no-window
  [ "$status" -eq 0 ]
  [[ "$output" == *"also used by task 'trip'"* ]]
  collie archive trip
  run collie new trip3 -r "$F" --no-window
  [[ "$output" != *"task 'trip'"* ]]
}

@test "run: the agent starts in the folder; the prompt names the task dir" {
  mkdir "$TMP/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$ARGS"\nexec sleep 300\n' >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH" ARGS="$TMP/args"
  cd "$TMP"
  collie new trip -r "$F" --no-window
  collie run trip --agent claude
  [ "$(tmux display -p -t "$(run_pane trip)" '#{pane_current_path}')" = "$F" ]
  wait_for '[ -s "$ARGS" ]'
  grep -qF "contract is $(task_dir trip)/TASK.md" "$ARGS"
  grep -qF "report to $(task_dir trip)/REPORT.md" "$ARGS"
  grep -qxF "$(task_dir trip)" "$ARGS"
}

@test "done: closes the task without touching the folder, even from inside it" {
  cd "$F"
  collie new trip
  echo draft >"$F/draft.md"
  run collie done trip
  [ "$status" -eq 0 ]
  [ "$(fm trip status)" = done ]
  [ -f "$F/plan.md" ] && [ -f "$F/draft.md" ]
  ! tmux has-session -t =trip 2>/dev/null
  [ ! -e "$(task_dir trip)/repos/trip-2027" ]
}

@test "gc: never finishes a folder-only task" {
  cd "$TMP"
  collie new trip -r "$F" --no-window
  run collie gc -n
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "review: files changed since the first run, then REPORT.md" {
  cd "$TMP"
  collie new trip -r "$F" --no-window
  run collie review trip
  [[ "$output" == *"== trip-2027  folder  $F"* ]]
  [[ "$output" == *"(no runs yet)"* ]]
  collie run trip -- 300
  sleep 1.1 # mtimes have 1s resolution on some filesystems
  echo day1 >"$F/day1.md"
  echo "Booked." >"$(task_dir trip)/REPORT.md"
  run collie review trip
  [[ "$output" == *"day1.md"* ]]
  [[ "$output" != *"plan.md"* ]]
  [[ "$output" == *"Booked."* ]]
}

@test "add: a repo joins a folder task on feat/<id>" {
  make_bare_repo A
  cd "$TMP"
  collie new trip -r "$F" --no-window
  collie add trip -r A --no-window
  [ -d "$TMP/repos/A/feat-trip" ]
  [ "$(git -C "$TMP/repos/A/feat-trip" branch --show-current)" = feat/trip ]
}

@test "doctor and preview: folders are not checked as worktrees" {
  cd "$TMP"
  collie new trip -r "$F" --no-window
  run collie doctor
  [[ "$output" != *"trip"* ]]
  run collie _preview trip
  [[ "$output" == *"trip-2027  folder  $F"* ]]
  mv "$F" "$TMP/notes/moved"
  run collie doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  trip: trip-2027 folder missing: $F"* ]]
}
