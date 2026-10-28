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
  [[ "$(collie _rows | sed $'s/\033\\[[0-9;]*m//g' | cut -f2 | sed -n 5p)" == "● e "*" stalled "* ]]
  [[ "$(collie _rows | sed -n 6p)" == *"── needs you (4) ─"* ]]
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
  [ "$(FZF_PROMPT='collie> ' collie _key x N)" = "put(N)" ]
  [[ "$(collie _pick x 2>/dev/null)" != *notes* ]]
}

@test "dash actions: e edits the task's TASK.md" {
  collie new x --no-window
  [ "$(FZF_PROMPT='▸ adopt agent ' collie _key x down)" = "change-prompt(▸ edit task )" ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x e)" == *"_actions 'x' 'e')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='▸ new task ' collie _key '' e)" = "change-prompt(collie> )+clear-screen" ]
  printf '#!/bin/sh\necho edited >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie _actions x e
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = edited ]
}

@test "_key: ctrl keys run their action directly, menu open or not" {
  [[ "$(FZF_PROMPT='collie> ' collie _key x ctrl-r)" == "change-prompt(collie> )+clear-screen+execute("*"_actions 'x' 'r')+reload("*"_rows)+refresh-preview" ]]
  [[ "$(FZF_PROMPT='▸ adopt agent ' collie _key x ctrl-v)" == *"_actions 'x' 'v')"* ]]
  [[ "$(FZF_PROMPT='collie> ' collie _key x ctrl-e)" == *"_actions 'x' 'e')"* ]]
  [[ "$(FZF_PROMPT='collie> ' collie _key x ctrl-d)" == *"_actions 'x' 'd')"* ]]
  [ -z "$(FZF_PROMPT='collie> ' collie _key '' ctrl-r)" ]
}

@test "_rows: column names, then aligned rows grouped needs you > active > todo" {
  for t in a bb ccc-long; do collie new "$t" --no-window; done
  collie run a -- 300
  collie run bb -- 300
  hook bb waiting
  collie set ccc-long priority=P0
  run collie _rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d, -)" = ",bb,,a,,ccc-long," ]
  plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g' | cut -f2)
  [ "$(printf '%s\n' "$plain" | sed -n 1p)" = "  TASK      STATE    PRI  AGENT  AGE  REPOS  PR" ]
  [ "$(printf '%s\n' "$plain" | sed -n 2p)" = "● bb        answer   P2   sleep  now  A      -" ]
  [ "$(printf '%s\n' "$plain" | sed -n 3p)" = "── needs you (1) ──────────────────────────────" ]
  [ "$(printf '%s\n' "$plain" | sed -n 4p)" = "◐ a         working  P2   sleep  now  A      -" ]
  [ "$(printf '%s\n' "$plain" | sed -n 6p)" = "○ ccc-long  start    P0   -      now  A      -" ]
  [ "$(printf '%s\n' "$plain" | sed -n 7p)" = "── todo (1) ───────────────────────────────────" ]
  [[ "$output" == *$'\033[31m●'* && "$output" == *$'\033[33m◐'* && "$output" == *$'\033[1;31mP0'* ]]
  [ "$(paste -s -d, - <"$COLLIE_STATE_DIR/dash-rows")" = "bb,,a,,ccc-long," ]
  # dash -n keeps the same order, ungrouped
  [ "$(collie dash -n | cut -f1 | paste -s -d' ' -)" = "bb a ccc-long" ]
}

@test "_rows: group by priority (P0..P3) or repo; age of the last event" {
  for t in a b c; do collie new "$t" --no-window; done
  collie set b priority=P0
  collie set c priority=P3
  printf '2020-01-01T00:00:00Z\tnote\t\n' >>"$(task_dir c)/events.log"
  plain=$(collie _rows priority | sed $'s/\033\\[[0-9;]*m//g')
  [ "$(printf '%s\n' "$plain" | cut -f1 | paste -s -d, -)" = ",b,,a,,c," ]
  [[ "$(printf '%s\n' "$plain" | sed -n 3p)" == *"── P0 (1) ─"* ]]
  [[ "$(printf '%s\n' "$plain" | sed -n 7p)" == *"── P3 (1) ─"* ]]
  [[ "$(printf '%s\n' "$plain" | sed -n 6p)" == *"  P3   -      "*"w  A      -" ]]
  [ "$(collie _rows repo | cut -f1 | paste -s -d, -)" = ",b,a,c," ]
  [[ "$(collie _rows repo | sed -n 5p)" == *"── A (3) ─"* ]]
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
  [ "$(printf '%s\n' "$plain" | sed -n 1p)" = "  TASK  STATE  PRI  AGENT  AGE  REPOS  PR" ]
  [[ "$plain" == *$'\n'"○ x     start  P2   -      now  A,B    #244 #12"$'\n'* ]]
  [[ "$plain" == *$'\n'"○ w     start  P2   -      now  A      -"$'\n'* ]]
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
  [[ "$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')" == *"○ x     start  P2   -      now  A      -"* ]]
}

