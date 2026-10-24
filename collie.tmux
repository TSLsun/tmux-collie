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

# prefix <@collie-key> (default h) opens the collie menu; prefix h h = dashboard.
# Actions target the current session's task.
key=$(tmux show-options -gqv @collie-key)
C="$BIN/collie"
T='#{session_name}'
popup="display-popup -E -w 90% -h 85%"
prompt="display-popup -E -w 70 -h 3"
status_menu="display-menu -T status"
for s in active blocked review todo; do
  status_menu="$status_menu $s ${s:0:1} \"run-shell '$C set $T status=$s'\""
done
tmux bind-key "${key:-h}" display-menu -T '#[align=centre] collie ' -x C -y C \
  dashboard h "$popup '$C dash'" \
  lazygit g "$popup -d '#{pane_current_path}' lazygit" \
  notes n "$popup '$C notes $T'" \
  "next action" N "$prompt '$C set $T next'" \
  status s "$status_menu" \
  review v "$popup '$C review $T | less -R'" \
  "" \
  "run agent" r "run-shell '$C run $T'" \
  "done" d "confirm-before -p 'done $T? (y/n)' \"run-shell '$C done $T'\""
