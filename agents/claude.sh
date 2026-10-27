# shellcheck shell=bash
# Claude Code adapter. Hooks come in via --settings, so they only fire in
# sessions started by `collie run`; the user's own settings stay untouched.
# Sourced by bin/collie; reads RUN_PROMPT, RUN_NAME and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(--continue)
# shellcheck disable=SC2034  # args that resume a conversation, followed by its id (restore)
AGENT_RESUME_ID=(--resume)

agent_argv() {
  local d settings
  settings=$(printf '{"hooks":{%s,%s,%s,%s,%s,%s}}' \
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
