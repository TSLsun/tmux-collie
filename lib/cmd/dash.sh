# shellcheck shell=bash
# Sourced by bin/collie: dashboard, menu and popups.

# Each task's PRs, one per repo with one: <task>/pr.tsv holds
# "repo<TAB>number<TAB>open|draft|merged|closed" lines. gh is slow and needs
# the network, so the dashboard only reads the file and refreshes it in the
# background once it is PR_TTL minutes old; sync and gc refresh it inline.
PR_TTL=5

# Refreshes <task>/pr.tsv; a repo whose lookup fails keeps its last entry.
cmd__pr() { # id
  local d="$TASKS_DIR/$1" name c b p line out=""
  command -v gh >/dev/null || return 0
  [ -f "$d/repos.tsv" ] || return 0
  while IFS=$TAB read -r name c b p; do
    # folders have no branch
    [ "$c" != - ] || continue
    [ -d "$p" ] || continue
    # newest first; a draft is open too
    if ! line=$(cd "$p" && gh pr list --state all --head "$b" --limit 1 --json number,state,isDraft \
      --jq '.[] | "\(.number)\t\(if .isDraft and .state == "OPEN" then "draft" else .state | ascii_downcase end)"' \
      </dev/null 2>/dev/null); then
      line=$(awk -F'\t' -v n="$name" '$1 == n { print $2 "\t" $3 }' "$d/pr.tsv" 2>/dev/null) || line=""
    fi
    [ -z "$line" ] || out="$out$name$TAB$line"$'\n'
  done <"$d/repos.tsv"
  printf '%s' "$out" >"$d/pr.tsv.$$" && mv "$d/pr.tsv.$$" "$d/pr.tsv"
}

# Starts a background cmd__pr for each task (rows in `ls` format) whose pr.tsv
# is missing or stale, touching it first so the next reload does not start another.
pr_refresh_stale() { # rows
  local fresh id _
  command -v gh >/dev/null || return 0
  fresh=$(find "$TASKS_DIR" -mindepth 2 -maxdepth 2 -name pr.tsv -mmin "-$PR_TTL" 2>/dev/null) || true
  while IFS=$TAB read -r id _; do
    case $'\n'"$fresh"$'\n' in *"/$id/pr.tsv"$'\n'*) continue ;; esac
    touch "$TASKS_DIR/$id/pr.tsv"
    "$BASH" "$PLUGIN_DIR/bin/collie" _pr "$id" </dev/null >/dev/null 2>&1 &
  done <<<"$1"
}

