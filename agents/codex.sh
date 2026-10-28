# shellcheck shell=bash
# Codex 0.165.0+ adapter. Inline hooks are invocation scoped and still need
# review in /hooks. A dedicated process preserves this run's hook environment
# and lets adoption identify the open rollout without guessing by cwd/mtime.
# shellcheck disable=SC2034  # adapter contract, consumed by lib/cmd/agents.sh
AGENT_HOOKS=1 AGENT_HOOKS_PENDING=1 AGENT_EXTRA_HANDLED=1 AGENT_REQUIRE_SESSION=1
# shellcheck disable=SC2034
AGENT_RESUME=(resume --last)
# shellcheck disable=SC2034
AGENT_RESUME_ID=(resume)

agent_session() { # pid: exactly one open rollout; shared daemons are ambiguous
  local ids
  ids=$(lsof -a -p "$1" -Fn 2>/dev/null | sed -n 's|^n.*/rollout-.*-\([a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}\)\.jsonl$|\1|p' | sort -u) || true
  [ -n "$ids" ] && [ "$(wc -l <<<"$ids")" -eq 1 ] || return 0
  printf '%s\n' "$ids"
}

agent_argv() { # forwarded CLI arguments; resume must precede the prompt
  local d guard waiting uuid='^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
  # Resume can sit idle without SessionStart until the first new turn.
  # Preserve an explicitly known UUID immediately, even before hook trust.
  # shellcheck disable=SC2034
  if [ "${1:-}" = resume ] && [[ ${2:-} =~ $uuid ]]; then AGENT_SESSION_ID=$2; fi
  guard=$(codex_hook PreToolUse '' "$PLUGIN_DIR/hooks/tmux-guard" Bash)
  waiting=$(codex_hook PreToolUse wait '' request_user_input)
  waiting=${waiting#*=\[}
  AGENT_ARGV=(codex --no-daemon --sandbox workspace-write
    -c "${guard%]},$waiting"
    -c "$(codex_hook SessionStart _session)"
    -c "$(codex_hook UserPromptSubmit 'state working')"
    -c "$(codex_hook PostToolUse 'state working')"
    -c "$(codex_hook PermissionRequest wait)"
    -c "$(codex_hook Stop 'state idle')"
    -c "$(codex_hook Interrupt 'state idle')"
    -c "$(codex_hook SessionEnd 'state exited')")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
  [ $# -eq 0 ] || AGENT_ARGV+=("$@")
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}

codex_hook() { # event collie-args [executable] [matcher]
  local command matcher="" exe=${3:-$PLUGIN_DIR/bin/collie}
  # POSIX shell single quoting, then TOML basic-string escaping. Neither
  # config syntax nor shell metacharacters in the plugin path become code.
  exe=${exe//\'/\'\\\'\'}
  command="'$exe'"
  [ -z "$2" ] || command="$command _codex-hook $2"
  command=${command//\\/\\\\}
  command=${command//\"/\\\"}
  command=${command//$'\n'/\\n}
  command=${command//$'\r'/\\r}
  command=${command//$'\t'/\\t}
  [ -z "${4:-}" ] || matcher="matcher=\"$4\","
  printf 'hooks.%s=[{%shooks=[{type="command",command="%s"}]}]' "$1" "$matcher" "$command"
}
