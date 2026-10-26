# shellcheck shell=bash
# oh-my-pi (omp) adapter. omp has no command hooks; a TS extension (omp.ts,
# loaded with -e) maps its lifecycle events to `collie state`.
# Sourced by bin/collie; reads RUN_PROMPT and RUN_DIRS, sets AGENT_ARGV.

# shellcheck disable=SC2034  # read by bin/collie
AGENT_HOOKS=1
# shellcheck disable=SC2034  # args that resume the latest conversation in the cwd (adopt)
AGENT_RESUME=(-c)
agent_argv() {
  local d
  AGENT_ARGV=(env "COLLIE_BIN=$PLUGIN_DIR/bin/collie" omp -e "$PLUGIN_DIR/agents/omp.ts")
  while IFS= read -r d; do
    [ -z "$d" ] || AGENT_ARGV+=(--add-dir "$d")
  done <<<"$RUN_DIRS"
  [ -z "$RUN_PROMPT" ] || AGENT_ARGV+=("$RUN_PROMPT")
}