# Predicted conflicts (see conflicts_predict) of the given active tasks whose
# conflicts.tsv is current: base and every branch it names are still at the
# cached SHAs, and the other tasks are active. Sets CONFLICTS to
# "id<TAB>count<TAB>other (files), ..." lines, one per task with conflicts
# (base counts as one); no merge-tree, one git per repo, none without caches. A stale cache shows nothing and
# starts a background _conflicts, unless one is running.
conflicts_cached() { # ids (one per line)
  local id c seen=$'\n' refs="" rc
  CONFLICTS=""
  while IFS= read -r id; do
    [ -s "$TASKS_DIR/$id/conflicts.tsv" ] || continue
    while IFS=$TAB read -r c _; do
      case $seen in *$'\n'"$c"$'\n'*) continue ;; esac
      seen="$seen$c"$'\n'
      refs="$refs$(git --git-dir="$c" for-each-ref --format="${c//%/%%}%09%(refname)%09%(objectname)" refs/heads refs/remotes 2>/dev/null)"$'\n'
    done <"$TASKS_DIR/$id/conflicts.tsv"
  done <<<"$1"
  [ "$seen" != $'\n' ] || return 0
  CONFLICTS=$(REFS=$refs IDS=$1 awk -F'\t' -v tasks="$TASKS_DIR" '
    BEGIN {
      n = split(ENVIRON["REFS"], l, "\n")
      for (i = 1; i <= n; i++) if (split(l[i], x, "\t") == 3) sha[x[1], x[2]] = x[3]
      n = split(ENVIRON["IDS"], ids, "\n")
      for (i = 1; i <= n; i++) if (ids[i] != "") on[ids[i]] = 1
      for (i = 1; i <= n; i++) {
        if (ids[i] == "") continue
        f = tasks "/" ids[i] "/conflicts.tsv"; ok = 1; k = 0; s = ""
        while ((getline r <f) > 0) {
          split(r, x, "\t")
          if (sha[x[1], x[2]] != x[3] || sha[x[1], x[4]] != x[5]) ok = 0
          if (x[6] == "-") continue
          if (x[6] != "base" && (!(x[6] in on) || sha[x[1], x[7]] != x[8])) ok = 0
          gsub(/ /, ", ", x[9])
          if (!(x[6] in cnt)) k++
          cnt[x[6]] = 1
          s = s (s == "" ? "" : ", ") x[6] " (" x[9] ")"
        }
        close(f)
        for (o in cnt) delete cnt[o]
        if (!ok) stale = 1
        else if (k) print ids[i] "\t" k "\t" s
      }
      exit stale ? 3 : 0
    }') && rc=0 || rc=$?
  [ "$rc" -eq 3 ] && [ ! -d "$STATE_DIR/conflicts.lock" ] || return 0
  "$BASH" "$PLUGIN_DIR/bin/collie" _conflicts </dev/null >/dev/null 2>&1 &
}

# Background refresh of the conflict caches from local refs (no fetch); the
# lock keeps reloads of the dashboard from starting another.
cmd__conflicts() {
  mkdir -p "$STATE_DIR"
  mkdir "$STATE_DIR/conflicts.lock" 2>/dev/null || return 0
  trap 'rmdir "$STATE_DIR/conflicts.lock"' EXIT
  conflicts_predict >/dev/null
}

# Active tasks in `ls` format, most urgent first (see DESIGN §3.3: answer >
# reply > review > stalled > working > start), then by priority and id, plus
# two last fields: the cached PRs ("#<number>:<state> ...", or -) and the
# number of predicted conflicts (see conflicts_cached, or -).
dash_rows() {
  local rows ids="" id _
  rows=$(cmd_ls)
  [ -n "$rows" ] || return 0
  pr_refresh_stale "$rows"
  while IFS=$TAB read -r id _; do ids="$ids$id"$'\n'; done <<<"$rows"
  conflicts_cached "$ids"
  CONFLICTS=$CONFLICTS awk -F'\t' -v tasks="$TASKS_DIR" '
    BEGIN { n = split(ENVIRON["CONFLICTS"], cl, "\n"); for (i = 1; i <= n; i++) if (split(cl[i], x, "\t") == 3) cf[x[1]] = x[2] }
    {
      r = 6
      if ($7 == "answer") r = 1
      else if ($7 == "reply") r = 2
      else if ($7 == "review") r = 3
      else if ($7 == "stalled") r = 4
      else if ($7 == "-") r = 5
      f = tasks "/" $1 "/pr.tsv"; s = ""
      while ((getline l <f) > 0) if (split(l, x, "\t") == 3) s = s (s == "" ? "" : " ") "#" x[2] ":" x[3]
      close(f)
      print r "\t" $0 "\t" (s == "" ? "-" : s) "\t" ($1 in cf ? cf[$1] : "-")
    }' <<<"$rows" | sort -t "$TAB" -k1,1n -k4,4 -k2,2 | cut -f2-
}

DASH_GROUPS=(status priority repo)

# awk functions: ISO 8601 UTC time to epoch seconds (days from civil), and
# seconds to a short age.
DASH_AWK_TIME='
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
  }'

