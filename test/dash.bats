#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

# --- set --------------------------------------------------------------------

@test "set: updates priority and title; logs each change" {
  collie new x --no-window
  run collie set x priority=P1 "title=Retry: v2"
  [ "$status" -eq 0 ]
  [ "$(fm x priority)" = P1 ]
  [ "$(fm x title)" = "Retry: v2" ]
  grep -q "field_set	title=Retry: v2" "$(task_dir x)/events.log"
}

@test "set: rejects bad fields and values without writing anything" {
  collie new x --no-window
  for bad in status=review next=later priority=P9 colour=red; do
    run collie set x title=keep "$bad"
    [ "$status" -ne 0 ]
  done
  [ "$(fm x title)" = x ]
  run collie set x
  [ "$status" -ne 0 ]
}

@test "set: a field without a value is read from stdin; COLLIE_TASK is the default" {
  collie new x --no-window
  echo "Write the migration" | COLLIE_TASK=x collie set title
  [ "$(fm x title)" = "Write the migration" ]
}

# --- edit -------------------------------------------------------------------

@test "edit: opens TASK.md in \$EDITOR; COLLIE_TASK is the default; unknown task fails" {
  collie new x --no-window
  printf '#!/bin/sh\necho "- keep it small" >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie edit x
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = "- keep it small" ]
  EDITOR="$TMP/ed" COLLIE_TASK=x collie edit
  [ "$(grep -c 'keep it small' "$(task_dir x)/TASK.md")" -eq 2 ]
  # an editor with arguments, like EDITOR='code --wait'
  printf '#!/bin/sh\necho "$1" >>"$2"\n' >"$TMP/ed2"
  chmod +x "$TMP/ed2"
  EDITOR="$TMP/ed2 --wait" collie edit x
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = "--wait" ]
  run env EDITOR="$TMP/ed" bash "$COLLIE_ROOT/bin/collie" edit nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task 'nope'"* ]]
}

@test "edit: a hand-written status: line does not change the derived status" {
  collie new x --no-window
  cat >"$TMP/ed" <<'EOF'
#!/bin/sh
awk 'NR == 2 { print "status: blocked" } { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
EOF
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie edit x
  [ "$(fm x status)" = blocked ]
  [ "$(collie ls | cut -f2)" = todo ]
}

@test "notes, park: removed" {
  collie new x --no-window
  run collie notes x
  [ "$status" -ne 0 ]
  run collie park x -m later
  [ "$status" -ne 0 ]
}

# --- dashboard --------------------------------------------------------------

@test "dash -n: answer > reply > review > stalled > working > start (by priority, id)" {
  for t in a b c d e f g; do collie new "$t" --no-window; done
  collie new z --no-window
  collie archive z
  collie run a -- 300
  collie run b -- 300
  collie run c -- 300
  hook b waiting
  hook c idle
  # d: a past run (no session) that wrote its report
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir d)/events.log"
  echo done >"$(task_dir d)/REPORT.md"
  # e: a past run (no session) without a report
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir e)/events.log"
  collie set g priority=P0
  run collie dash -n
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d' ' -)" = "b c d e a g f" ]
  [ "$(printf '%s\n' "$output" | cut -f1,7 | paste -s -d' ' -)" = "b	answer c	reply d	review e	stalled a	- g	start f	start" ]
  # a stalled task needs you too
  [[ "$(collie _rows | sed $'s/\033\\[[0-9;]*m//g' | cut -f2 | sed -n 4p)" == "● e "*" stalled "* ]]
  [[ "$(collie _rows | sed -n 5p)" == *"── needs you (4) ─"* ]]
}

@test "status: review once the agent is idle and REPORT.md is fresh; working stays active" {
  collie new x --no-window
  collie run x -- 300
  echo "All green." >"$(task_dir x)/REPORT.md"
  [ "$(collie ls | cut -f2)" = active ]
  hook x idle
  [ "$(collie ls | cut -f2)" = review ]
  hook x working
  [ "$(collie ls | cut -f2)" = active ]
}

