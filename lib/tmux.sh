# shellcheck shell=bash
# Sourced by bin/collie: tmux helpers.

# --- tmux -------------------------------------------------------------------

has_session() {
  if [ -n "${SESSIONS+x}" ]; then
    case $SESSIONS in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
  fi
  tmux has-session -t "=$1" 2>/dev/null
}

# For read-only commands that look at every task: the session names (used
# by has_session) and @collie-silence (win_states, manual_runs), queried once.
load_tmux_state() {
  local s
  SESSIONS=$'\n'$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)$'\n'
  if [ -z "${COLLIE_SILENCE:-}" ]; then
    s=$(tmux_opt @collie-silence)
    COLLIE_SILENCE=${s:-30}
  fi
}

# tmux new-window/new-session, retried when the pane's pty open fails with
# ENXIO: macOS /dev/ptmx races with a pty freed concurrently (xnu tty_ptmx.c
# picks a minor past the slot vector, then skips growing it). Prints stdout.
tmux_spawn() {
  local out i
  for i in 1 2 3; do
    out=$(tmux "$@" 2>&1 </dev/null) && { printf '%s\n' "$out"; return 0; }
    case $out in *"Device not configured"*) sleep 0.2 ;; *) break ;; esac
  done
  printf '%s\n' "$out" >&2
  return 1
}

open_window() { # id name path
  local wid
  if has_session "$1"; then
    wid=$(tmux_spawn new-window -d -P -F '#{window_id}' -t "=$1:" -n "$2" -c "$3")
  else
    wid=$(tmux_spawn new-session -d -P -F '#{window_id}' -s "$1" -n "$2" -c "$3" \
      -e "COLLIE_TASK=$1" -e "COLLIE_TASK_DIR=$TASKS_DIR/$1")
  fi
  tmux set-option -w -t "$wid" @collie_path "$3" \; set-option -w -t "$wid" @collie_task "$1"
}

ensure_session() {
  local id=$1 name c b p
  has_session "$id" && return 0
  while IFS=$TAB read -r name c b p; do
    if [ -d "$p" ]; then open_window "$id" "$name" "$p"; else warn "missing worktree $p"; fi
  done <"$TASKS_DIR/$id/repos.tsv"
}

tmux_opt() { tmux show-options -gqv "$1" 2>/dev/null || true; }

# Print the last N joined lines, dropping trailing whitespace-only rows.
pane_tail() { # pane lines
  local screen
  screen=$(tmux capture-pane -p -J -t "$1" -S - 2>/dev/null) || return 1
  [ -n "$screen" ] || return 0
  printf '%s\n' "$screen" | awk -v n="$2" '
    { line[NR] = $0 }
    END {
      while (NR && line[NR] ~ /^[[:space:]]*$/) NR--
      first = NR - n + 1
      if (first < 1) first = 1
      for (i = first; i <= NR; i++) print line[i]
    }'
}

# Types text into a pane and submits it: a line as keys, several lines as one
# paste (bracketed when the program asked for it, newlines kept as LF, so they
# do not submit early). A pause before Enter, so agents that detect pastes
# still submit.
type_into() { # pane text
  if [[ $2 == *$'\n'* ]]; then
    tmux set-buffer -b "collie-$$" -- "$2" &&
      tmux paste-buffer -d -p -r -b "collie-$$" -t "$1" || return
  else
    tmux send-keys -t "$1" -l -- "$2" || return
  fi
  sleep 0.3
  tmux send-keys -t "$1" Enter
}