# Where the preview goes: right of the list when rows <width> wide fit beside
# it, below otherwise; long lines wrap. Sets PREVIEW and WIDTH, the list's text
# width (fzf's gutter and scrollbar off) from fzf's FZF_COLUMNS or COLUMNS, 0
# when unknown.
preview_layout() { # width
  local c=${FZF_COLUMNS:-${COLUMNS:-0}}
  PREVIEW='right,50%,wrap' WIDTH=$((c - c / 2 - 4))
  if [ "$c" -le 3 ]; then
    WIDTH=0
  elif [ "$WIDTH" -lt "$1" ] || [ "$WIDTH" -lt 40 ]; then
    PREVIEW='down,45%,wrap' WIDTH=$((c - 3))
  fi
}

# preview_layout for the dashboard's rows, their width cached by _rows.
dash_layout() {
  local w=0
  [ ! -s "$STATE_DIR/dash-width" ] || read -r w <"$STATE_DIR/dash-width" || true
  preview_layout "$w"
}

# The dashboard's grouping (DASH_GROUPS), kept across dashboards. Sets GROUP.
dash_group() {
  GROUP=""
  [ ! -f "$STATE_DIR/dash-group" ] || read -r GROUP <"$STATE_DIR/dash-group" || true
  case " ${DASH_GROUPS[*]} " in *" $GROUP "*) ;; *) GROUP=status ;; esac
}

