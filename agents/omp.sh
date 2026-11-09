# shellcheck shell=bash
# oh-my-pi (omp) adapter. omp has no command hooks; a TS extension (omp.ts,
# loaded with -e) maps its lifecycle events to `collie state`.
# Sourced by bin/collie; reads RUN_PROMPT and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(-c)
# shellcheck disable=SC2034  # args that resume a conversation, followed by its id
AGENT_RESUME_ID=(-r)
# shellcheck disable=SC2034  # RUN_MODEL -> --model, RUN_EFFORT -> --thinking
AGENT_MODELS=1
# `session_start` in the extension logs the active id for restore. `-c` is
# retained as a fallback for runs where omp does not expose an id.
agent_session() { # pid
  lsof -p "$1" -Fn 2>/dev/null | sed -n 's|^n.*/session-owners/\(.*\)\.lock$|\1|p' | head -n 1
}
agent_argv() {
  local d
  AGENT_ARGV=(env "COLLIE_BIN=$PLUGIN_DIR/bin/collie" omp -e "$PLUGIN_DIR/agents/omp.ts")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
  [ -z "${RUN_MODEL:-}" ] || AGENT_ARGV+=(--model "$RUN_MODEL")
  [ -z "${RUN_EFFORT:-}" ] || AGENT_ARGV+=(--thinking "$RUN_EFFORT")
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}