@test "status: quiet agents without a fresh REPORT.md stay active; preview and show say so" {
  collie new x --no-window
  collie run x -- 300
  hook x working
  run collie _preview x
  [[ "$output" != *"no REPORT.md"* ]]
  hook x idle
  [ "$(collie ls | cut -f2)" = active ]
  run collie _preview x
  [[ "$output" == *$'[active P2]\nno REPORT.md since run 1\n'* ]]
  run collie show x
  [[ "$output" == *$'status: active (no REPORT.md since run 1)\n'* ]]
  echo "All green." >"$(task_dir x)/REPORT.md"
  run collie _preview x
  [[ "$output" == *"[review P2]"* && "$output" != *"no REPORT.md"* ]]
  run collie show x
  [[ "$output" == *$'status: review\n'* ]]
}

@test "dash actions: no next/notes keys" {
  run collie _actions x N
  [ -z "$output" ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key N x)" ]
  [[ "$(FZF_PROMPT='▸ run agent ' COLLIE_DASH="$TMP/dash" collie _preview x)" == *"run agent"*"new task"* ]]
  [[ "$(FZF_PROMPT='▸ run agent ' COLLIE_DASH="$TMP/dash" collie _preview x)" != *notes* ]]
}

@test "dash actions: e edits the task's TASK.md" {
  collie new x --no-window
  [ "$(FZF_PROMPT='▸ adopt agent ' collie _key down x)" = "change-prompt(▸ edit task )+refresh-preview" ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key e x)" == *"_actions 'x' 'e')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='▸ new task ' collie _key e '')" = "change-prompt(collie> )+refresh-preview" ]
  printf '#!/bin/sh\necho edited >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie _actions x e
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = edited ]
}

@test "_key: action keys run their action directly, lazygit style" {
  [[ "$(FZF_PROMPT='collie> ' collie _key r x)" == "change-prompt(collie> )+refresh-preview+bg-transform("*"_bg r x)" ]]
  [ "$(FZF_PROMPT='collie> ' collie _key v x)" = "change-prompt(collie> )+change-preview-label( review )+refresh-preview" ]
  [ "$(FZF_PROMPT='collie> ' FZF_PREVIEW_LABEL=' review ' collie _key v x)" = "change-prompt(collie> )+change-preview-label()+refresh-preview" ]
  [[ "$(FZF_PROMPT='collie> ' collie _key e x)" == "change-prompt(collie> )+clear-screen+execute("*"_actions 'x' 'e')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='collie> ' collie _key d x)" = "change-prompt(? d x )+refresh-preview" ]
  [ "$(FZF_PROMPT='collie> ' collie _key a x)" = "change-prompt(? a x )+refresh-preview" ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key r '')" ]
  [[ "$(FZF_PROMPT='collie> ' collie _key c '')" == *"_actions '' 'c')"* ]]
  [ "$(FZF_PROMPT='collie> ' collie _key q x)" = abort ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key j x)" = down ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key k x)" = up ]
}

@test "_rows: aligned rows grouped needs you > active > todo" {
  for t in a bb ccc-long; do collie new "$t" --no-window; done
  collie run a -- 300
  collie run bb -- 300
  hook bb waiting
  collie set ccc-long priority=P0
  run collie _rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d, -)" = "bb,,a,,ccc-long," ]
  plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g' | cut -f2)
  [ "$(printf '%s\n' "$plain" | sed -n 1p)" = "● bb        answer   P2" ]
  [ "$(printf '%s\n' "$plain" | sed -n 2p)" = "── needs you (1) ──────" ]
  [ "$(printf '%s\n' "$plain" | sed -n 3p)" = "◐ a         working  P2" ]
  [ "$(printf '%s\n' "$plain" | sed -n 5p)" = "○ ccc-long  start    P0" ]
  [ "$(printf '%s\n' "$plain" | sed -n 6p)" = "── todo (1) ───────────" ]
  [[ "$output" == *$'\033[31m●'* && "$output" == *$'\033[33m◐'* && "$output" == *$'\033[1;31mP0'* ]]
  [ "$(paste -s -d, - <"$COLLIE_STATE_DIR/dash-rows")" = "bb,,a,,ccc-long," ]
  # dash -n keeps the same order, ungrouped
  [ "$(collie dash -n | cut -f1 | paste -s -d' ' -)" = "bb a ccc-long" ]
}