# Two lines, each wrapped at the list's width (dash_layout) so narrow popups do
# not cut the keys off; the group and a kept filter (the input is hidden
# outside a search) in bold yellow.
dash_header() { # group [filter]
  local y=$'\033[1;33m' z=$'\033[0m' h n line="" len=0 out="" hints=()
  # a ")" would end fzf's change-header(...)
  [ -z "${2:-}" ] || hints+=("filter: $y${2//)/}$z" "esc: clear")
  if dash_runs; then
    hints+=("runs of $y$RUNS_OF$z" "enter: go" "/: filter" "" "h: handoff" "esc: back" "")
  else
    hints+=("enter: go" "tab: group by $y$1$z" "/: filter" "space: mark" ""
      "r: run" "u: runs" "v: review" "e: edit" "d: done" "s: sync" "?: more" "")
  fi
  dash_layout
  for h in "${hints[@]}"; do
    n=${#h}
    [[ $h != *"$y"* ]] || n=$((n - ${#y} - ${#z}))
    if [ -n "$line" ] && { [ -z "$h" ] || { [ "$WIDTH" -gt 0 ] && [ $((len + 2 + n)) -gt "$WIDTH" ]; }; }; then
      out="$out${out:+$'\n'}$line" line="" len=0
    fi
    [ -n "$h" ] || continue
    if [ -z "$line" ]; then line=$h len=$n; else line="$line  $h" len=$((len + 2 + n)); fi
  done
  printf '%s' "$out"
}

# dash_rows for fzf, in groups (DASH_GROUPS; status: needs you, active, todo;
# priority: P0..P3; repo: most urgent first), each topped by a dim
# "── <group> (<n>) ──" line (fzf lists bottom-up, so it follows its rows).
# A row is the id, then aligned columns: a glyph (red ● needs you, yellow ◐
# working, dim ○ todo) and the whole id (fzf filters on it), state (what it
# needs from you, or working), colored priority, PRs (green open, dim draft,
# purple merged, red closed), then a yellow ⚡N when the task conflicts with N
# others (see conflicts_cached). Agents, age and repos are in the preview.
# Separators have an empty id. $STATE_DIR/dash-rows gets the ids in order
# (empty for separators), for _key; $STATE_DIR/dash-width the rows' width,
# for dash_layout.
# shellcheck disable=SC2120  # group comes from the CLI; internal callers pass none
cmd__rows() { # [group]
  local g=${1:-}
  if [ -z "$g" ]; then
    dash_group
    g=$GROUP
  fi
  mkdir -p "$STATE_DIR"
  dash_rows | awk -F'\t' -v g="$g" -v cache="$STATE_DIR/dash-rows" -v width="$STATE_DIR/dash-width" '
    function pad(s, w, l) { return s sprintf("%" (w - l > 0 ? w - l : 0) "s", "") }
    function max(a, b) { return a > b ? a : b }
    BEGIN {
      pc["P0"] = "1;31"; pc["P1"] = "33"; pc["P3"] = "2"
      e = "\033["
      qc["open"] = "32"; qc["draft"] = "2"; qc["merged"] = "35"; qc["closed"] = "31"
      printf "" >cache; printf "" >width
    }
    {
      n++; id[n] = $1; st[n] = $7 == "-" ? "working" : $7; pr[n] = $3
      you = $7 != "-" && $7 != "start"
      gl[n] = you ? e "31m●" : $7 == "-" ? e "33m◐" : e "2m○"
      k = $8 == "-" ? 0 : split($8, a, " "); b = ""; ql[n] = k ? -1 : 0
      for (i = 1; i <= k; i++) {
        split(a[i], x, ":"); b = b (i > 1 ? " " : "") e (x[2] in qc ? qc[x[2]] : "0") "m" x[1] e "0m"; ql[n] += length(x[1]) + 1
      }
      pq[n] = b
      # ⚡ takes two columns
      cf[n] = $9 == "-" || $9 == "" ? "" : e "33m⚡" $9 e "0m"; cl[n] = cf[n] == "" ? 0 : 2 + length($9)
      if (g == "priority") k = $3
      else if (g == "repo") k = $6
      else if (you) k = "needs you"
      else k = $2
      if (!(k in cnt)) seen[++ns] = k
      cnt[k]++; key[n] = k
      wi = max(wi, length($1)); ws = max(ws, length(st[n])); wp = max(wp, length($3)); wq = max(wq, ql[n])
    }
    END {
      if (!n) exit
      if (g == "priority") for (i = 0; i <= 3; i++) if (("P" i) in cnt) { ord[++no] = "P" i; done["P" i] = 1 }
      for (i = 1; i <= ns; i++) if (!(seen[i] in done)) ord[++no] = seen[i]
      # PRs, then the badge, aligned; nothing (no trailing blanks) when a row has neither
      for (i = 1; i <= n; i++) {
        t[i] = cf[i] == "" ? pq[i] : (wq ? pad(pq[i], wq, ql[i]) " " : "") cf[i]
        tl[i] = cf[i] == "" ? ql[i] : (wq ? wq + 1 : 0) + cl[i]
        w = max(w, 2 + wi + 2 + ws + 2 + wp + (tl[i] ? 2 + tl[i] : 0))
      }
      # a separator keeps at least two ─ after its label
      for (j = 1; j <= no; j++) w = max(w, length(ord[j] cnt[ord[j]]) + 9)
      print w >width
      for (j = 1; j <= no; j++) {
        for (i = 1; i <= n; i++) {
          if (key[i] != ord[j]) continue
          p = pr[i] in pc ? e pc[pr[i]] "m" pr[i] e "0m" : pr[i]
          print id[i] "\t" gl[i] e "0m " pad(id[i], wi, length(id[i])) "  " pad(st[i], ws, length(st[i])) "  " \
            (t[i] == "" ? p : pad(p, wp, length(pr[i])) "  " t[i])
          print id[i] >cache
        }
        l = "── " ord[j] " (" cnt[ord[j]] ") "
        for (r = w - length(ord[j] cnt[ord[j]]) - 7; r > 0; r--) l = l "─"
        print "\t" e "2m" l e "0m"
        print "" >cache
      }
    }'
}

# Whether the dashboard lists a task's runs (u) instead of the tasks: its
# $COLLIE_DASH/runs holds the task id. Sets RUNS_OF to it.
dash_runs() {
  RUNS_OF=""
  [ -n "${COLLIE_DASH:-}" ] && [ -s "$COLLIE_DASH/runs" ] || return 1
  read -r RUNS_OF <"$COLLIE_DASH/runs"
}

# The runs view's rows (see run_history), newest first: the run (or the window
# of an agent started by hand), then aligned columns: run, agent, repo, state
# (yellow live, dim ended, red lost), age, note. $STATE_DIR/dash-rows and
# dash-width as for _rows.
cmd__runrows() { # [id]
  local id=${1:-}
  [ -n "$id" ] || { dash_runs || return 0; id=$RUNS_OF; }
  mkdir -p "$STATE_DIR"
  stamp %s
  run_history "$id" | awk -F'\t' -v now="$NOW" -v cache="$STATE_DIR/dash-rows" -v width="$STATE_DIR/dash-width" "$DASH_AWK_TIME"'
    function pad(s, w) { return s sprintf("%" (w - length(s) > 0 ? w - length(s) : 0) "s", "") }
    function max(a, b) { return a > b ? a : b }
    {
      n++; key[n] = $1 == "-" ? $5 : $1; run[n] = $1 == "-" ? "-" : "#" $1
      ag[n] = $2; rp[n] = $3; st[n] = $4; nt[n] = $7 == "-" ? "" : $7
      a[n] = $6 == "-" ? "" : age(now - epoch($6))
      c[n] = $4 ~ /^(working|waiting|idle)$/ ? "33" : $4 == "lost" ? "31" : "2"
      wr = max(wr, length(run[n])); wa = max(wa, length($2)); wp = max(wp, length($3)); ws = max(ws, length($4)); wt = max(wt, length(a[n]))
    }
    END {
      printf "" >cache
      for (i = 1; i <= n; i++) {
        l = pad(run[i], wr) "  " pad(ag[i], wa) "  " pad(rp[i], wp) "  \033[" c[i] "m" pad(st[i], ws) "\033[0m  " pad(a[i], wt)
        if (nt[i] != "") l = l "  " nt[i]
        w = max(w, wr + wa + wp + ws + wt + 8 + (nt[i] == "" ? 0 : 2 + length(nt[i])))
        print key[i] "\t" l
        print key[i] >cache
      }
      print w + 0 >width
    }'
}

# fzf transform for tab / btab (next / prev): switch the dashboard grouping.
cmd__group() { # next|prev
  case ${FZF_PROMPT:-} in "$PICK_MARK"* | "$ASK_MARK"*) return 0 ;; esac
  ! dash_runs || return 0
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" n=${#DASH_GROUPS[@]} i
  dash_group
  for i in "${!DASH_GROUPS[@]}"; do [ "${DASH_GROUPS[$i]}" != "$GROUP" ] || break; done
  if [ "${1:-}" = prev ]; then i=$(((i + n - 1) % n)); else i=$(((i + 1) % n)); fi
  mkdir -p "$STATE_DIR"
  printf '%s\n' "${DASH_GROUPS[$i]}" >"$STATE_DIR/dash-group"
  echo "change-header($(dash_header "${DASH_GROUPS[$i]}" "$(dash_filter)"))+reload($self _rows)"
}

# The query to show in the header: only outside a search, which shows it.
dash_filter() { [ "${FZF_PROMPT:-}" = "$SEARCH_PROMPT" ] || printf '%s' "${FZF_QUERY:-}"; }

cmd_dash() {
  if [ "${1:-}" = -n ]; then
    dash_rows
    return
  fi
  command -v fzf >/dev/null || die "dash: fzf required"
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" rows header sel id wid k go binds=() COLUMNS=${COLUMNS:-} rc=0
  # fzf passes its width to reloads and transforms (FZF_COLUMNS), not to this first draw
  [ -n "$COLUMNS" ] || { COLUMNS=$(stty size </dev/tty 2>/dev/null) && COLUMNS=${COLUMNS#* }; } || COLUMNS=""
  rows=$(cmd__rows)
  dash_layout
  # the action panel's state (see dash_panel), for this dashboard's transforms
  export COLLIE_DASH="$STATE_DIR/dash.$$"
  mkdir -p "$COLLIE_DASH"
  for k in $(action_items x | cut -c1) enter up down j k q space / '?' y n u h; do
    binds+=(--bind="$k:transform($self _key '$k' {1} {+1})")
  done
  # after the transform: fzf ignores clear-query while the input is hidden
  binds+=(--bind="esc:transform($self _key esc {1} {+1})+hide-input")
  dash_group
  header=$(dash_header "$GROUP")
  [ -n "$rows" ] || header='no tasks — c: new task'
  sel=$(printf '%s' "$rows" | fzf --ansi --delimiter='\t' --with-nth=2.. --no-sort --prompt="$DASH_PROMPT" \
    --no-input --multi --marker='*' \
    --header="$header" \
    --preview="$self _preview {1}" --preview-window="$PREVIEW" \
    "${binds[@]}" \
    --bind="tab:transform($self _group next)" --bind="btab:transform($self _group prev)") || rc=$?
  # enter in the runs view: "<task><TAB><window>" (see dash_runs_key)
  go=$(cat "$COLLIE_DASH/go" 2>/dev/null) || go=""
  rm -rf "$COLLIE_DASH"
  [ "$rc" -eq 0 ] || return 0
  if [ -n "$go" ]; then
    tmux select-window -t "${go#*"$TAB"}" 2>/dev/null || true
    cmd_go "${go%%"$TAB"*}"
    return
  fi
  id=${sel%%"$TAB"*}
  [ -n "$id" ] || return 0
  wid=$(cmd__target "$id")
  if [ "$wid" != - ]; then tmux select-window -t "$wid" 2>/dev/null || true; fi
  cmd_go "$id"
}

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
# in the background; done, archive, adopt and sync ask y/n in the panel first
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
    r) dash_bg r "$id" ;;
    s)
      for m in "$@"; do [ -z "$m" ] || ids="$ids $m"; done
      echo "change-prompt($ASK_MARK$k${ids:- $id} )+refresh-preview"
      ;;
    *) echo "change-prompt($ASK_MARK$k $id )+refresh-preview" ;;
  esac
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
cmd__bg() { # key id...
  local self="'$BASH' '$PLUGIN_DIR/bin/collie'" k=$1 a out rc=0 rows=_rows
  shift
  # the user may have opened a task's runs (u) meanwhile
  ! dash_runs || rows=_runrows
  case $k in
    r) a=(run "$1") ;;
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

# The dashboard's preview doubles as its action panel: a failed action's
# output (until a key), the ? menu, a y/n question (sync shows `sync -n`
# below it, done and archive the task), or `collie review` (v); a running or
# finished action puts one line on top. Fails when the task preview follows.
dash_panel() { # id
  local f="${COLLIE_DASH:-}/msg" kind line k ids
  if [ -f "$f" ]; then
    { read -r kind && read -r line; } <"$f" || true
    case $kind in
      fail)
        printf '\033[31m'
        tail -n +2 "$f"
        printf '\033[0m\n[press any key]\n'
        return 0
        ;;
      ok) printf '\033[32m%s\033[0m\n\n' "$line" ;;
      *) printf '\033[33m%s\033[0m\n\n' "$line" ;;
    esac
  fi
  case ${FZF_PROMPT:-} in
    "$PICK_MARK"*)
      pick_lines "$1" "$(k=${FZF_PROMPT#"$PICK_MARK"} && echo "${k% }")"
      return 0
      ;;
    "$ASK_MARK"*)
      read -r k ids <<<"${FZF_PROMPT#"$ASK_MARK"}"
      printf '\033[1;33m%s %s? (y/n)\033[0m\n\n' "$(action_verb "$k")" "$ids"
      case $k in
        s)
          # shellcheck disable=SC2086  # the ids, split
          "$BASH" "$PLUGIN_DIR/bin/collie" sync -n $ids 2>&1
          return 0
          ;;
        a)
          echo "stops the agent started by hand and resumes it under collie run"
          return 0
          ;;
      esac
      return 1
      ;;
  esac
  if [ "${FZF_PREVIEW_LABEL:-}" = "$REVIEW_LABEL" ] && [ -n "$1" ]; then
    "$BASH" "$PLUGIN_DIR/bin/collie" review "$1" 2>&1
    return 0
  fi
  return 1
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
  [ -z "$1" ] || printf '%s\n' 'r  run agent' 'a  adopt agent' 'e  edit task' 'v  review' 't  terminal' 'd  done' 'x  archive' 's  sync'
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
  local C="$PLUGIN_DIR/bin/collie" T=$1 popup="display-popup -E -w 90% -h 85%" items
  items=(dashboard h "$popup '$C _popup $C dash'"
    lazygit g "$popup -d '#{pane_current_path}' '$C _popup lazygit'"
    terminal t "$popup -d '#{pane_current_path}'"
    "new task" c "display-popup -EE -w 70 -h 15 -d '#{pane_current_path}' '$C new'")
  if valid_id "$T" && [ -f "$TASKS_DIR/$T/TASK.md" ]; then
    items+=("edit task" e "$popup '$C _popup $C edit $T'"
      review v "$popup '$C _popup \"$C review $T | less -R\"'"
      ""
      "run agent" r "run-shell '$C run $T -s${2:+ -c $2}'"
      "adopt agent" a "display-popup -E -w 90 -h 12 '$C _popup $C adopt $T'"
      "done" d "confirm-before -p 'done $T? (y/n)' \"display-popup -E -w 90 -h 12 '$C _popup $C done $T'\""
      archive x "confirm-before -p 'archive $T? (y/n)' \"display-popup -E -w 90 -h 12 '$C _popup $C archive $T'\"")
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

