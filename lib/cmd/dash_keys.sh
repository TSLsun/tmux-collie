# shellcheck shell=bash
# Sourced by bin/collie: dashboard keys, actions and menus.

# Dashboard `?` (an fzf transform): opens the action menu in the panel (see
# dash_panel) and puts the selected action in the prompt ("▸ <label> "), which
# _key reads as "menu open" and as the selection. A tmux popup cannot open over
# the dashboard's popup, hence the panel.
cmd__pick() { # [id]
  echo "change-prompt($PICK_MARK$(action_items "${1:-}" | sed -n 1p | cut -c4-) )+refresh-preview"
}

# The menu, the action labelled <label> highlighted.
pick_lines() { # id label
  local w=30 line t=${1:-collie} hl
  printf '\033[0;34m╭─ \033[1m%s\033[22m %s╮\n' "$t" "$(rule $((w - 5 - ${#t})) ─)"
  while IFS= read -r line; do
    hl=""
    [ "${line:3}" != "$2" ] || hl=$'\033[1;44m'
    printf '│\033[0m%s \033[36m%s\033[39m  %-*s\033[0;34m│\n' "$hl" "${line:0:1}" $((w - 6)) "${line:3}"
  done < <(action_items "$1")
  printf '╰─ ↑↓ enter · key · esc %s╯\033[0m\n' "$(rule $((w - 25)) ─)"
}

# fzf transform for a dashboard key, lazygit style: outside a search an action
# key (see action_items) runs its action on the selected task (see
# dash_action), j/k move, space marks, q quits, esc clears a kept filter or
# quits, ? opens the menu and / shows the input for a search (SEARCH_PROMPT).
# In a search every key types; enter keeps the filter and hides the input
# again, esc drops it (the esc bind hides the input after this transform).
# With the menu open, keys move its selection, run an action or close it; with
# a question up (ASK_MARK), y confirms and any other key cancels; a failed
# action's output takes the first key. The marked ids (fzf {+1}: the row under
# the cursor when none) go to sync; separators have an empty id. The key comes
# first: with no rows fzf drops {1} and {+1} instead of passing them empty.
cmd__key() { # key [id [marked id...]]
  set -- "${2:-}" "$1" "${@:3}"
  local back="change-prompt($DASH_PROMPT)+refresh-preview"
  local items n cur k
  dash_group
  if [ "$2" = resize ]; then
    dash_layout
    case ${FZF_PROMPT:-} in "$PICK_MARK"*) ;; *) echo "change-preview-window($PREVIEW)+change-header($(dash_header "$GROUP" "$(dash_filter)"))" ;; esac
    return
  fi
  if [ "${FZF_PROMPT:-}" != "$SEARCH_PROMPT" ] && [ -n "${COLLIE_DASH:-}" ] &&
    [ "$(head -n 1 "$COLLIE_DASH/msg" 2>/dev/null)" = fail ]; then
    rm -f "$COLLIE_DASH/msg"
    echo refresh-preview
    return
  fi
  case ${FZF_PROMPT:-} in
    "$PICK_MARK"*) ;;
    "$ASK_MARK"*)
      if [ "$2" = y ]; then
        # shellcheck disable=SC2086  # the key and ids, split
        dash_bg ${FZF_PROMPT#"$ASK_MARK"}
      else
        echo "$back"
      fi
      return
      ;;
    "$AGENT_MARK"*)
      # the agent chooser (r): a digit picks, enter the default, others cancel
      k=""
      case $2 in
        enter) k=1 ;;
        [1-9]) k=$2 ;;
      esac
      [ -z "$k" ] || k=$(run_agents | sed -n "${k}p")
      cur=${FZF_PROMPT#"$AGENT_MARK"}
      if [ -n "$k" ]; then dash_run "${cur% }" "$k"; else echo "$back"; fi
      return
      ;;
    "$SEARCH_PROMPT"*)
      case $2 in
        esc) echo "clear-query+change-prompt($DASH_PROMPT)+change-header($(dash_header "$GROUP"))" ;;
        enter) echo "hide-input+change-prompt($DASH_PROMPT)+change-header($(dash_header "$GROUP" "${FZF_QUERY:-}"))" ;;
        up | down) dash_move "$2" ;;
        space) echo "put( )" ;;
        *) echo "put($2)" ;;
      esac
      return
      ;;
    *)
      if dash_runs; then
        dash_runs_key "$@"
        return
      fi
      case $2 in
        u) if [ -n "$1" ]; then dash_runs_open "$1"; fi ;;
        esc)
          if [ -n "${FZF_QUERY:-}" ]; then
            # the esc bind hides the input again
            echo "show-input+clear-query+change-header($(dash_header "$GROUP"))"
          else
            echo abort
          fi
          ;;
        q) echo abort ;;
        enter) if [ -n "$1" ]; then echo clear-multi+accept; fi ;;
        space) if [ -n "$1" ]; then echo toggle; fi ;;
        /) echo "show-input+change-prompt($SEARCH_PROMPT)" ;;
        # fzf shows no preview, so no menu, without a row
        '?') if [ "${FZF_MATCH_COUNT:-1}" -gt 0 ]; then cmd__pick "$1"; fi ;;
        up | down) dash_move "$2" ;;
        j) dash_move down ;;
        k) dash_move up ;;
        *)
          k=$(action_items "$1" | cut -c1 | grep -xF -- "$2" || true)
          [ -z "$k" ] || dash_action "$1" "$k" "${@:3}"
          ;;
      esac
      return
      ;;
  esac
  items=$(action_items "$1")
  n=$(printf '%s\n' "$items" | wc -l)
  cur=${FZF_PROMPT#"$PICK_MARK"}
  cur=$(printf '%s\n' "$items" | awk -v l="${cur% }" 'substr($0, 4) == l { print NR; exit }')
  cur=${cur:-1}
  case $2 in j) set -- "$1" down ;; k) set -- "$1" up ;; esac
  case $2 in
    up | down)
      if [ "$2" = up ]; then cur=$(((cur + n - 2) % n + 1)); else cur=$((cur % n + 1)); fi
      echo "change-prompt($PICK_MARK$(printf '%s\n' "$items" | sed -n "${cur}p" | cut -c4-) )+refresh-preview"
      return
      ;;
    enter) k=$(printf '%s\n' "$items" | sed -n "${cur}p" | cut -c1) ;;
    esc) k="" ;;
    *) k=$(printf '%s\n' "$items" | cut -c1 | grep -xF -- "$2" || true) ;;
  esac
  if [ -n "$k" ]; then
    dash_action "$1" "$k" "${@:3}"
  else
    echo "$back"
  fi
}

