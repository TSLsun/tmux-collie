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

@test "brief: one line per task that needs you, most urgent first, with the command; no gh" {
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
  [ "$output" = "answer   b (P2): an agent waits for your answer  ->  collie go b
reply    c (P2): an agent finished its turn without a REPORT.md  ->  collie go c
review   h (P1): All green. | PR #9 draft  ->  collie review h
review   d (P2): Added the thing. | PR https://github.com/o/r/pull/7 (open, CI fail)  ->  collie review d
stalled  e (P2): its agents were lost with the tmux server  ->  collie restore e
stalled  f (P2): no agent running and no REPORT.md since the last run  ->  collie run f" ]
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