@test "_rows: group by priority (P0..P3) or repo; the preview has the last event's age" {
  for t in a b c; do collie new "$t" --no-window; done
  collie set b priority=P0
  collie set c priority=P3
  printf '2020-01-01T00:00:00Z\tnote\t\n' >>"$(task_dir c)/events.log"
  plain=$(collie _rows priority | sed $'s/\033\\[[0-9;]*m//g')
  [ "$(printf '%s\n' "$plain" | cut -f1 | paste -s -d, -)" = "b,,a,,c," ]
  [[ "$(printf '%s\n' "$plain" | sed -n 2p)" == *"── P0 (1) ─"* ]]
  [[ "$(printf '%s\n' "$plain" | sed -n 6p)" == *"── P3 (1) ─"* ]]
  [ "$(printf '%s\n' "$plain" | sed -n 5p | cut -f2)" = "○ c  start  P3" ]
  [[ "$(collie _preview c)" == *$'\n'"last event "*"w ago"$'\n'* ]]
  [[ "$(collie _preview a)" == *$'\n'"last event now"$'\n'* ]]
  [ "$(collie _rows repo | cut -f1 | paste -s -d, -)" = "b,a,c," ]
  [[ "$(collie _rows repo | sed -n 4p)" == *"── A (3) ─"* ]]
}