# fzf actions for u: list the task's runs (see _runrows), its row kept in
# $COLLIE_DASH/runs-pos for esc to return to; marks and a kept filter go.
dash_runs_open() { # id
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" pos
  pos=$(grep -nxF -- "$1" "$STATE_DIR/dash-rows" 2>/dev/null | cut -d: -f1 | head -n 1) || pos=""
  printf '%s\n' "$1" >"$COLLIE_DASH/runs"
  printf '%s\n' "${pos:-1}" >"$COLLIE_DASH/runs-pos"
  echo "clear-multi+show-input+clear-query+hide-input+change-header($(dash_header ""))+reload-sync($self _runrows)+first+refresh-preview"
}

# A key in the runs view (RUNS_OF set; see cmd__key for the arguments): j/k
# and arrows move, / searches, q quits, esc clears a kept filter or goes back to
# the tasks, enter goes to a run's window (the run's state in the panel when it
# has none), h hands the run off to the other agent (see _handoff).
dash_runs_key() { # id key
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" w pos
  case $2 in
    esc)
      if [ -n "${FZF_QUERY:-}" ]; then
        echo "show-input+clear-query+change-header($(dash_header ""))"
        return
      fi
      read -r pos <"$COLLIE_DASH/runs-pos" 2>/dev/null || pos=1
      rm -f "$COLLIE_DASH/runs" "$COLLIE_DASH/runs-pos"
      dash_group
      echo "change-header($(dash_header "$GROUP"))+reload-sync($self _rows)+pos($pos)+refresh-preview"
      ;;
    q) echo abort ;;
    /) echo "show-input+change-prompt($SEARCH_PROMPT)" ;;
    up | down) echo "$2" ;;
    j) echo down ;;
    k) echo up ;;
    enter)
      [ -n "$1" ] || return 0
      case $1 in
        @*) w=$1 ;;
        *) w=$(run_history "$RUNS_OF" | awk -F'\t' -v r="$1" '$1 == r { print $5 "\t" $4; exit }') ;;
      esac
      if [ "${w%%"$TAB"*}" = - ]; then
        panel_msg fail "run $1 has no window (${w#*"$TAB"})"
        echo refresh-preview
      else
        printf '%s\t%s\n' "$RUNS_OF" "${w%%"$TAB"*}" >"$COLLIE_DASH/go"
        echo accept
      fi
      ;;
    h) if [ -n "$1" ]; then echo "change-prompt($DASH_PROMPT)+clear-screen+execute($self _handoff '$RUNS_OF' '$1')+reload-sync($self _runrows)+first+refresh-preview"; fi ;;
  esac
}

