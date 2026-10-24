# shellcheck shell=bash
# Codex CLI adapter. Hooks come in as -c config overrides, so they only apply
# to sessions started by `collie run`. Codex runs non-managed hooks only after
# they are trusted once in /hooks (trust is keyed to the hook's hash).
# Sourced by bin/collie; reads RUN_PROMPT and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1

agent_argv() {
  local d
  AGENT_ARGV=(codex
    -c "$(codex_hook UserPromptSubmit working)"
    -c "$(codex_hook PostToolUse working)"
    -c "$(codex_hook PermissionRequest waiting)"
    -c "$(codex_hook Stop idle)"
    -c "$(codex_hook SessionEnd exited)")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}

codex_hook() { # event state
  printf 'hooks.%s=[{hooks=[{type="command",command="'"'"'%s'"'"' state %s"}]}]' \
    "$1" "$PLUGIN_DIR/bin/collie" "$2"
}
