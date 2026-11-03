#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  make_bare_repo B
  cd "$TMP/repos/A/main"
  collie new x -r A -r B --no-window
  cat >"$TMP/stub/gh" <<'EOF'
#!/bin/sh
repo=$(git remote get-url origin)
repo=${repo##*origin-}
if [ "$1 $2" = "pr list" ]; then
  if [ "$repo" = A ]; then printf '70\tmerged\tpass\n71\tclosed\t-\n'; else printf '70\topen\tpending\n'; fi
elif [ "$1 $2" = "pr view" ]; then
  if [ -f "$FAIL_VIEW" ]; then exit 1; fi
  case "$3" in 83) printf '83\topen\tfail\n' ;; 70) printf '70\tmerged\tpass\n' ;; esac
else
  if [ "$repo" = A ] && [ -f "$FAIL_SEARCH" ]; then exit 1; fi
  case "$repo:$*" in
    *'"70"'*) if [ "$repo" = A ]; then printf '83\n70\n'; fi ;;
  esac
fi
EOF
  chmod +x "$TMP/stub/gh"
  export FAIL_SEARCH="$TMP/fail-search" FAIL_VIEW="$TMP/fail-view"
}
teardown() { teardown_env; }

@test "refresh discovers multiple branch and restoration PRs per repository, deduplicated" {
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = $'A\t70\tmerged\tpass\nA\t71\tclosed\t-\nA\t83\topen\tfail\nB\t70\topen\tpending' ]
  [[ "$(collie dash -n)" == *'#70:merged #71:closed #83:open #70:open'* ]]
}

@test "failed search preserves all previous rows only for the failed repository" {
  printf 'A\t70\tmerged\tpass\nA\t83\tdraft\tfail\nB\t99\tclosed\t-\n' >"$(task_dir x)/pr.tsv"
  touch "$FAIL_SEARCH"
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = $'A\t70\tmerged\tpass\nA\t83\tdraft\tfail\nB\t70\topen\tpending' ]
}

@test "failed restoration details preserve repository state including CI" {
  printf 'A\t70\tmerged\tpass\nA\t83\tdraft\tfail\n' >"$(task_dir x)/pr.tsv"
  touch "$FAIL_VIEW"
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = $'A\t70\tmerged\tpass\nA\t83\tdraft\tfail\nB\t70\topen\tpending' ]
}