# Dashboard h on a run: hands a claude run off to codex or the reverse (see
# cmd_handoff) with a note written in $EDITOR; an empty note cancels. Says
# when the source stays live, and why a run cannot be handed off.
cmd__handoff() { # id run
  local id=$1 run=$2 info agent repo st to note rc=0
  [ ! -t 1 ] || printf '\033[H\033[2J'
  info=$(run_history "$id" | awk -F'\t' -v r="$run" '$1 == r { print $2 "\t" $3 "\t" $4; exit }')
  IFS=$TAB read -r agent repo st <<<"$info"
  case $agent in
    claude) to=codex ;;
    codex) to=claude ;;
    *)
      if [ "${run#@}" != "$run" ]; then
        echo "an agent started by hand has no run to hand off: adopt it first (a)"
      else
        echo "run $run (${agent:-unknown}) cannot be handed off: only claude and codex runs"
      fi
      printf '\n[press any key]'
      read -rsn1 _ || true
      return 0
      ;;
  esac
  printf 'handoff %s run %s (%s, %s, %s) to %s\n' "$id" "$run" "$agent" "$repo" "$st" "$to"
  case $st in working | waiting | idle) printf 'run %s stays live: both runs share the worktree\n' "$run" ;; esac
  printf '\nWrite the handoff note (an empty note cancels). Press any key.'
  read -rsn1 _ || true
  note=$(mktemp "${TMPDIR:-/tmp}/collie-note.XXXXXX")
  sh -c "${EDITOR:-vi} \"\$1\"" "${EDITOR:-vi}" "$note" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '[^[:space:]]' "$note"; then
    cmd__popup "'$BASH' '$PLUGIN_DIR/bin/collie' handoff '$id' --from '$run' --agent '$to' --note '$note' >/dev/null" || true
  fi
  rm -f "$note"
}

# fzf actions for a dashboard action (see action_items) on a task and the
# marked ids (sync only). Edit, terminal and new task take the screen (see
# _actions); review switches the panel to `collie review` and back; run starts
# in the background (r first asks for the agent in the panel, R takes the
# default); done, archive, adopt and sync ask y/n in the panel first
# (the prompt holds "<ASK_MARK><key> <id...> "), then run in the background.
dash_action() { # id key [marked id...]
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" id=$1 k=$2 m ids=""
  shift 2
  case $k in
    e | t | c) echo "change-prompt($DASH_PROMPT)+clear-screen+execute($self _actions '$id' '$k')+reload($self _rows)+refresh-preview" ;;
    v)
      if [ "${FZF_PREVIEW_LABEL:-}" = "$REVIEW_LABEL" ]; then
        echo "change-prompt($DASH_PROMPT)+change-preview-label()+refresh-preview"
      else
        echo "change-prompt($DASH_PROMPT)+change-preview-label($REVIEW_LABEL)+refresh-preview"
      fi
      ;;
    r) echo "change-prompt($AGENT_MARK$id )+refresh-preview" ;;
    R) dash_run "$id" ;;
    s)
      for m in "$@"; do [ -z "$m" ] || ids="$ids $m"; done
      echo "change-prompt($ASK_MARK$k${ids:- $id} )+refresh-preview"
      ;;
    *) echo "change-prompt($ASK_MARK$k $id )+refresh-preview" ;;
  esac
}

# fzf actions for run (R, or r and an agent): in the background, but a
# blocked todo task asks first (see cmd_run; the prompt keeps the agent).
dash_run() { # id [agent]
  if [ -n "$1" ] && task_status "$1" "" && [ "$STATUS" = todo ] &&
    task_blocked "$TASKS_DIR/$1" && [ -n "$BLOCKED" ]; then
    echo "change-prompt(${ASK_MARK}r $1 ${2:+$2 })+refresh-preview"
  else
    dash_bg r "$1" ${2:+"$2"}
  fi
}

# What an action key does, for the panel: run, adopt, done, archive, sync.
action_verb() { # key
  case $1 in r) echo run ;; a) echo adopt ;; d) echo "done" ;; x) echo archive ;; s) echo sync ;; esac
}

