# shellcheck shell=bash
# Claude Code adapter. Hooks come in via --settings, so they only fire in
# sessions started by `collie run`; the user's own settings stay untouched.
# Sourced by bin/collie; reads RUN_PROMPT, RUN_NAME and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(--continue)

agent_argv() {
  local d settings
  settings=$(printf '{"hooks":{%s,%s,%s,%s,%s}}' \
    "$(claude_hook UserPromptSubmit '' working)" \
    "$(claude_hook PostToolUse '*' working)" \
    "$(claude_hook Notification 'permission_prompt|elicitation_dialog' waiting)" \
    "$(claude_hook Stop '' idle)" \
    "$(claude_hook SessionEnd '' exited)")
  AGENT_ARGV=(claude)
  # the prompt goes first: --add-dir is variadic and would swallow it
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
  AGENT_ARGV+=(--name "$RUN_NAME" --settings "$settings")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
}

claude_hook() { # event matcher state
  printf '"%s":[{%s"hooks":[{"type":"command","command":"'"'"'%s'"'"' state %s"}]}]' \
    "$1" "${2:+\"matcher\":\"$2\",}" "$PLUGIN_DIR/bin/collie" "$3"
}
