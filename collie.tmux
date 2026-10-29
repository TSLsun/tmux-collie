#!/usr/bin/env bash
# tpm entry point: expose bin/ to every pane started by this tmux server.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$CURRENT_DIR/bin"

# bin/ of the copy loaded before this one (another checkout under `collie _dev`)
prev=$(tmux show-options -gqv @collie-bin)
tmux show-options -gqv @collie-home | grep -q . || tmux set-option -g @collie-home "$CURRENT_DIR"
tmux set-option -g @collie-bin "$BIN"

path=$(tmux show-environment -g PATH 2>/dev/null)
path=${path#PATH=}
case "$path" in "" | -PATH) path=$PATH ;; esac

# PATH gets exactly one collie bin/, this one, in front.
new=$BIN
IFS=: read -ra dirs <<<"$path"
for d in "${dirs[@]}"; do
  [ "$d" = "$BIN" ] || [ "$d" = "$prev" ] || new="$new:$d"
done
[ "$new" = "$path" ] || tmux set-environment -g PATH "$new"

# #{collie_status} in status-left/right (or a previous copy's command) becomes
# the agent counts.
pat='#{collie_status}'
old="#(\"$prev/collie\" status)"
cmd="#(\"$BIN/collie\" status)"
for side in status-left status-right; do
  v=$(tmux show-options -gqv "$side")
  case $v in
    *"$pat"*) tmux set-option -g "$side" "${v//"$pat"/$cmd}" ;;
    *"$old"*) [ -z "$prev" ] || tmux set-option -g "$side" "${v//"$old"/$cmd}" ;;
  esac
done

# With the mouse on, clicking a count of collie status lists its agents
# (bin/collie _status-menu) at the click: #{mouse_x} is passed on, since a
# menu from run-shell has no mouse event for -x M. A MouseUp1Status binding of
# the user's is kept.
cur=$(tmux list-keys -T root MouseUp1Status 2>/dev/null)
case $cur in "" | *_status-menu*)
  tmux bind-key -n MouseUp1Status if-shell -F '#{m:collie-*,#{mouse_status_range}}' \
    "run-shell \"'$BIN/collie' _status-menu #{q:mouse_status_range} #{q:client_name} #{mouse_x}\""
  ;;
esac

# @collie-restore on: restart the agents lost with the previous server
# (bin/collie restore; restored runs are logged, so a reload starts nothing).
[ "$(tmux show-options -gqv @collie-restore)" != on ] || tmux run-shell -b "'$BIN/collie' restore >/dev/null 2>&1"

# prefix <@collie-key> (default h) opens the collie menu (bin/collie _menu);
# prefix h h = dashboard.
key=$(tmux show-options -gqv @collie-key)
tmux bind-key "${key:-h}" run-shell "'$BIN/collie' _menu #{q:session_name} #{q:client_name}"