# fzf actions that start _bg for an action, with a "running" line in the panel.
dash_bg() { # key id...
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" k=$1
  shift
  [ -z "${COLLIE_DASH:-}" ] || panel_msg run "… $(action_verb "$k") $*"
  echo "change-prompt($DASH_PROMPT)+refresh-preview+bg-transform($self _bg $k $*)"
}

# Writes the panel's message: kind (run, ok, fail) on the first line.
panel_msg() { # kind text
  [ -d "${COLLIE_DASH:-}" ] || return 0
  printf '%s\n%s\n' "$1" "$2" >"$COLLIE_DASH/msg.$$" && mv "$COLLIE_DASH/msg.$$" "$COLLIE_DASH/msg"
}

# A dashboard action in the background (an fzf bg-transform), immune to the
# popup closing; then the rows reload and the panel reports: one green line
# that fades (see _fade), or the output in red until a key.
cmd__bg() { # key id... (r: id [agent])
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" k=$1 a out rc=0 rows=_rows
  shift
  # the user may have opened a task's runs (u) meanwhile
  ! dash_runs || rows=_runrows
  case $k in
    r) a=(run "$1" ${2:+--agent "$2"}) ;;
    a) a=(adopt "$1" -y) ;;
    d) a=("done" "$1") ;;
    x) a=(archive "$1") ;;
    s) a=(sync "$@") ;;
    *) return 0 ;;
  esac
  out="${COLLIE_DASH:-${TMPDIR:-/tmp}}/out.$$"
  # its own file: the popup may close (and this shell die) before it ends
  (
    trap '' HUP PIPE
    exec "$BASH" "$PLUGIN_DIR/bin/collie" "${a[@]}"
  ) </dev/null >"$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    panel_msg ok "✓ $(action_verb "$k") $*"
    echo "reload($self $rows)+refresh-preview+bg-transform($self _fade)"
  else
    panel_msg fail "✗ $(action_verb "$k") $* (exit $rc)"$'\n'"$(cat "$out")"
    echo "reload($self $rows)+refresh-preview"
  fi
  rm -f "$out"
}

# Clears a success line from the panel after a moment (an fzf bg-transform).
cmd__fade() {
  sleep 2
  [ "$(head -n 1 "${COLLIE_DASH:-}/msg" 2>/dev/null)" = ok ] || return 0
  rm -f "$COLLIE_DASH/msg"
  echo refresh-preview
}

# up / down on the dashboard, over a group separator when it lands on one
# (fzf has no unselectable rows; up moves to the next row in default layout).
dash_move() { # up|down
  local to=$((${FZF_POS:-0} + 1)) l=""
  [ "$1" = up ] || to=$((${FZF_POS:-0} - 1))
  if [ -z "${FZF_QUERY:-}" ] && [ "$to" -ge 1 ] && [ -f "$STATE_DIR/dash-rows" ]; then
    l=$(sed -n "${to}p" "$STATE_DIR/dash-rows")
    if [ -z "$l" ]; then
      # the topmost separator has nothing past it: stay
      [ "$to" -ge $(($(wc -l <"$STATE_DIR/dash-rows"))) ] || echo "$1+$1"
      return
    fi
  fi
  echo "$1"
}

# "<key>  <label>" lines of the dashboard actions for a task (or none).
action_items() { # [id]
  [ -z "$1" ] || printf '%s\n' 'r  run agent' 'R  run default agent' 'a  adopt agent' 'e  edit task' 'v  review' 't  terminal' 'd  done' 'x  archive' 's  sync'
  printf '%s\n' 'c  new task'
}

# Runs a dashboard action that takes the screen (see dash_action): edit,
# terminal, new task.
cmd__actions() { # id key
  local id=${1:-} k=${2:-} self="'$BASH' '$PLUGIN_DIR/bin/collie'" a
  [ ! -t 1 ] || printf '\033[H\033[2J'
  case ${id:+x}$k in
    xe) a="$self edit '$id'" ;;
    xt)
      # a shell in the task's first worktree; its exit status is not a failure
      a=$(awk -F'\t' 'NR == 1 { print $4 }' "$TASKS_DIR/$id/repos.tsv" 2>/dev/null)
      [ -d "$a" ] || a="$TASKS_DIR/$id"
      (cd "$a" && "${SHELL:-sh}") || true
      return 0
      ;;
    c | xc) a="$self new" ;;
    *) return 0 ;;
  esac
  cmd__popup "$a"
}

