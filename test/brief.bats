#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

@test "brief: nothing waits on you" {
  run collie brief
  [ "$status" -eq 0 ]
  [ "$output" = "nothing waits on you" ]
  collie new x --no-window
  collie run x -- 300
  [ "$(collie brief)" = "nothing waits on you" ]
}

@test "brief: tasks are ordered by urgency, include actions, and do not call gh" {
  printf '#!/bin/sh\necho "$*" >>"%s/gh.log"\nexit 1\n' "$TMP" >"$TMP/stub/gh"
  for t in a b c d e f g h; do collie new "$t" --no-window; done
  collie run a -- 300
  collie run b -- 300
  collie run c -- 300
  collie run f -- 0
  hook b waiting
  hook c idle
  # d, h: past runs (no session) that wrote their reports; d's PR is cached
  for t in d h; do
    printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir "$t")/events.log"
  done
  printf '# d report\n\nPR: https://github.com/o/r/pull/7\n\n- Added the thing.\n' >"$(task_dir d)/REPORT.md"
  printf 'A\t7\topen\tfail\n' >"$(task_dir d)/pr.tsv"
  printf '# h\n\nAll green.\n' >"$(task_dir h)/REPORT.md"
  printf 'A\t9\tdraft\n' >"$(task_dir h)/pr.tsv"
  collie set h priority=P1
  # e: a past run (no session) without a report: lost with the tmux server
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir e)/events.log"
  # f: its agent exited without a report
  wait_for '[ "$(collie ls | awk -F"\t" "\$1 == \"f\" { print \$7 }")" = stalled ]'
  run collie brief
  [ "$status" -eq 0 ]
  [[ "$output" == *$'answer  b (P2)\n'*'Next: collie go b'* ]]
  [[ "$output" == *$'reply  c (P2)\n'*'Next: collie go c'* ]]
  [[ "$output" == *$'review  h (P1)\n'*'PR: #9 draft'*'Next: collie review h'* ]]
  [[ "$output" == *$'review  d (P2)\n'*'Added the thing.'*'https://github.com/o/r/pull/7'*'CI fail'*'Next: collie review d'* ]]
  [[ "$output" == *'Next: collie restore e'*'Next: collie run f'*'Next: collie ci d --send'* ]]
  headers=$(printf '%s\n' "$output" | grep -E '^(answer|reply|review|stalled|ci)  ')
  [ "$headers" = $'answer  b (P2)\nreply  c (P2)\nreview  h (P1)\nreview  d (P2)\nstalled  e (P2)\nstalled  f (P2)\nci  d (P2)' ]
  [ ! -s "$TMP/gh.log" ]
}

@test "_pr: caches CI state; dash still reads the PR column" {
  cat >"$TMP/stub/gh" <<'STUB'
#!/bin/sh
printf '12\topen\tpass\n'
STUB
  collie new x --no-window
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = "A	12	open	pass" ]
  [ "$(collie dash -n | cut -f8)" = "#12:open" ]
}

@test "brief: multiple cached PRs keep their own numbers and CI states with a report URL" {
  collie new x --no-window
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir x)/events.log"
  printf '# report\n\nPR: https://github.com/o/r/pull/7\n\nReady.\n' >"$(task_dir x)/REPORT.md"
  printf 'A\t7\tmerged\tpass\nA\t83\topen\tfail\n' >"$(task_dir x)/pr.tsv"
  out=$(collie brief)
  [[ "$out" == *'https://github.com/o/r/pull/7; #7 merged, CI pass;'* && "$out" == *'#83 open, CI fail'* ]]
}

@test "brief: a ci row for open and draft PRs with cached CI fail, without calling gh" {
  printf '#!/bin/sh\necho "$*" >>"%s/gh.log"\nexit 1\n' "$TMP" >"$TMP/stub/gh"
  for t in a b c; do collie new "$t" --no-window; done
  printf 'A\t7\tmerged\tfail\nA\t8\tdraft\tfail\nA\t9\topen\tfail\n' >"$(task_dir a)/pr.tsv"
  printf 'A\t5\topen\tpass\n' >"$(task_dir b)/pr.tsv"
  printf 'A\t6\tclosed\tfail\n' >"$(task_dir c)/pr.tsv"
  run collie brief
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ci  a (P2)\n'*'PR #8, #9 has failing CI'*'Next: collie ci a --send'* ]]
  [[ "$output" != *'ci  b (P2)'* && "$output" != *'ci  c (P2)'* ]]
  [ ! -s "$TMP/gh.log" ]
}

@test "brief: long review details wrap without obscuring the next action" {
  collie new x --no-window
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir x)/events.log"
  printf '# Report\n\nA long summary that needs to wrap at a word boundary so the command remains easy to find.\n' >"$(task_dir x)/REPORT.md"
  COLUMNS=48 run collie brief
  [ "$status" -eq 0 ]
  [[ "$output" == *$'review  x (P2)\n  Why: A long summary'*$'\n    '*$'\n  Next: collie review x'* ]]
  while IFS= read -r line; do [ "${#line}" -le 48 ]; done <<<"$output"
}
