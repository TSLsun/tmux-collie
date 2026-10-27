# shellcheck shell=bash
# Sourced by bin/collie: dashboard, menu and popups.

# Active tasks in `ls` format, most urgent first (see DESIGN §3.3: needs you,
# then active, then todo), then by priority and id.
dash_rows() {
  cmd_ls | awk -F'\t' '{
      r = 6
      if ($5 == "waiting") r = 1
      else if ($5 == "idle") r = 2
      else if ($2 == "review") r = 3
      else if ($5 == "working") r = 4
      else if ($2 == "active") r = 5
      print r "\t" $0
    }' | sort -t "$TAB" -k1,1n -k4,4 -k2,2 | cut -f2-
}

DASH_GROUPS=(status priority repo)

# The dashboard's grouping (DASH_GROUPS), kept across dashboards. Sets GROUP.
dash_group() {
  GROUP=""
  [ ! -f "$STATE_DIR/dash-group" ] || read -r GROUP <"$STATE_DIR/dash-group" || true
  case " ${DASH_GROUPS[*]} " in *" $GROUP "*) ;; *) GROUP=status ;; esac
}

dash_header() { # group
  printf 'enter: go   ?: actions   tab: group by %s' "$1"
}

# dash_rows for fzf, in groups (DASH_GROUPS; status: needs you, active, todo;
# priority: P0..P3; repo: most urgent first), each topped by a dim
# "── <group> (<n>) ──" line (fzf lists bottom-up, so it follows its rows).
# A row is the id, then aligned columns: a status glyph (red ● needs you,
# yellow ◐ working, dim ○ none) and id, status, colored priority, a badge per
# live agent, the last event's age, repos. The first line holds the column
# names (fzf --header-lines=1); separators and it have an empty id.
# $STATE_DIR/dash-rows gets the ids in order (empty for separators), for _key.
# shellcheck disable=SC2120  # group comes from the CLI; internal callers pass none
cmd__rows() { # [group]
  local g=${1:-}
  if [ -z "$g" ]; then
    dash_group
    g=$GROUP
  fi
  mkdir -p "$STATE_DIR"
  LS_AGENTS=1 dash_rows | awk -F'\t' -v g="$g" -v cache="$STATE_DIR/dash-rows" '
    # ISO 8601 UTC time to epoch seconds (days from civil)
    function epoch(t, y, m) {
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0
      if (m <= 2) { y--; m += 12 }
      return ((365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + substr(t, 9, 2) - 719469) * 86400 \
        + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2))
    }
    function age(s) {
      if (s < 60) return "now"
      if (s < 3600) return int(s / 60) "m"
      if (s < 86400) return int(s / 3600) "h"
      if (s < 604800) return int(s / 86400) "d"
      return int(s / 604800) "w"
    }
    function pad(s, w, l) { return s sprintf("%" (w - l > 0 ? w - l : 0) "s", "") }
    function max(a, b) { return a > b ? a : b }
    BEGIN {
      c["claude"] = "38;5;208"; c["codex"] = "32"; c["gemini"] = "34"; c["omp"] = "35"; c["aider"] = "36"
      pc["P0"] = "1;31"; pc["P1"] = "33"; pc["P3"] = "2"
      e = "\033["
      srand(); now = srand()
      wi = 4; ws = 6; wp = 3; wa = 5; wg = 3; wr = 5
    }
    {
      n++; id[n] = $1; st[n] = $2; pr[n] = $3; rp[n] = $6
      gl[n] = e "2m○"
      if ($5 == "waiting" || $5 == "idle") gl[n] = e "31m●"
      else if ($5 == "working") gl[n] = e "33m◐"
      k = split($7, a, " "); b = ""
      for (i = 1; i <= k; i++) b = b (i > 1 ? " " : "") e "1;" (a[i] in c ? c[a[i]] : "37") "m" a[i] e "0m"
      al[n] = k ? length($7) - 1 : 1
      ag[n] = b == "" ? e "2m-" e "0m" : b
      ad[n] = $8 == "" ? "-" : age(now - epoch($8))
      if (g == "priority") k = $3
      else if (g == "repo") k = $6
      else if ($5 == "waiting" || $5 == "idle" || $2 == "review") k = "needs you"
      else k = $2
      if (!(k in cnt)) seen[++ns] = k
      cnt[k]++; key[n] = k
      wi = max(wi, length($1)); ws = max(ws, length($2)); wp = max(wp, length($3))
      wa = max(wa, al[n]); wg = max(wg, length(ad[n])); wr = max(wr, length($6))
    }
    END {
      if (!n) exit
      if (g == "priority") for (i = 0; i <= 3; i++) if (("P" i) in cnt) { ord[++no] = "P" i; done["P" i] = 1 }
      for (i = 1; i <= ns; i++) if (!(seen[i] in done)) ord[++no] = seen[i]
      w = 2 + wi + 2 + ws + 2 + wp + 2 + wa + 2 + wg + 2 + wr
      print "\t" e "2m  " pad("TASK", wi, 4) "  " pad("STATUS", ws, 6) "  " pad("PRI", wp, 3) "  " \
        pad("AGENT", wa, 5) "  " sprintf("%" wg "s", "AGE") "  REPOS" e "0m"
      printf "" >cache
      for (j = 1; j <= no; j++) {
        for (i = 1; i <= n; i++) {
          if (key[i] != ord[j]) continue
          p = pr[i] in pc ? e pc[pr[i]] "m" pr[i] e "0m" : pr[i]
          print id[i] "\t" gl[i] e "0m " pad(id[i], wi, length(id[i])) "  " pad(st[i], ws, length(st[i])) "  " \
            pad(p, wp, length(pr[i])) "  " pad(ag[i], wa, al[i]) "  " e "2m" sprintf("%" wg "s", ad[i]) e "0m  " rp[i]
          print id[i] >cache
        }
        l = "── " ord[j] " (" cnt[ord[j]] ") "
        for (r = w - length(ord[j] cnt[ord[j]]) - 7; r > 0; r--) l = l "─"
        print "\t" e "2m" l e "0m"
        print "" >cache
      }
    }'
}