# Menu for prefix <@collie-key>, built per session: task actions only inside a
# task's session (see collie.tmux).
cmd__menu() { # session [client]
  local C="$PLUGIN_DIR/bin/collie" T=$1 popup="display-popup -E -w 90% -h 85%" items k l a
  items=(dashboard h "$popup '$C _popup $C dash'"
    brief b "$popup '$C _popup \"$C brief | less -R\"'"
    lazygit g "$popup -d '#{pane_current_path}' '$C _popup lazygit'"
    terminal t "$popup -d '#{pane_current_path}'"
    "new task" c "display-popup -EE -w 80% -h 70% -d '#{pane_current_path}' '$C new'")
  if valid_id "$T" && [ -f "$TASKS_DIR/$T/TASK.md" ]; then
    # the dashboard's task actions (action_items), same keys and labels;
    # terminal and new task are the global items above
    items+=("" "peek task" p "display-popup -E -w 90% -h 85% '$C _popup -w $C peek $T'")
    while read -r k l; do
      case $k in
        r) a="run-shell '$C _runpick $T${2:+ $2}'" ;;
        R) a="run-shell '$C run $T -s${2:+ -c $2}'" ;;
        a) a="display-popup -E -w 90 -h 12 '$C _popup $C adopt $T'" ;;
        e) a="$popup '$C _popup $C edit $T'" ;;
        v) a="$popup '$C _popup \"$C review $T | less -R\"'" ;;
        d | x) a="confirm-before -p '$l $T? (y/n)' \"display-popup -E -w 90 -h 12 '$C _popup $C $l $T'\"" ;;
        s) a="confirm-before -p 'sync $T? (y/n)' \"display-popup -E -w 90 -h 20 '$C _popup -w $C sync $T'\"" ;;
        *) continue ;;
      esac
      items+=("$l" "$k" "$a")
    done < <(action_items "$T")
  else
    items+=("" "-not a collie task — use collie new" "" "")
  fi
  items+=("" "jump to alert" j "run-shell '$C _jump - ${2:-}'"
    "gc merged tasks" G "display-popup -E -w 90 -h 20 '$C _popup $C _gc'")
  if [ "${COLLIE_DEV:-$(tmux_opt @collie-dev)}" = on ]; then
    items+=("" "dev: load this checkout" D "run-shell '$C _dev load #{q:pane_current_path}'"
      "dev: back to installed" B "run-shell '$C _dev reset'")
  fi
  tmux display-menu ${2:+-c "$2"} -T '#[align=centre] collie ' -x C -y C "${items[@]}"
}

# The prefix menu's run agent (r): a menu of run_agents, the default first,
# keyed 1, 2, ...; each runs the task like run default agent (R).
cmd__runpick() { # id [client]
  local C="$PLUGIN_DIR/bin/collie" items=() a i=0 l
  valid_id "${1:-}" || die "usage: collie _runpick <id> [client]"
  while read -r a; do
    i=$((i + 1)) l=$a
    [ "$i" -gt 1 ] || l="$a (default)"
    items+=("$l" "$i" "run-shell '$C run $1 -s${2:+ -c $2} --agent $a'")
  done < <(run_agents)
  tmux display-menu ${2:+-c "$2"} -T '#[align=centre] run agent ' -x C -y C "${items[@]}"
}

# @collie-dev: reload the plugin from another tmux-collie checkout (load <dir>)
# or from the one tpm installed (reset).
cmd__dev() {
  local root
  case ${1:-} in
    load)
      root=$(git -C "${2:-.}" rev-parse --show-toplevel 2>/dev/null) || root=
      if [ -z "$root" ] || [ ! -f "$root/collie.tmux" ]; then
        die "dev: ${2:-.} is not a tmux-collie checkout"
      fi
      ;;
    reset)
      root=$(tmux_opt @collie-home)
      [ -n "$root" ] || die "dev: @collie-home unset"
      ;;
    *) die "usage: collie _dev load <dir> | reset" ;;
  esac
  tmux run-shell "'$root/collie.tmux'"
  tmux display-message "collie: loaded $root @ $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
}

# Run a command line in a popup; on failure keep the popup open until a key.
cmd__popup() { # [-w] command...
  local rc=0 w=""
  [ "${1:-}" != -w ] || { w=1 && shift; }
  (eval "$*") || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -n "$w" ] || return 0
    printf '\n[press any key]'
    read -rsn1 _ || true
    return 0
  fi
  printf '\n[collie: exit %s — press any key]' "$rc"
  read -rsn1 _ || true
  return "$rc"
}

