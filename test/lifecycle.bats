#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

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

@test "spike: untracked files are left behind with a warning, copied with -u" {
  collie new src --no-window
  wt="$TMP/repos/A/feat-src"
  commit_in "$wt" base
  echo .ignored >"$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" commit -qm ignore
  mkdir -p "$wt/dir"
  echo loose >"$wt/dir/loose"
  echo junk >"$wt/.ignored"
  before=$(git -C "$wt" status --porcelain)
  cd "$wt"
  run collie spike try-a --no-window
  [ "$status" -eq 0 ]
  [[ "$output" == *"untracked files are not carried over"* ]]
  [ ! -e "$TMP/repos/A/exp-try-a/dir/loose" ]
  run collie spike try-b -u --no-window
  [ "$status" -eq 0 ]
  [[ "$output" != *"not carried over"* ]]
  sp="$TMP/repos/A/exp-try-b"
  [ "$(cat "$sp/dir/loose")" = loose ]
  [ ! -e "$sp/.ignored" ]
  [ "$(git -C "$wt" status --porcelain)" = "$before" ]
  [ "$(cat "$wt/dir/loose")" = loose ]
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

@test "_gc: previews merged tasks; n aborts, y runs gc" {
  for t in m u; do collie new "$t" --no-window; done
  commit_in "$TMP/repos/A/feat-m" m
  merge_upstream feat/m
  run collie _gc <<<n
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking"*"merged:"$'\n'"m"$'\n'*"gc these? (y/n)"* ]]
  [[ "$output" != *"done m"* ]]
  [ -z "$(fm m status)" ]
  [ -d "$TMP/repos/A/feat-m" ]
  run collie _gc <<<y
  [ "$status" -eq 0 ]
  [[ "$output" == *"done m"* ]]
  [ "$(fm m status)" = done ]
  [ -z "$(fm u status)" ]
}

@test "_gc: nothing merged says so without asking" {
  collie new u --no-window
  run collie _gc <<<y
  [ "$status" -eq 0 ]
  [[ "$output" == *"no merged tasks"* && "$output" != *"(y/n)"* ]]
  [ -z "$(fm u status)" ]
}

@test "gc: a reopened task is not finished again until it has new work" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  merge_upstream feat/m
  collie gc >/dev/null
  collie reopen m --no-window
  run --separate-stderr collie gc -n
  [ -z "$output" ]
  commit_in "$TMP/repos/A/feat-m" m2
  merge_upstream feat/m
  run --separate-stderr collie gc -n
  [ "$output" = m ]
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

@test "done: accepts a squash-merged branch after base edits the same lines" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  squash_upstream feat/m
  echo changed >"$TMP/origin-A/m"
  git -C "$TMP/origin-A" commit -q -am "edit m"
  git -C "$REPO" fetch -q origin
  run collie done m
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repos/A/feat-m" ]
}

@test "done: refuses work added after a squash-merge, even once base moves on" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  squash_upstream feat/m
  commit_in "$TMP/repos/A/feat-m" extra
  echo changed >"$TMP/origin-A/m"
  git -C "$TMP/origin-A" commit -q -am "edit m"
  git -C "$REPO" fetch -q origin
  run collie done m
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmerged: A has 2 commit(s) on feat/m not in origin/"* ]]
  [ -d "$TMP/repos/A/feat-m" ]
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

# --- history ----------------------------------------------------------------

@test "reopen: commit history reads new commits; archive keeps refreshed history without the branch" {
  collie new m --no-window
  wt="$TMP/repos/A/feat-m"
  commit_in "$wt" one
  collie archive m
  snapshot=$(cat "$(task_dir m)/commits.txt")

  # A failed reopen must leave the archived history available.
  mkdir "$wt"
  run collie reopen m --no-window
  [ "$status" -ne 0 ]
  [ "$(fm m status)" = archived ]
  [ "$(cat "$(task_dir m)/commits.txt")" = "$snapshot" ]
  run collie show m
  [ "$status" -eq 0 ]
  [[ "$output" == *"add one"* ]]
  rmdir "$wt"

  collie reopen m --no-window
  commit_in "$wt" two
  run bash -c '
    source "$1/lib/tasks.sh"
    source "$1/lib/repos.sh"
    source "$1/lib/runtime.sh"
    TASKS_DIR="$COLLIE_STATE_DIR/tasks"
    TAB=$'"'"'\t'"'"'
    task_commits m
  ' bash "$COLLIE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add one"* && "$output" == *"add two"* ]]
  [[ "$output" == *"2 files changed"* ]]
  run collie _preview m
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 ahead"* ]]

  collie archive m
  git -C "$REPO" branch -q -D feat/m
  for command in show _preview; do
    run collie "$command" m
    [ "$status" -eq 0 ]
    [[ "$output" == *"add one"* && "$output" == *"add two"* ]]
  done
}

@test "done: snapshots the branch's own commits, so show keeps them after the branch is deleted" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  commit_in "$TMP/origin-A" later
  git -C "$REPO" fetch -q origin
  git -C "$TMP/repos/A/feat-m" rebase -q origin/main
  squash_upstream feat/m
  collie done m
  git -C "$REPO" branch -q -D feat/m
  run collie show m
  [ "$status" -eq 0 ]
  [[ "$output" == *$'commits:\n  == A  feat/m  '* ]]
  [[ "$output" == *"add m"* && "$output" == *"1 file changed"* ]]
  [[ "$output" != *"add later"* ]]
}