# gh stub: answers `pr list --head <branch>` from $TMP/prs ("<repo>:<branch>
# <TAB>number<TAB>state" lines, the repo named by its origin) and logs each call
stub_gh() {
  cat >"$TMP/stub/gh" <<STUB
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
while [ \$# -gt 0 ]; do [ "\$1" != --head ] || b=\$2; shift; done
r=\$(git remote get-url origin)
awk -F'\t' -v k="\${r##*origin-}:\$b" '\$1 == k { print \$2 "\t" \$3 }' "$TMP/prs"
STUB
  : >"$TMP/prs"
}

branch_of() { awk -F'\t' -v r="$2" '$1 == r { print $3 }' "$(task_dir "$1")/repos.tsv"; }

@test "dash: PR column, #N per repo colored by state; cached, refreshed in the background once stale" {
  stub_gh
  make_bare_repo B
  cd "$TMP/repos/A/main"
  collie new x -r A -r B --no-window
  for t in y z w; do collie new "$t" --no-window; done
  printf 'A:%s\t244\topen\nB:%s\t12\tmerged\nA:%s\t7\tdraft\nA:%s\t3\tclosed\n' \
    "$(branch_of x A)" "$(branch_of x B)" "$(branch_of y A)" "$(branch_of z A)" >"$TMP/prs"
  # sync looks PRs up inline
  collie sync >/dev/null
  [ "$(collie dash -n | cut -f1,8 | sort | paste -s -d, -)" = $'w\t-,x\t#244:open #12:merged,y\t#7:draft,z\t#3:closed' ]
  run collie _rows
  plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g' | cut -f2)
  [[ "$plain" == *"○ x  start  P2  #244 #12"$'\n'* ]]
  [[ "$plain" == "○ w  start  P2"$'\n'* ]]
  [[ "$(collie _preview x)" == *$'\n'"  A  $(branch_of x A)  #244 open  "* ]]
  [[ "$output" == *$'\033[32m#244\033[0m \033[35m#12\033[0m'* ]]
  [[ "$output" == *$'\033[2m#7\033[0m'* && "$output" == *$'\033[31m#3\033[0m'* ]]
  # a fresh cache: no gh call on render
  : >"$TMP/gh.log"
  collie _rows >/dev/null
  collie dash -n >/dev/null
  sleep 0.5
  [ ! -s "$TMP/gh.log" ]
  # a stale one: one background lookup, shown on the next render
  printf 'A:%s\t9\topen\n' "$(branch_of w A)" >>"$TMP/prs"
  touch -t 202001010000 "$(task_dir w)/pr.tsv"
  collie dash -n >/dev/null
  wait_for '[ "$(collie dash -n | awk -F"\t" "\$1 == \"w\" { print \$8 }")" = "#9:open" ]'
  [ "$(wc -l <"$TMP/gh.log")" -eq 1 ]
}

@test "dash: PR column shows - when gh fails; a failed lookup keeps the last entry" {
  collie new x --no-window
  collie new y --no-window
  printf 'A\t5\tmerged\n' >"$(task_dir y)/pr.tsv"
  run collie sync
  [ "$status" -eq 0 ]
  [[ "$output" != *gh* ]]
  [ "$(collie dash -n | cut -f1,8 | sort | paste -s -d, -)" = $'x\t-,y\t#5:merged' ]
  run collie _rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g' | cut -f2 | sed -n 1p)" = "○ x  start  P2" ]
}

@test "_group: tab cycles the grouping, kept across dashboards; not while the menu is up" {
  collie new a --no-window
  [[ "$(FZF_PROMPT='collie> ' collie _group next)" == "change-header(enter: go  tab: group by "$'\033[1;33m'"priority"$'\033[0m'"  /: filter  space: mark"$'\n'"r: run  u: runs  v: review  e: edit  d: done  s: sync  ?: more)+reload("*"_rows)" ]]
  [[ "$(collie _rows | sed -n 2p)" == *"── P2 (1) ─"* ]]
  FZF_PROMPT='collie> ' collie _group next >/dev/null
  [ "$(cat "$COLLIE_STATE_DIR/dash-group")" = repo ]
  [[ "$(FZF_PROMPT='collie> ' collie _group next)" == *"group by "$'\033[1;33m'"status"$'\033'* ]]
  [[ "$(FZF_PROMPT='collie> ' collie _group prev)" == *"group by "$'\033[1;33m'"repo"$'\033'* ]]
  [ -z "$(FZF_PROMPT='▸ run agent ' collie _group next)" ]
  [ "$(cat "$COLLIE_STATE_DIR/dash-group")" = repo ]
}

@test "_key: arrows step over group separators; enter on one does nothing" {
  mkdir -p "$COLLIE_STATE_DIR"
  printf '%s\n' b '' a '' >"$COLLIE_STATE_DIR/dash-rows"
  [ "$(FZF_PROMPT='collie> ' FZF_POS=1 collie _key up b)" = "up+up" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key down a)" = "down+down" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=2 collie _key up '')" = up ]
  [ -z "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key up a)" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=1 FZF_QUERY=x collie _key up b)" = up ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key enter '')" ]
  [ -z "$(collie _preview '')" ]
}

@test "manual agent: one started by hand in a task session shows up, idle by silence" {
  collie new x
  mkdir -p "$TMP/bin"
  fake_agent "$TMP/bin/claude"
  tmux new-window -d -t "=x:" "sh -c '$TMP/bin/claude -c \"read -t 300\"; :'"
  # ps must retain the full executable path even in a narrow terminal.
  export COLUMNS=40
  wait_for '[ "$(COLLIE_SILENCE=999 agent_of x)" = working ]'
  [ "$(COLLIE_SILENCE=0 agent_of x)" = idle ]
  [[ "$(collie _preview x)" == *$'\n'"claude · last event "* ]]
  run collie show x
  [[ "$output" == *"-	claude	"* ]]
}