# A run of the runs view (see run_history; an agent started by hand is its
# window): agent, repo, state, start, session, handoff/restore links, and the
# handoff packet it came from.
run_preview() { # id run|window
  local d="$TASKS_DIR/$1" r
  r=$(run_history "$1" | awk -F'\t' -v k="$2" '$1 == k || ($1 == "-" && $5 == k) { print; exit }')
  [ -n "$r" ] || return 0
  awk -F'\t' -v ev="$d/events.log" '
    function kv(s, k,  a, i, n) {
      n = split(s, a, " ")
      for (i = 1; i <= n; i++) if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
    }
    {
      print ($1 == "-" ? "agent started by hand" : "run #" $1) "  [" $4 "]"
      print "agent:   " $2
      if ($3 != "-") print "repo:    " $3
      if ($6 != "-") print "started: " $6
      if ($5 != "-") print "window:  " $5
      if ($7 != "-") print "links:   " $7
      if ($1 == "-") { print ""; print "a (on the task): adopt it as a collie run"; exit }
      while ((getline l <ev) > 0) {
        split(l, f, "\t")
        if (f[2] == "agent_session" && kv(f[3], "run") == $1) sid = kv(f[3], "id")
        if (f[2] == "run_exited" && kv(f[3], "run") == $1) end = f[1]
        if (f[2] == "run_handoff" && kv(f[3], "to") == $1) pk = kv(f[3], "packet")
      }
      if (end != "") print "ended:   " end
      if (sid != "") print "session: " sid
      if (pk != "") print "packet:  handoffs/" pk
      if ($4 ~ /^(working|waiting|idle)$/) print "\nenter: go to its window"
      else if ($4 == "lost") print "\nno exit logged and no window: collie restore may bring it back"
    }' <<<"$r"
  case $(cut -f2 <<<"$r") in claude | codex) [ "${2#@}" != "$2" ] || echo "h: hand off to $([ "$(cut -f2 <<<"$r")" = claude ] && echo codex || echo claude)" ;; esac
}