# fzf transform for tab / btab (next / prev): switch the dashboard grouping.
cmd__group() { # next|prev
  case ${FZF_PROMPT:-} in "$PICK_MARK"*) return 0 ;; esac
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" n=${#DASH_GROUPS[@]} i
  dash_group
  for i in "${!DASH_GROUPS[@]}"; do [ "${DASH_GROUPS[$i]}" != "$GROUP" ] || break; done
  if [ "${1:-}" = prev ]; then i=$(((i + n - 1) % n)); else i=$(((i + 1) % n)); fi
  mkdir -p "$STATE_DIR"
  printf '%s\n' "${DASH_GROUPS[$i]}" >"$STATE_DIR/dash-group"
  echo "change-header($(dash_header "${DASH_GROUPS[$i]}"))+reload($self _rows)"
}

cmd_dash() {
  if [ "${1:-}" = -n ]; then
    dash_rows
    return
  fi
  command -v fzf >/dev/null || die "dash: fzf required"
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" rows header sel id wid k binds=()
  rows=$(cmd__rows)
  for k in $(action_items x | cut -c1) esc enter up down; do binds+=(--bind="$k:transform($self _key {1} $k)"); done
  dash_group
  header=$(dash_header "$GROUP")
  [ -n "$rows" ] || header='no tasks — ?: new task'
  sel=$(printf '%s' "$rows" | fzf --ansi --delimiter='\t' --with-nth=2.. --no-sort --prompt="$DASH_PROMPT" \
    --header="$header" --header-lines=1 \
    --preview="$self _preview {1}" --preview-window=right,50% \
    --bind="?:transform($self _pick {1})" "${binds[@]}" \
    --bind="tab:transform($self _group next)" --bind="btab:transform($self _group prev)") || return 0
  id=${sel%%"$TAB"*}
  [ -n "$id" ] || return 0
  wid=$(cmd__target "$id")
  if [ "$wid" != - ]; then tmux select-window -t "$wid" 2>/dev/null || true; fi
  cmd_go "$id"
}

# Dashboard `?` (an fzf transform): draws the action menu over the dashboard
# and puts the selected action in the prompt ("▸ <label> "), which _key reads
# as "menu open" and as the selection. fzf keeps reading keys meanwhile, so
# keys go through fzf binds, not a read here. A tmux popup cannot open over
# the dashboard's popup, hence the drawing.
cmd__pick() { # [id]
  pick_draw "${1:-}" 1 || return 0
  echo "change-prompt($PICK_MARK$(action_items "${1:-}" | sed -n 1p | cut -c4-) )"
}