@test "adopt: stops a hand-started agent and resumes it under collie run" {
  collie new x
  mkdir -p "$TMP/bin" "$TMP/manual"
  fake_agent "$TMP/manual/claude"
  printf '#!/bin/sh\necho "$@" >"%s/args"\nexec sleep 300\n' "$TMP" >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"
  tmux new-window -d -t "=x:" -c "$TMP/repos/A/feat-x" "sh -c '$TMP/manual/claude -c \"read -t 300\"; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  run collie adopt x </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirm with -y"* ]]
  collie adopt x -y
  wait_for '[ -f "$TMP/args" ]'
  [[ "$(cat "$TMP/args")" == *"--settings"*"--continue" ]]
  ! pgrep -f "$TMP/manual/claude" >/dev/null
  grep -q "agent_adopted	agent=claude" "$(task_dir x)/events.log"
  grep -q "run_started	run=1 agent=claude repo=A" "$(task_dir x)/events.log"
  run collie adopt x -y
  [[ "$output" == *"no agent started by hand"* ]]
}

@test "_key: menu keys act only while the menu prompt is up; arrows move the selection" {
  [ "$(FZF_PROMPT='collie> ' collie _key esc x)" = abort ]
  [ "$(FZF_PROMPT='collie> ' collie _key enter x)" = clear-multi+accept ]
  [ "$(FZF_PROMPT='collie> ' collie _key up x)" = up ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key r x)" == "change-prompt(collie> )+refresh-preview+bg-transform("*"_bg r x)" ]]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key down x)" = "change-prompt(▸ adopt agent )+refresh-preview" ]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key up x)" = "change-prompt(▸ new task )+refresh-preview" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key down x)" = "change-prompt(▸ run agent )+refresh-preview" ]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key j x)" = "change-prompt(▸ adopt agent )+refresh-preview" ]
  [[ "$(FZF_PROMPT='▸ review ' collie _key enter x)" == *"change-preview-label( review )"* ]]
  [ "$(FZF_PROMPT='▸ archive ' collie _key enter x)" = "change-prompt(? x x )+refresh-preview" ]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key esc x)" = "change-prompt(collie> )+refresh-preview" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key r '')" = "change-prompt(collie> )+refresh-preview" ]
}

@test "_actions: terminal opens a shell in the task's worktree; other keys do nothing" {
  collie new x --no-window
  collie _actions x q
  collie _actions x d
  [ -z "$(fm x status)" ]
  printf '#!/bin/sh\npwd >"%s/pwd"\nexit 3\n' "$TMP" >"$TMP/sh"
  chmod +x "$TMP/sh"
  SHELL="$TMP/sh" collie _actions x t
  [ "$(cat "$TMP/pwd")" = "$TMP/repos/A/feat-x" ]
}

@test "_key: a question in the panel; y runs it in the background, any other key cancels" {
  collie new x --no-window
  export COLLIE_DASH="$TMP/dash"
  mkdir -p "$COLLIE_DASH"
  [ "$(FZF_PROMPT='? d x ' collie _key n x)" = "change-prompt(collie> )+refresh-preview" ]
  [ "$(FZF_PROMPT='? d x ' collie _key r x)" = "change-prompt(collie> )+refresh-preview" ]
  [ ! -f "$COLLIE_DASH/msg" ]
  [ -z "$(FZF_PROMPT='? d x ' collie _group next)" ]
  [[ "$(FZF_PROMPT='? d x ' collie _key y x)" == "change-prompt(collie> )+refresh-preview+bg-transform("*"_bg d x)" ]]
  [ "$(cat "$COLLIE_DASH/msg")" = $'run\n… done x' ]
  [[ "$(FZF_PROMPT='? d x ' collie _preview x)" == *"done x? (y/n)"*"objective:"* ]]
  [[ "$(FZF_PROMPT='? a x ' collie _preview x)" == *"adopt x? (y/n)"* ]]
}