# The task's title, status and priority, its live agents and last event's
# age, the Objective, runs, and per repo its branch, PRs and progress.
cmd__preview() {
  local id d name c b p base top title ids line a
  [ -z "${COLLIE_DASH:-}" ] || ! dash_panel "${1:-}" || return 0
  [ $# -eq 0 ] || [ -n "$1" ] || return 0 # a dash group separator
  if dash_runs; then
    run_preview "$RUNS_OF" "$1"
    return
  fi
  task_id "${1:-}"
  d="$TASKS_DIR/$id"
  fm_get "$d/TASK.md" title
  title=$FM
  top=$(task_top "$id")
  task_status "$id" "${top%%"$TAB"*}"
  fm_get "$d/TASK.md" priority
  printf '%s  [%s %s]\n' "$title" "$STATUS" "$FM"
  [ -z "$STATUS_NOTE" ] || echo "$STATUS_NOTE"
  line=${top##*"$TAB"}
  line=${line% }
  if [ -n "$LAST_EVENT" ]; then
    a=$(awk -v t="$LAST_EVENT" "$DASH_AWK_TIME"' BEGIN { srand(); a = age(srand() - epoch(t)); print (a == "now" ? a : a " ago") }')
    line="$line${line:+ · }last event $a"
  fi
  [ -z "$line" ] || echo "$line"
  case $STATUS in done | archived) printf 'finished %s\n' "$(finished_at "$id")" ;; esac
  echo
  echo "objective:"
  awk '$0 == "## Objective" { f = 1; next }
    f && /^## / { exit }
    f && NF && n++ < 5 { print "  " $0 }
    END { if (!n) print "  (empty)" }' "$d/TASK.md"
  echo
  # the newest runs; ▸ marks the one enter goes to (see _target)
  a=$(run_history "$id")
  printf 'runs:%s\n' "$([ "$(grep -c . <<<"$a")" -le 5 ] || printf '  (newest 5 of %s; u: all)' "$(grep -c . <<<"$a")")"
  [ -n "$a" ] || echo "  (none)"
  [ -z "$a" ] || awk -F'\t' -v w="$(cut -f2 <<<"$top")" '
    NR <= 5 { print ($5 == w && w != "-" ? "▸ " : "  ") ($1 == "-" ? "-" : "#" $1) "  " $2 "  " $3 "  " $4 ($7 == "-" ? "" : "  " $7) }' <<<"$a"
  echo
  echo "repos:"
  case $STATUS in done | archived)
    while IFS=$TAB read -r name c b p; do
      if [ "$c" = - ]; then printf '  %s  folder  %s\n' "$name" "$p"; else printf '  %s  %s  (removed)\n' "$name" "$b"; fi
    done <"$d/repos.tsv"
    echo
    echo "commits:"
    task_commits "$id" | sed 's/^/  /'
    if [ -f "$d/REPORT.md" ]; then
      echo
      echo "report:"
      sed 's/^/  /' "$d/REPORT.md"
    fi
    return
    ;;
  esac
  while IFS=$TAB read -r name c b p; do
    if [ ! -d "$p" ]; then
      printf '  %s  %s  (missing)\n' "$name" "$b"
      continue
    fi
    if [ "$c" = - ]; then
      printf '  %s  folder  %s\n' "$name" "$p"
      continue
    fi
    default_base "$c"
    base=$BASE
    a=$(awk -F'\t' -v n="$name" '$1 == n { print "  #" $2 " " $3 }' "$d/pr.tsv" 2>/dev/null) || a=""
    printf '  %s  %s%s  %s ahead, %s dirty  %s\n' "$name" "$b" "$a" \
      "$(git --git-dir="$c" rev-list --count "$base..refs/heads/$b" 2>/dev/null || echo '?')" \
      "$(git -C "$p" status --porcelain | wc -l | tr -d ' ')" \
      "$(git -C "$p" diff --shortstat "$base" 2>/dev/null)"
  done <"$d/repos.tsv"
  ids=""
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    fm_get "$d/TASK.md" status
    case $FM in done | archived) ;; *) ids="$ids${d##*/}"$'\n' ;; esac
  done
  conflicts_cached "$ids"
  while IFS=$TAB read -r c _ p; do
    [ "$c" != "$id" ] || printf '\nconflicts with: %s\n' "$p"
  done <<<"$CONFLICTS"
}
