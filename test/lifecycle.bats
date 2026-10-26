#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
}
teardown() {
  # the fifo writers of attach_client would otherwise keep bats waiting
  [ -z "${CLIENT_PIDS:-}" ] || kill $CLIENT_PIDS 2>/dev/null || true
  teardown_env
}

commit_in() { # dir file
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# merge a branch into origin's main the way a PR would, then fetch
merge_upstream() {
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" "$1"
  git -C "$TMP/origin-A" merge -q --ff-only FETCH_HEAD
  git -C "$REPO" fetch -q origin
}

# squash-merge a branch into origin's main (the only strategy some repos allow)
squash_upstream() {
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" "$1"
  git -C "$TMP/origin-A" merge -q --squash FETCH_HEAD >/dev/null
  git -C "$TMP/origin-A" commit -q -m "squash $1"
  git -C "$REPO" fetch -q origin
}

# --- review -----------------------------------------------------------------

@test "review: commits, diff stat and dirty files for every repo, then REPORT.md" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  commit_in "$TMP/repos/A/feat-x" one
  commit_in "$TMP/repos/B.worktrees/feat-x" two
  echo wip >"$TMP/repos/B.worktrees/feat-x/wip"
  echo "All green." >"$(task_dir x)/REPORT.md"
  run collie review x
  [ "$status" -eq 0 ]
  [[ "$output" == *"== A  feat/x  1 ahead"* ]]
  [[ "$output" == *"add one"* && "$output" == *"one | 1 +"* ]]
  [[ "$output" == *"== B  feat/x  1 ahead"* && "$output" == *"add two"* ]]
  [[ "$output" == *"?? wip"* ]]
  [[ "$output" == *"All green."* ]]
  run collie review x -p
  [[ "$output" == *"+one"* ]]
}

# --- spike ------------------------------------------------------------------

@test "spike: copies uncommitted changes to an exp/ task; source untouched" {
  collie new src --no-window
  wt="$TMP/repos/A/feat-src"
  commit_in "$wt" base
  echo changed >"$wt/base"
  echo staged >"$wt/new"
  git -C "$wt" add new
  before=$(git -C "$wt" status --porcelain)
  stashes=$(git -C "$wt" stash list)
  cd "$wt"
  run collie spike try-x --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$wt" status --porcelain)" = "$before" ]
  [ "$(git -C "$wt" stash list)" = "$stashes" ]
  sp="$TMP/repos/A/exp-try-x"
  [ "$(git -C "$sp" branch --show-current)" = exp/try-x ]
  [ "$(cat "$sp/base")" = changed ]
  [ "$(cat "$sp/new")" = staged ]
  grep -q "spiked_from	task=src" "$(task_dir try-x)/events.log"
}

@test "spike: clean worktree just branches off HEAD" {
  collie new src --no-window
  commit_in "$TMP/repos/A/feat-src" base
  cd "$TMP/repos/A/feat-src"
  collie spike try-y --no-window
  [ -f "$TMP/repos/A/exp-try-y/base" ]
  [ -z "$(git -C "$TMP/repos/A/exp-try-y" status --porcelain)" ]
}

# --- gc ---------------------------------------------------------------------

@test "gc: finishes tasks whose branches were merged; leaves new and unmerged ones" {
  for t in m u n; do collie new "$t" --no-window; done
  commit_in "$TMP/repos/A/feat-m" m
  commit_in "$TMP/repos/A/feat-u" u
  merge_upstream feat/m
  run --separate-stderr collie gc -n
  [ "$status" -eq 0 ]
  [ "$output" = m ]
  [ -z "$(fm m status)" ]
  run collie gc
  [ "$status" -eq 0 ]
  [ "$(fm m status)" = done ]
  [ ! -d "$TMP/repos/A/feat-m" ]
  [ -z "$(fm u status)" ]
  [ -z "$(fm n status)" ]
}

@test "gc: skips a merged task with uncommitted changes" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  merge_upstream feat/m
  echo dirty >"$TMP/repos/A/feat-m/d"
  run --separate-stderr collie gc
  [ "$output" = "skipped m: dirty: A ($TMP/repos/A/feat-m) (see: collie done m)" ]
  [ -z "$(fm m status)" ]
}

@test "gc: shows the refusal reason when done fails outside the safety checks" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  merge_upstream feat/m
  cd "$TMP/repos/A/feat-m"
  run --separate-stderr collie gc
  [ "$output" = "skipped m: currently inside $TMP/repos/A/feat-m; cd elsewhere first (see: collie done m)" ]
  [ -z "$(fm m status)" ]
}

