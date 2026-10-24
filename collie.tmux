#!/usr/bin/env bash
# tpm entry point: expose bin/ to every pane started by this tmux server.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$CURRENT_DIR/bin"

path=$(tmux show-environment -g PATH 2>/dev/null)
path=${path#PATH=}
case "$path" in "" | -PATH) path=$PATH ;; esac

case ":$path:" in
  *":$BIN:"*) ;;
  *) tmux set-environment -g PATH "$BIN:$path" ;;
esac

# #{collie_status} in status-left/right becomes the agent counts.
pat='#{collie_status}'
cmd="#(\"$BIN/collie\" status)"
for side in status-left status-right; do
  v=$(tmux show-options -gqv "$side")
  case $v in
    *"$pat"*) tmux set-option -g "$side" "${v//"$pat"/$cmd}" ;;
  esac
done
