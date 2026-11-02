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
if [ "$1" = pr ]; then
  if [ "$repo" = A ]; then printf '70\tmerged\n71\tclosed\n'; else printf '70\topen\n'; fi
else
  if [ "$repo" = A ] && [ -f "$FAIL_SEARCH" ]; then exit 1; fi
  case "$repo:$*" in
    *'"70"'*) if [ "$repo" = A ]; then printf '83\topen\n70\tmerged\n'; fi ;;
  esac
fi
EOF
  chmod +x "$TMP/stub/gh"
  export FAIL_SEARCH="$TMP/fail-search"
}
teardown() { teardown_env; }

@test "refresh discovers multiple branch and restoration PRs per repository, deduplicated" {
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = $'A\t70\tmerged\nA\t71\tclosed\nA\t83\topen\nB\t70\topen' ]
  [[ "$(collie dash -n)" == *'#70:merged #71:closed #83:open #70:open'* ]]
}

@test "failed search preserves all previous rows only for the failed repository" {
  printf 'A\t70\tmerged\nA\t83\tdraft\nB\t99\tclosed\n' >"$(task_dir x)/pr.tsv"
  touch "$FAIL_SEARCH"
  collie _pr x
  [ "$(cat "$(task_dir x)/pr.tsv")" = $'A\t70\tmerged\nA\t83\tdraft\nB\t70\topen' ]
}
