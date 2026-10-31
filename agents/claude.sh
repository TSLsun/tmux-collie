# shellcheck shell=bash
# Claude Code adapter. Hooks come in via --settings, so they only fire in
# sessions started by `collie run`; the user's own settings stay untouched.
# Sourced by bin/collie; reads RUN_PROMPT, RUN_NAME, RUN_DIRS, RUN_MODEL and
# RUN_EFFORT, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(--continue)
# shellcheck disable=SC2034  # args that resume a conversation, followed by its id (restore)
AGENT_RESUME_ID=(--resume)
# shellcheck disable=SC2034  # maps RUN_MODEL/RUN_EFFORT to --model/--effort
AGENT_MODELS=1

agent_argv() {
  local d settings
  # PreToolUse: hooks/tmux-guard denies killing the user's tmux server
  settings=$(printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'"'"'%s'"'"'"}]}],%s,%s,%s,%s,%s,%s}}' \
    "$PLUGIN_DIR/hooks/tmux-guard" \
    "$(claude_hook SessionStart '' _session)" \
    "$(claude_hook UserPromptSubmit '' state working)" \
    "$(claude_hook PostToolUse '*' state working)" \
    "$(claude_hook Notification 'permission_prompt|elicitation_dialog' state waiting)" \
    "$(claude_hook Stop '' state idle)" \
    "$(claude_hook SessionEnd '' state exited)")
  AGENT_ARGV=(claude)
  # the prompt goes first: --add-dir is variadic and would swallow it
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
  AGENT_ARGV+=(--name "$RUN_NAME" --settings "$settings")
  [ -z "${RUN_MODEL:-}" ] || AGENT_ARGV+=(--model "$RUN_MODEL")
  [ -z "${RUN_EFFORT:-}" ] || AGENT_ARGV+=(--effort "$RUN_EFFORT")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
}

claude_hook() { # event matcher collie-args...
  local e=$1 m=$2
  shift 2
  printf '"%s":[{%s"hooks":[{"type":"command","command":"'"'"'%s'"'"' %s"}]}]' \
    "$e" "${m:+\"matcher\":\"$m\",}" "$PLUGIN_DIR/bin/collie" "$*"
}