# Draws the menu with row <sel> highlighted on /dev/tty, just above the
# selected dashboard row (fzf's default layout: prompt, info, header and the
# column names take the last 4 lines, list row 1 sits above them).
pick_draw() { # id sel
  local items n w=30 top left=2 line i=0 t=${1:-collie} hl
  items=$(action_items "$1")
  n=$(printf '%s\n' "$items" | wc -l)
  top=$((${FZF_LINES:-24} - ${FZF_POS:-1} - n - 5))
  [ "$top" -ge 1 ] || top=1
  {
    printf '\033[%d;%dH\033[0;34m╭─ \033[1m%s\033[22m %s╮' "$top" "$left" "$t" "$(rule $((w - 5 - ${#t})) ─)"
    while IFS= read -r line; do
      i=$((i + 1)) top=$((top + 1)) hl=""
      [ "$i" -ne "$2" ] || hl=$'\033[1;44m'
      printf '\033[%d;%dH│\033[0m%s \033[36m%s\033[39m  %-*s\033[0;34m│' \
        "$top" "$left" "$hl" "${line:0:1}" $((w - 6)) "${line:3}"
    done <<<"$items"
    printf '\033[%d;%dH╰─ ↑↓ enter · key · esc %s╯\033[0m' $((top + 1)) "$left" "$(rule $((w - 25)) ─)"
  } >/dev/tty 2>/dev/null
}

# fzf transform for a menu key (an action key, up, down, esc or enter): with
# the menu open, move the selection, run an action or close; otherwise the
# key's usual job.
cmd__key() { # id key
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" back="change-prompt($DASH_PROMPT)+clear-screen"
  local items n cur k
  case ${FZF_PROMPT:-} in
    "$PICK_MARK"*) ;;
    *)
      case $2 in
        esc) echo abort ;;
        enter) if [ -n "$1" ]; then echo accept; fi ;;
        up | down) dash_move "$2" ;;
        *) echo "put($2)" ;;
      esac
      return
      ;;
  esac
  items=$(action_items "$1")
  n=$(printf '%s\n' "$items" | wc -l)
  cur=${FZF_PROMPT#"$PICK_MARK"}
  cur=$(printf '%s\n' "$items" | awk -v l="${cur% }" 'substr($0, 4) == l { print NR; exit }')
  cur=${cur:-1}
  case $2 in
    up | down)
      if [ "$2" = up ]; then cur=$(((cur + n - 2) % n + 1)); else cur=$((cur % n + 1)); fi
      pick_draw "$1" "$cur" || true
      echo "change-prompt($PICK_MARK$(printf '%s\n' "$items" | sed -n "${cur}p" | cut -c4-) )"
      return
      ;;
    enter) k=$(printf '%s\n' "$items" | sed -n "${cur}p" | cut -c1) ;;
    esc) k="" ;;
    *) k=$(printf '%s\n' "$items" | cut -c1 | grep -xF -- "$2" || true) ;;
  esac
  if [ -n "$k" ]; then
    echo "$back+execute($self _actions '$1' '$k')+reload($self _rows)+refresh-preview"
  else
    echo "$back"
  fi
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

rule() { local s="" i; for ((i = 0; i < $1; i++)); do s="$s$2"; done; printf '%s' "$s"; }

# "<key>  <label>" lines of the dashboard actions for a task (or none).
action_items() { # [id]
  [ -z "$1" ] || printf '%s\n' 'r  run agent' 'a  adopt agent' 'e  edit task' 'v  review' 't  terminal' 'd  done'
  printf '%s\n' 'c  new task'
}