@test "show/_preview: a finished task shows when, removed worktrees and REPORT.md" {
  collie new m --no-window
  printf '# report\nPR: https://github.com/o/r/pull/7\n' >"$(task_dir m)/REPORT.md"
  collie archive m
  run collie show m
  [ "$status" -eq 0 ]
  [[ "$output" == *$'status: archived\nfinished: 20'* ]]
  [[ "$output" == *"feat-m (removed)"* && "$output" != *missing* ]]
  [[ "$output" == *$'report:\n  # report\n'* ]]
  run collie _preview m
  [ "$status" -eq 0 ]
  [[ "$output" == *$'[archived P2]\nfinished 20'* ]]
  [[ "$output" == *"A  feat/m  (removed)"* && "$output" == *"pull/7"* ]]
  # a task finished before snapshots, its branch since deleted: point at the PR
  rm "$(task_dir m)/commits.txt"
  git -C "$REPO" branch -q -D feat/m
  run collie show m
  [[ "$output" == *$'commits:\n  (branches gone; see https://github.com/o/r/pull/7)\n'* ]]
}

@test "history -n: finished tasks newest first with branch and PR; a pattern searches TASK.md and REPORT.md" {
  collie new old --no-window --title "Old one"
  collie new new --no-window -m "Fix the OAuth flow"
  collie new open --no-window
  echo 'PR: https://github.com/o/r/pull/12 (green)' >"$(task_dir new)/REPORT.md"
  collie done old
  collie archive new
  sed -i.bak 's/^[^	]*	task_done/2020-01-02T00:00:00Z	task_done/' "$(task_dir old)/events.log"
  run collie history -n
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == 20*"  archived  new  new      feat/new  #12" ]]
  [ "${lines[1]}" = "2020-01-02  done      old  Old one  feat/old  -" ]
  run collie history -n oauth
  [[ "$output" == 20*"  archived  new  new  feat/new  #12" ]]
  run collie history -n pull/12
  [[ "$output" == *"  new  "* && "$output" != *"  old  "* ]]
  run collie history -n nothing-matches
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "history -n: columns line up across mixed-length ids and titles; titles give way to COLUMNS" {
  collie new a --no-window --title "Short"
  collie new a-much-longer-task-id --no-window --title "A considerably longer title than the others"
  collie new mid-id --no-window --title "Mid title"
  echo 'https://github.com/o/r/pull/1234' >"$(task_dir mid-id)/REPORT.md"
  local id
  for id in a a-much-longer-task-id mid-id; do collie done "$id"; done
  # every row's branch and PR start at the same column
  col() { # needle line
    local pre=${2%%"$1"*}
    echo "${#pre}"
  }
  run collie history -n
  [ "$status" -eq 0 ] && [ "${#lines[@]}" -eq 3 ]
  [[ "$output" != *"	"* ]]
  local l b=() p=()
  for l in "${lines[@]}"; do
    b+=("$(col feat/ "$l")")
    p+=("$(col "  ${l##* }" "$l")")
  done
  [ "${b[0]}" = "${b[1]}" ] && [ "${b[1]}" = "${b[2]}" ]
  [ "${p[0]}" = "${p[1]}" ] && [ "${p[1]}" = "${p[2]}" ]
  [[ "$output" == *"A considerably longer title than the others  feat/"* ]]
  # a narrow terminal cuts the long title with an ellipsis, rows stay aligned
  COLUMNS=100 run collie history -n
  [[ "$output" == *"A considerably longer t…  feat/"* ]]
  b=()
  for l in "${lines[@]}"; do
    [ "${#l}" -le 100 ]
    b+=("$(col feat/ "$l")")
  done
  [ "${b[0]}" = "${b[1]}" ] && [ "${b[1]}" = "${b[2]}" ]
  [[ "$output" == *"#1234"* ]]
}

@test "history: at 80 columns the picker rows line up and the preview goes below" {
  command -v fzf >/dev/null || skip "fzf not installed"
  collie new a --no-window --title "Short"
  collie new a-much-longer-task-id --no-window --title "A considerably longer title than the others"
  echo 'https://github.com/o/r/pull/1234' >"$(task_dir a)/REPORT.md"
  collie done a
  collie done a-much-longer-task-id
  tmux -f /dev/null new-session -d -s h -x 80 -y 24 \
    "'${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' history; sleep 60"
  wait_for "tmux capture-pane -p -t =h: | grep -q 'objective:'"
  tmux capture-pane -p -t =h: >"$TMP/screen"
  # titles, then branches, give way; the branch and PR columns stay put
  grep -q "  done  a-much-longer-task-id  A considera…  feat/a-much-lo…  -\$" "$TMP/screen"
  grep -q "  done  a                      Short         feat/a           #1234\$" "$TMP/screen"
  # the preview sits below the list
  [ "$(grep -n 'objective:' "$TMP/screen" | cut -d: -f1)" -gt "$(grep -n 'feat/a ' "$TMP/screen" | cut -d: -f1)" ]
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
