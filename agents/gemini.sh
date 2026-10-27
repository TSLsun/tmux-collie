# shellcheck shell=bash
# Gemini CLI adapter. Hooks live in a generated settings file passed as the
# system settings layer (GEMINI_CLI_SYSTEM_SETTINGS_PATH), which hides
# /etc/gemini-cli/settings.json for these sessions. Gemini strips the hook
# environment, so `collie state` finds its pane through parent processes, and
# hook stdout must be JSON.
# Sourced by bin/collie; reads RUN_PROMPT and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1

agent_argv() {
  local f="$STATE_DIR/gemini-settings.json" d
  mkdir -p "$STATE_DIR"
  {
    echo '{"hooks":{'
    # hooks/tmux-guard denies killing the user's tmux server (exit 2)
    printf '"BeforeTool":[{"matcher":"run_shell_command","hooks":[{"name":"collie-tmux-guard","type":"command","command":"'"'"'%s'"'"' && echo {}"}]}],\n' \
      "$PLUGIN_DIR/hooks/tmux-guard"
    gemini_hook BeforeAgent '' working ,
    gemini_hook AfterTool '' working ,
    gemini_hook Notification ToolPermission waiting ,
    gemini_hook AfterAgent '' idle ,
    gemini_hook SessionEnd '' exited ''
    echo '}}'
  } >"$f"
  AGENT_ARGV=(env "GEMINI_CLI_SYSTEM_SETTINGS_PATH=$f" gemini)
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--include-directories "$d")
  done <<<"$RUN_DIRS"
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}

gemini_hook() { # event matcher state separator
  printf '"%s":[{%s"hooks":[{"name":"collie","type":"command","command":"'"'"'%s'"'"' state %s; echo {}"}]}]%s\n' \
    "$1" "${2:+\"matcher\":\"$2\",}" "$PLUGIN_DIR/bin/collie" "$3" "$4"
}