# Runs the dashboard action for a key (see action_items); done asks first.
cmd__actions() { # id key
  local id=${1:-} k=${2:-} self="'$BASH' '$PLUGIN_DIR/bin/collie'" a
  [ ! -t 1 ] || printf '\033[H\033[2J'
  case ${id:+x}$k in
    xr) a="$self run '$id'" ;;
    xa) a="$self adopt '$id'" ;;
    xe) a="$self edit '$id'" ;;
    xv) a="$self review '$id' | less -R" ;;
    xt)
      # a shell in the task's first worktree; its exit status is not a failure
      a=$(awk -F'\t' 'NR == 1 { print $4 }' "$TASKS_DIR/$id/repos.tsv" 2>/dev/null)
      [ -d "$a" ] || a="$TASKS_DIR/$id"
      (cd "$a" && "${SHELL:-sh}") || true
      return 0
      ;;
    xd)
      read -r -p "done $id? (y/n) " k || return 0
      [ "$k" = y ] || return 0
      a="$self done '$id'"
      ;;
    c | xc) a="$self new" ;;
    *) return 0 ;;
  esac
  cmd__popup "$a"
}

# Menu for prefix <@collie-key>, built per session: task actions only inside a
# task's session (see collie.tmux).
cmd__menu() { # session [client]
  local C="$PLUGIN_DIR/bin/collie" T=$1 popup="display-popup -E -w 90% -h 85%" items
  items=(dashboard h "$popup '$C _popup $C dash'"
    lazygit g "$popup -d '#{pane_current_path}' '$C _popup lazygit'"
    terminal t "$popup -d '#{pane_current_path}'"
    "new task" c "display-popup -EE -w 70 -h 15 -d '#{pane_current_path}' '$C new'")
  if valid_id "$T" && [ -f "$TASKS_DIR/$T/TASK.md" ]; then
    items+=("edit task" e "$popup '$C _popup $C edit $T'"
      review v "$popup '$C _popup \"$C review $T | less -R\"'"
      ""
      "run agent" r "run-shell '$C run $T'"
      "done" d "confirm-before -p 'done $T? (y/n)' \"display-popup -E -w 90 -h 12 '$C _popup $C done $T'\"")
  else
    items+=("" "-not a collie task — use collie new" "" "")
  fi
  items+=("" "jump to alert" j "run-shell '$C _jump - ${2:-}'")
  if [ "${COLLIE_DEV:-$(tmux_opt @collie-dev)}" = on ]; then
    items+=("" "dev: load this checkout" D "run-shell '$C _dev load #{q:pane_current_path}'"
      "dev: back to installed" B "run-shell '$C _dev reset'")
  fi
  tmux display-menu ${2:+-c "$2"} -T '#[align=centre] collie ' -x C -y C "${items[@]}"
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
cmd__popup() {
  local rc=0
  (eval "$*") || rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf '\n[collie: exit %s — press any key]' "$rc"
  read -rsn1 _ || true
  return "$rc"
}

# Window of the task's most urgent run, or "-".
cmd__target() {
  local id
  task_id "${1:-}"
  task_top "$id" | cut -f2
}

cmd__preview() {
  local id d name c b p base top title
  [ $# -eq 0 ] || [ -n "$1" ] || return 0 # a dash group separator
  task_id "${1:-}"
  d="$TASKS_DIR/$id"
  fm_get "$d/TASK.md" title
  title=$FM
  top=$(task_top "$id")
  task_status "$id" "${top%%"$TAB"*}"
  fm_get "$d/TASK.md" priority
  printf '%s  [%s %s]\n' "$title" "$STATUS" "$FM"
  echo
  echo "objective:"
  awk '$0 == "## Objective" { f = 1; next }
    f && /^## / { exit }
    f && NF && n++ < 5 { print "  " $0 }
    END { if (!n) print "  (empty)" }' "$d/TASK.md"
  echo
  echo "runs:"
  task_runs "$id" | sed 's/^/  /'
  echo
  echo "repos:"
  while IFS=$TAB read -r name c b p; do
    if [ ! -d "$p" ]; then
      printf '  %s  %s  (missing)\n' "$name" "$b"
      continue
    fi
    default_base "$c"
    base=$BASE
    printf '  %s  %s  %s ahead, %s dirty  %s\n' "$name" "$b" \
      "$(git --git-dir="$c" rev-list --count "$base..refs/heads/$b" 2>/dev/null || echo '?')" \
      "$(git -C "$p" status --porcelain | wc -l | tr -d ' ')" \
      "$(git -C "$p" diff --shortstat "$base" 2>/dev/null)"
  done <"$d/repos.tsv"
}
