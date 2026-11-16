#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off TMP # blocks write to $TMP
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

# replace the task's ## Verify section (the template's last) with stdin
set_verify() { # id
  local f
  f="$(task_dir "$1")/TASK.md"
  awk '$0 == "## Verify" { exit } { print }' "$f" >"$f.new"
  { echo "## Verify"; cat; } >>"$f.new"
  mv "$f.new" "$f"
}

@test "verify: runs only sh blocks under ## Verify, in the worktree; records a pass" {
  collie new x --no-window
  wt="$TMP/repos/A/feat-x"
  set_verify x <<'EOF'
```sh
pwd >"$TMP/pwd"
echo from-block-one
```
```bash
echo not-sh
```
Some text.
```sh
## not a heading inside a fence
echo from-block-two
```

## Ship
```sh
echo not-verify
```
EOF
  run collie verify x
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/pwd")" = "$wt" ]
  [[ "$output" == *from-block-one* && "$output" == *from-block-two* ]]
  [[ "$output" != *not-sh* && "$output" != *not-verify* ]]
  [[ "$output" == *"== A  pass  exit 0"* ]]
  ev=$(awk -F'\t' '$2 == "verify"' "$(task_dir x)/events.log")
  [[ "$ev" == *"repo=A result=pass exit=0 blocks=2 log=verify/"*"-A.log" ]]
  log="$(task_dir x)/${ev##*log=}"
  grep -q from-block-two "$log"
  run collie show x
  [[ "$output" == *"verify:"*"  A  pass  exit 0  "*"$log"* ]]
  run collie review x
  [[ "$output" == *"== verify"*"  A  pass  exit 0"* ]]
  run collie _preview x
  [[ "$output" == *"verify:"*"  A  pass  exit 0"* ]]
}

@test "verify: a failing block stops the repo, records fail and the exit code" {
  collie new x --no-window
  set_verify x <<'EOF'
```sh
echo first
false
echo after-false
```
```sh
echo second-block
```
EOF
  run collie verify x
  [ "$status" -ne 0 ]
  [[ "$output" == *first* ]]
  [[ "$output" != *after-false* && "$output" != *second-block* ]]
  grep -q $'\tverify\trepo=A result=fail exit=1 ' "$(task_dir x)/events.log"
  run collie show x
  [[ "$output" == *"  A  fail  exit 1  "* ]]
}

@test "verify: no Verify blocks prints a message, exits 0, records nothing" {
  collie new x --no-window
  run collie verify x
  [ "$status" -eq 0 ]
  [[ "$output" == *"no \`\`\`sh blocks under ## Verify"* ]]
  ! grep -q $'\tverify\t' "$(task_dir x)/events.log"
  [ ! -e "$(task_dir x)/verify" ]
  run collie show x
  [[ "$output" != *"verify:"* ]]
}

@test "verify: runs in every repo, -r picks one; fails if any repo fails" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  set_verify x <<'EOF'
```sh
basename "$(pwd)" >>"$TMP/ran"
[ ! -e only-in-b ]
```
EOF
  touch "$TMP/repos/B.worktrees/feat-x/only-in-b"
  run collie verify x
  [ "$status" -ne 0 ]
  [ "$(grep -c . "$TMP/ran")" -eq 2 ]
  [[ "$output" == *"== A  pass"* && "$output" == *"== B  fail  exit 1"* ]]
  rm "$TMP/repos/B.worktrees/feat-x/only-in-b" "$TMP/ran"
  run collie verify x -r B
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$TMP/ran")" -eq 1 ]
  # the last result per repo
  run collie show x
  [[ "$output" == *"  A  pass  exit 0"* && "$output" == *"  B  pass  exit 0"* ]]
  run collie verify x -r nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no repo 'nope'"* ]]
}

@test "verify: a \`\`\`sh repo=<name> block runs in that repo only; unknown names warn" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  set_verify x <<'EOF2'
```sh
echo "all $(basename "$(dirname "$(pwd)")")" >>"$TMP/ran"
```
```sh repo=B
echo "only-b $(basename "$(dirname "$(pwd)")")" >>"$TMP/ran"
```
```sh repo=nope
echo never >>"$TMP/ran"
```
EOF2
  run --separate-stderr collie verify x
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"block 3 is for repo 'nope', which task 'x' does not have"* ]]
  [ "$(sort "$TMP/ran")" = "$(printf 'all A\nall B.worktrees\nonly-b B.worktrees')" ]
  grep -q $'\tverify\trepo=A result=pass exit=0 blocks=1 ' "$(task_dir x)/events.log"
  grep -q $'\tverify\trepo=B result=pass exit=0 blocks=2 ' "$(task_dir x)/events.log"
  [[ "$output" == *"--- block 2 of 2"* ]]
  # a repo with only other repos' blocks is skipped and records nothing
  rm "$TMP/ran"
  set_verify x <<'EOF2'
```sh repo=B
echo b >>"$TMP/ran"
```
EOF2
  run collie verify x
  [ "$status" -eq 0 ]
  [[ "$output" == *"== A  no blocks for this repo"* ]]
  [ "$(cat "$TMP/ran")" = b ]
  [ "$(grep -c $'\tverify\trepo=A ' "$(task_dir x)/events.log")" -eq 1 ]
}