@test "gc: finishes squash-merged tasks" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  commit_in "$TMP/repos/A/feat-m" m2
  squash_upstream feat/m
  run --separate-stderr collie gc
  [ "$status" -eq 0 ]
  [ "$output" = "done m" ]
  [ "$stderr" = "collie: A: fetching origin…"$'\n'"collie: A: fetched (base origin/HEAD @ $(git -C "$REPO" rev-parse --short origin/HEAD))" ]
  [ "$(fm m status)" = done ]
}

# --- done -------------------------------------------------------------------

@test "done: accepts a squash-merged branch without --force" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  commit_in "$TMP/repos/A/feat-m" m2
  squash_upstream feat/m
  commit_in "$TMP/origin-A" later
  git -C "$REPO" fetch -q origin
  run collie done m
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repos/A/feat-m" ]
}

@test "done: fetches origin first, so a PR merged remotely needs no manual fetch" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" feat/m
  git -C "$TMP/origin-A" merge -q --squash FETCH_HEAD >/dev/null
  git -C "$TMP/origin-A" commit -q -m "squash feat/m"
  run collie done m
  [ "$status" -eq 0 ]
  [ "$(fm m status)" = done ]
  [[ "$output" == *"A: fetching origin…"* ]]
  [[ "$output" == *"A: fetched (base origin/HEAD @ $(git -C "$REPO" rev-parse --short origin/HEAD))"* ]]
}

@test "done: a failed fetch is reported, and so is why it refuses" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  git -C "$REPO" remote set-url origin "$TMP/nowhere"
  run collie done m
  [ "$status" -ne 0 ]
  [[ "$output" == *"A: git fetch origin failed (fatal: "*"); checking against local refs"* ]]
  [[ "$output" == *"unmerged: A has 1 commit(s) on feat/m not in origin/"* ]]
}

# a control-mode client stands in for a terminal attached to session $1
attach_client() {
  mkfifo "$TMP/client-$1"
  tmux -C attach -t "=$1" <"$TMP/client-$1" >/dev/null 2>&1 3>&- &
  sleep 600 >"$TMP/client-$1" 2>/dev/null 3>&- & # keeps the client's stdin open
  CLIENT_PIDS="${CLIENT_PIDS:-} $!"
  wait_for "[ -n \"\$(tmux list-clients -t '=$1')\" ]"
}
client_session() { tmux list-clients -F '#{client_session}'; }

@test "done: a client in the finished task's session moves to another session" {
  tmux new-session -d -s home
  tmux new-session -d -s other
  collie new m
  attach_client other
  c=$(tmux list-clients -F '#{client_name}')
  tmux switch-client -c "$c" -t =m
  attach_client home # now the most recently used, but not c's last session
  run collie done m --force
  [ "$status" -eq 0 ]
  [ "$(tmux display-message -c "$c" -p '#{client_session}')" = other ]
}

@test "done: without a last session, the client goes to the most recently used one" {
  tmux new-session -d -s home
  collie new m
  attach_client m
  run collie done m --force
  [ "$status" -eq 0 ]
  [ "$(client_session)" = home ]
}

@test "done: a client of the only session detaches as before" {
  collie new m
  attach_client m
  run collie done m --force
  [ "$status" -eq 0 ]
  ! tmux has-session 2>/dev/null
}

@test "done: still refuses a squash-merged branch with later work" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  squash_upstream feat/m
  commit_in "$TMP/repos/A/feat-m" extra
  run collie done m
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmerged: A has 2 commit(s)"* ]]
  [ -d "$TMP/repos/A/feat-m" ]
}

@test "done: refuses before touching anything when .collie is a real directory" {
  collie new m --no-window
  p="$TMP/repos/A/feat-m"
  rm "$p/.collie"
  mkdir "$p/.collie"
  echo mine >"$p/.collie/f"
  run collie done m --force
  [ "$status" -ne 0 ]
  [[ "$output" == *".collie"* ]]
  [ -f "$p/.collie/f" ]
  [ -L "$(task_dir m)/repos/A" ]
  [ -z "$(fm m status)" ]
}

# --- pre-push ---------------------------------------------------------------

@test "hooks/pre-push: rejects exp/* branches unless COLLIE_ALLOW_EXP=1" {
  git init -q --bare "$TMP/remote.git"
  git -C "$REPO" config core.hooksPath "$COLLIE_ROOT/hooks"
  collie new feat-ok --no-window
  collie new try --no-window -t exp
  run git -C "$TMP/repos/A/exp-try" push -q "$TMP/remote.git" exp/try
  [ "$status" -ne 0 ]
  [[ "$output" == *"exp/try"* ]]
  git -C "$TMP/repos/A/feat-feat-ok" push -q "$TMP/remote.git" feat/feat-ok
  COLLIE_ALLOW_EXP=1 git -C "$TMP/repos/A/exp-try" push -q "$TMP/remote.git" exp/try
}
