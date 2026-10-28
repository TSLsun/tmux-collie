# shellcheck shell=bash
# oh-my-pi (omp) adapter. omp has no command hooks; a TS extension (omp.ts,
# loaded with -e) maps its lifecycle events to `collie state`.
# Sourced by bin/collie; reads RUN_PROMPT and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(-c)
# shellcheck disable=SC2034  # args that resume a conversation, followed by its id (adopt)
AGENT_RESUME_ID=(-r)
# Id of the conversation a running omp has open: it holds
# run/session-owners/<id>.lock while the session is live. -c alone would take
# the session its new terminal last showed, or the newest one in the cwd.
agent_session() { # pid
  lsof -p "$1" -Fn 2>/dev/null | sed -n 's|^n.*/session-owners/\(.*\)\.lock$|\1|p' | head -n 1
}
agent_argv() {
  local d
  AGENT_ARGV=(env "COLLIE_BIN=$PLUGIN_DIR/bin/collie" omp -e "$PLUGIN_DIR/agents/omp.ts")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}