@test "_bg: runs the action; success is one line that fades, failure stays until a key" {
  collie new x --no-window
  collie new y --no-window
  export COLLIE_DASH="$TMP/dash"
  mkdir -p "$COLLIE_DASH"
  [[ "$(collie _bg r x)" == "reload("*"_rows)+refresh-preview+bg-transform("*"_fade)" ]]
  [ -n "$(run_pane x)" ]
  [[ "$(FZF_PROMPT='collie> ' collie _preview x)" == *"✓ run x"*"objective:"* ]]
  [ "$(collie _fade)" = refresh-preview ]
  [ ! -f "$COLLIE_DASH/msg" ]
  collie _bg d x >/dev/null
  [ "$(fm x status)" = done ]
  # adopt fails: y has no session
  [[ "$(collie _bg a y)" == "reload("*"_rows)+refresh-preview" ]]
  run env FZF_PROMPT='collie> ' bash "$COLLIE_ROOT/bin/collie" _preview y
  [[ "$output" == *"✗ adopt y (exit 1)"*"has no session"*"[press any key]"* ]]
  [[ "$output" != *"objective:"* ]]
  [ -z "$(collie _fade)" ]
  [ "$(FZF_PROMPT='filter: ' collie _key j y)" = "put(j)" ]
  [ "$(FZF_PROMPT='collie> ' collie _key j y)" = refresh-preview ]
  [ ! -f "$COLLIE_DASH/msg" ]
  collie _bg x y >/dev/null
  [ "$(fm y status)" = archived ]
}

@test "_jump: waiting/idle records the pane; nothing recorded is an error" {
  collie new x --no-window
  run collie _jump
  [ "$status" -ne 0 ]
  [[ "$output" == *"no agent pane to jump to"* ]]
  collie run x -- 300
  hook x working
  [ -z "$(tmux show-options -gqv @collie-last-pane)" ]
  hook x waiting
  [ "$(tmux show-options -gqv @collie-last-pane)" = "$(run_pane x)" ]
}

@test "_preview: title, derived status, runs, per-repo ahead/dirty" {
  collie new x --no-window --title "Ship it"
  wt="$TMP/repos/A/feat-x"
  echo hi >"$wt/f"
  git -C "$wt" add f
  git -C "$wt" commit -q -m f
  echo dirty >"$wt/g"
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ship it"* ]]
  [[ "$output" == *"Ship it  [todo P2]"* ]]
  [[ "$output" == *"A  feat/x  1 ahead, 1 dirty"* ]]
}

@test "_preview: the start of TASK.md's Objective" {
  collie new x --no-window -m "Add OAuth login"
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'objective:\n  Add OAuth login\n'* ]]
  [[ "$output" != *"## Context"* ]]
  collie new y --no-window
  run collie _preview y
  [[ "$output" == *$'objective:\n  (empty)\n'* ]]
}

@test "_target: window of the most urgent run (where dash jumps to)" {
  collie new x --no-window
  collie run x -- 300
  collie run x -- 300
  hook x waiting 2
  [ "$(collie _target x)" = "$(tmux display -p -t "$(run_pane x 2)" '#{window_id}')" ]
}

# --- tmux integration -------------------------------------------------------

@test "done works from tmux run-shell (menu action)" {
  collie new x
  tmux run-shell "$COLLIE_ROOT/bin/collie done x"
  [ "$(fm x status)" = done ]
}

@test "_key: space marks tasks (not separators); / shows the input, where every key types" {
  [ "$(FZF_PROMPT='collie> ' collie _key space x)" = toggle ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key space '')" ]
  [ "$(FZF_PROMPT='collie> ' collie _key / x)" = "show-input+change-prompt(filter: )" ]
  [ "$(FZF_PROMPT='filter: ' collie _key space x)" = "put( )" ]
  [ "$(FZF_PROMPT='filter: ' collie _key / x)" = "put(/)" ]
  [ "$(FZF_PROMPT='filter: ' collie _key r x)" = "put(r)" ]
  [ "$(FZF_PROMPT='filter: ' collie _key '?' x)" = "put(?)" ]
  # enter keeps the filter (shown in the header), esc drops it
  [[ "$(FZF_PROMPT='filter: ' FZF_QUERY=dep collie _key enter x)" == "hide-input+change-prompt(collie> )+change-header(filter: "$'\033[1;33m'"dep"$'\033[0m'"  esc: clear  enter: go"* ]]
  [[ "$(FZF_PROMPT='filter: ' FZF_QUERY=dep collie _key esc x)" == "clear-query+change-prompt(collie> )+change-header("* ]]
  [[ "$(FZF_PROMPT='filter: ' FZF_QUERY=dep collie _key esc x)" != *"dep"* ]]
  [[ "$(FZF_PROMPT='collie> ' FZF_QUERY=dep collie _key esc x)" == "show-input+clear-query+change-header("* ]]
  [ "$(FZF_PROMPT='collie> ' collie _key esc x)" = abort ]
}

