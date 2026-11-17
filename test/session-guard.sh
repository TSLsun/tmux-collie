#!/usr/bin/env bash
# Run a command while detecting sessions added to the invoking tmux server.
set -u

if [ -n "${TMUX:-}" ]; then
  socket=${TMUX%%,*}
  tmux_server() { tmux -S "$socket" "$@"; }
else
  tmux_server() { tmux -L default "$@"; }
fi

sessions() {
  tmux_server list-sessions -F '#{session_id} #{session_name}' 2>/dev/null | LC_ALL=C sort
}

dir=$(mktemp -d "${TMPDIR:-/tmp}/collie-session-guard.XXXXXX") || exit 1
trap 'rm -rf "$dir"' EXIT
# An unreachable server has no existing sessions to protect.
if tmux_server list-sessions -F '#{session_id} #{session_name}' >"$dir/before.raw" 2>/dev/null; then
  LC_ALL=C sort "$dir/before.raw" >"$dir/before"
  watching=1
else
  watching=0
fi

status=0
"$@" || status=$?
if [ "$watching" -eq 1 ]; then
  sessions >"$dir/after"
  # Compare IDs rather than names: renaming an existing session is not a leak.
  awk '{print $1}' "$dir/before" >"$dir/ids"
  awk 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' "$dir/ids" "$dir/after" >"$dir/added"
  if [ -s "$dir/added" ]; then
    echo 'Error: test run added sessions to the invoking tmux server:' >&2
    cat "$dir/added" >&2
    status=1
  fi
fi
exit "$status"