@test "_group: tab cycles the grouping, kept across dashboards; not while the menu is up" {
  collie new a --no-window
  [[ "$(FZF_PROMPT='collie> ' collie _group next)" == "change-header(enter: go  tab: group by "$'\033[1;33m'"priority"$'\033[0m'"  space: mark  /: search"$'\n'"^r: run  ^v: review  ^e: edit  ^d: done  ?: more)+reload("*"_rows)" ]]
  [[ "$(collie _rows | sed -n 3p)" == *"── P2 (1) ─"* ]]
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
  [ "$(FZF_PROMPT='collie> ' FZF_POS=1 collie _key b up)" = "up+up" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key a down)" = "down+down" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=2 collie _key '' up)" = up ]
  [ -z "$(FZF_PROMPT='collie> ' FZF_POS=3 collie _key a up)" ]
  [ "$(FZF_PROMPT='collie> ' FZF_POS=1 FZF_QUERY=x collie _key b up)" = up ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key '' enter)" ]
  [ -z "$(collie _preview '')" ]
}

@test "manual agent: one started by hand in a task session shows up, idle by silence" {
  collie new x
  mkdir -p "$TMP/bin"
  ln -s "$(command -v sleep)" "$TMP/bin/claude"
  tmux new-window -d -t "=x:" "sh -c '$TMP/bin/claude 300; :'"
  wait_for '[ "$(COLLIE_SILENCE=999 agent_of x)" = working ]'
  [ "$(COLLIE_SILENCE=0 agent_of x)" = idle ]
  [[ "$(collie _rows | sed $'s/\033\\[[0-9;]*m//g')" == *"  claude  "* ]]
  run collie show x
  [[ "$output" == *"-	claude	"* ]]
}

@test "adopt: stops a hand-started agent and resumes it under collie run" {
  collie new x
  mkdir -p "$TMP/bin" "$TMP/manual"
  ln -s "$(command -v sleep)" "$TMP/manual/claude"
  printf '#!/bin/sh\necho "$@" >"%s/args"\nexec sleep 300\n' "$TMP" >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"
  tmux new-window -d -t "=x:" -c "$TMP/repos/A/feat-x" "sh -c '$TMP/manual/claude 300; :'"
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
  [ "$(FZF_PROMPT='collie> ' collie _key x r)" = "put(r)" ]
  [ "$(FZF_PROMPT='collie> ' collie _key x esc)" = abort ]
  [ "$(FZF_PROMPT='collie> ' collie _key x enter)" = clear-multi+accept ]
  [ "$(FZF_PROMPT='collie> ' collie _key x up)" = up ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x r)" == "change-prompt(collie> )+clear-screen+execute("*"_actions 'x' 'r')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x down)" = "change-prompt(▸ adopt agent )" ]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x up)" = "change-prompt(▸ new task )" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key x down)" = "change-prompt(▸ run agent )" ]
  [[ "$(FZF_PROMPT='▸ review ' collie _key x enter)" == *"_actions 'x' 'v'"* ]]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x esc)" = "change-prompt(collie> )+clear-screen" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key '' r)" = "change-prompt(collie> )+clear-screen" ]
}

@test "_actions: one key runs an action on the task; done and archive ask first" {
  collie new x --no-window
  collie _actions x r
  [ -n "$(run_pane x)" ]
  echo n | collie _actions x d
  [ -z "$(fm x status)" ]
  collie _actions x q
  printf '#!/bin/sh\npwd >"%s/pwd"\nexit 3\n' "$TMP" >"$TMP/sh"
  chmod +x "$TMP/sh"
  SHELL="$TMP/sh" collie _actions x t
  [ "$(cat "$TMP/pwd")" = "$TMP/repos/A/feat-x" ]
  echo n | collie _actions x x
  [ -z "$(fm x status)" ]
  echo y | collie _actions x x
  [ "$(fm x status)" = archived ]
}

@test "_actions: done after confirm" {
  collie new x --no-window
  echo y | collie _actions x d
  [ "$(fm x status)" = done ]
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

@test "_key: space marks tasks (not separators), / starts a search where space and / type" {
  [ "$(FZF_PROMPT='collie> ' collie _key x space)" = toggle ]
  [ -z "$(FZF_PROMPT='collie> ' collie _key '' space)" ]
  [ "$(FZF_PROMPT='collie> ' collie _key x /)" = "change-prompt(/ )" ]
  [ "$(FZF_PROMPT='/ ' collie _key x space)" = "put( )" ]
  [ "$(FZF_PROMPT='/ ' collie _key x /)" = "put(/)" ]
  [ "$(FZF_PROMPT='/ ' collie _key x r)" = "put(r)" ]
  [ "$(FZF_PROMPT='/ ' collie _key x esc)" = "change-prompt(collie> )" ]
  [ "$(FZF_PROMPT='/ ' collie _key x enter)" = clear-multi+accept ]
}

@test "_key: sync gets the marked ids (separators dropped), other actions only the cursor's" {
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x s a '' b)" == *"_actions 'x' 's' 'a' 'b')+reload("* ]]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x e a b)" == *"_actions 'x' 'e')+reload("* ]]
  [ "$(FZF_PROMPT='collie> ' collie _key x s a b)" = "put(s)" ]
  [ "$(FZF_PROMPT='▸ archive ' collie _key x down)" = "change-prompt(▸ sync )" ]
}