@test "_key: sync gets the marked ids (separators dropped), other actions only the cursor's" {
  [ "$(FZF_PROMPT='▸ run agent ' collie _key s x a '' b)" = "change-prompt(? s a b )+refresh-preview" ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key e x a b)" == *"_actions 'x' 'e')+reload("* ]]
  [ "$(FZF_PROMPT='collie> ' collie _key s x a b)" = "change-prompt(? s a b )+refresh-preview" ]
  [ "$(FZF_PROMPT='collie> ' collie _key s x)" = "change-prompt(? s x )+refresh-preview" ]
  [[ "$(FZF_PROMPT='? s a b ' collie _key y x a b)" == *"bg-transform("*"_bg s a b)" ]]
  [ "$(FZF_PROMPT='▸ archive ' collie _key down x)" = "change-prompt(▸ sync )+refresh-preview" ]
}

@test "dash: keys work with no tasks (c opens new task, q quits)" {
  command -v fzf >/dev/null || skip "fzf not installed"
  tmux -f /dev/null new-session -d -s d -x 120 -y 30 \
    "'${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' dash; echo dash-exit; sleep 60"
  wait_for "tmux capture-pane -p -t =d: | grep -q 'no tasks'"
  tmux send-keys -t =d: c
  wait_for "tmux capture-pane -p -t =d: | grep -q 'task id:'"
  # leave the form: EOF fails `new`, any key returns to the dash
  tmux send-keys -t =d: C-d
  wait_for "tmux capture-pane -p -t =d: | grep -q 'press any key'"
  tmux send-keys -t =d: x
  wait_for "tmux capture-pane -p -t =d: | grep -q 'no tasks'"
  tmux send-keys -t =d: q
  wait_for "tmux capture-pane -p -t =d: | grep -q dash-exit"
}
@test "_rows: whole ids (fzf filters on them); the preview goes below when rows do not fit beside it" {
  local id=luwa-201949-ulh-spark-operations-runbook
  collie new "$id" --no-window
  printf 'A\t244\topen\n' >"$(task_dir "$id")/pr.tsv"
  [ "$(collie _rows | sed $'s/\033\\[[0-9;]*m//g' | cut -f2 | sed -n 1p)" = "○ $id  start  P2  #244" ]
  [ "$(cat "$COLLIE_STATE_DIR/dash-width")" -eq 59 ]
  # 140 columns: a 66-column list holds the rows; 120: 56 does not
  [[ "$(FZF_COLUMNS=140 FZF_PROMPT='collie> ' collie _key resize x)" == "change-preview-window(right,50%,wrap)+change-header("* ]]
  [[ "$(FZF_COLUMNS=120 FZF_PROMPT='collie> ' collie _key resize x)" == "change-preview-window(down,45%,wrap)+change-header("* ]]
  # the menu stays open across a resize
  [ -z "$(FZF_COLUMNS=120 FZF_PROMPT='▸ run agent ' collie _key resize x)" ]
}

@test "dash header: key hints wrap at the list's width, none cut" {
  local c w h l out
  export LC_ALL=C.UTF-8
  collie new x --no-window
  collie _rows >/dev/null
  for c in 300 120 80 60 40; do
    # short rows: the preview is right while the list keeps 40 columns
    w=$((c - c / 2 - 4))
    [ "$w" -ge 40 ] || w=$((c - 3))
    out=$(FZF_COLUMNS=$c FZF_PROMPT='collie> ' FZF_QUERY=dep collie _key resize x)
    h=${out#*+change-header(}
    h=$(sed $'s/\033\\[[0-9;]*m//g' <<<"${h%)}")
    while IFS= read -r l; do [ "${#l}" -le "$w" ] || { echo "$c: ${#l} > $w: $l"; false; }; done <<<"$h"
    # every hint whole, in order
    [ "$(sed 's/  /\n/g' <<<"$h" | paste -s -d, -)" = "filter: dep,esc: clear,enter: go,tab: group by status,/: filter,space: mark,r: run,u: runs,v: review,e: edit,d: done,s: sync,?: more" ]
  done
  [ "$(FZF_COLUMNS=300 collie _key resize x | grep -c .)" -eq 2 ]
}

@test "dash: at 80 columns a long id row keeps state, priority and PR; the preview goes below" {
  command -v fzf >/dev/null || skip "fzf not installed"
  local id=luwa-201949-ulh-spark-operations-runbook
  collie new "$id" --no-window
  printf 'A\t244\topen\n' >"$(task_dir "$id")/pr.tsv"
  tmux -f /dev/null new-session -d -s d -x 80 -y 24 \
    "'${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' dash; sleep 60"
  wait_for "tmux capture-pane -p -t =d: | grep -q 'objective:'"
  tmux capture-pane -p -t =d: >"$TMP/screen"
  grep -q "$id  start  P2  #244" "$TMP/screen"
  grep -q "enter: go  tab: group by status  /: filter  space: mark" "$TMP/screen"
  grep -q "r: run  u: runs  v: review  e: edit  d: done  s: sync  ?: more" "$TMP/screen"
  ! grep -q "··" "$TMP/screen"
  # the preview sits below the list
  [ "$(grep -n 'objective:' "$TMP/screen" | cut -d: -f1)" -gt "$(grep -n '?: more' "$TMP/screen" | cut -d: -f1)" ]
}
@test "dash: actions answer in the panel while the list stays (no full-screen popup)" {
  command -v fzf >/dev/null || skip "fzf not installed"
  collie new w --no-window
  collie new x --no-window
  tmux -f /dev/null new-session -d -s d -x 140 -y 24 \
    "'${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' dash; echo dash-exit; sleep 60"
  wait_for "tmux capture-pane -p -t =d: | grep -q '○ x '"
  tmux send-keys -t =d: '?'
  wait_for "tmux capture-pane -p -t =d: | grep -q '↑↓ enter · key · esc'"
  tmux capture-pane -p -t =d: | grep -q '○ x '
  tmux send-keys -t =d: Escape
  wait_for "! tmux capture-pane -p -t =d: | grep -q '↑↓ enter · key · esc'"
  tmux send-keys -t =d: a
  wait_for "tmux capture-pane -p -t =d: | grep -q 'adopt w? (y/n)'"
  tmux send-keys -t =d: y
  # failure: the output stays until a key, which only clears it
  wait_for "tmux capture-pane -p -t =d: | grep -q 'press any key'"
  tmux capture-pane -p -t =d: | grep -q '○ x '
  tmux send-keys -t =d: d
  wait_for "! tmux capture-pane -p -t =d: | grep -q 'press any key'"
  [ -z "$(fm w status)" ]
  tmux send-keys -t =d: d
  wait_for "tmux capture-pane -p -t =d: | grep -q 'done w? (y/n)'"
  tmux send-keys -t =d: y
  wait_for "tmux capture-pane -p -t =d: | grep -q '✓ done w'"
  [ "$(fm w status)" = done ]
  wait_for "! tmux capture-pane -p -t =d: | grep -q '○ w '"
  # the success line fades
  wait_for "! tmux capture-pane -p -t =d: | grep -q '✓ done w'"
  tmux send-keys -t =d: q
  wait_for "tmux capture-pane -p -t =d: | grep -q dash-exit"
  [ -z "$(find "$COLLIE_STATE_DIR" -maxdepth 1 -name 'dash.*')" ]
}
