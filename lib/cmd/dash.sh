# shellcheck shell=bash
# Sourced by bin/collie: dashboard, menu and popups.

# Active tasks in `ls` format, most urgent first (see DESIGN §3.3: answer >
# reply > findings > review > stalled > working > start > blocked), then by priority and id, plus
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
      r = 7
      if ($7 == "answer") r = 1
      else if ($7 == "reply") r = 2
      else if ($7 == "findings") r = 3
      else if ($7 == "review") r = 4
      else if ($7 == "stalled") r = 5
      else if ($7 == "-") r = 6
      else if ($7 ~ /^blocked/) r = 8
      f = tasks "/" $1 "/pr.tsv"; s = ""
      while ((getline l <f) > 0) if (split(l, x, "\t") >= 3) s = s (s == "" ? "" : " ") "#" x[2] ":" x[3]
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
      n++; id[n] = $1; st[n] = $7 == "-" ? "working" : $7 ~ /^blocked/ ? "blocked" : $7; pr[n] = $3
      you = $7 != "-" && $7 != "start" && st[n] != "blocked"
      gl[n] = you ? e "31m●" : $7 == "-" ? e "33m◐" : e "2m○"
      k = $8 == "-" ? 0 : split($8, a, " "); b = ""; ql[n] = 0; shown = 0
      for (i = 1; i <= k; i++) {
        split(a[i], x, ":")
        suffix = k > i ? " +" (k - i) : ""
        if (shown && ql[n] + 1 + length(x[1]) + length(suffix) > 24) break
        b = b (shown ? " " : "") e (x[2] in qc ? qc[x[2]] : "0") "m" x[1] e "0m"
        ql[n] += (shown ? 1 : 0) + length(x[1]); shown++
      }
      if (shown < k) { suffix = " +" (k - shown); b = b suffix; ql[n] += length(suffix) }
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
  case ${FZF_PROMPT:-} in "$PICK_MARK"* | "$ASK_MARK"* | "$AGENT_MARK"*) return 0 ;; esac
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
  for k in $(action_items x | cut -c1) enter up down j k q space / '?' y n u h 1 2 3 4 5; do
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
        r)
          task_blocked "$TASKS_DIR/${ids%% *}"
          printf 'blocked on: %s (not done or merged)\n\n' "$BLOCKED"
          ;;
      esac
      return 1
      ;;
    "$AGENT_MARK"*)
      k=${FZF_PROMPT#"$AGENT_MARK"}
      printf '\033[1;33mrun %s with:\033[0m\n\n' "${k% }"
      run_agents | awk '{ printf "  \033[36m%d\033[39m  %s%s\n", NR, $0, (NR == 1 ? " (default)" : "") }'
      printf '\n%s\n' "digit: run · enter: default · esc: cancel"
      return 0
      ;;
  esac
  if [ "${FZF_PREVIEW_LABEL:-}" = "$REVIEW_LABEL" ] && [ -n "$1" ]; then
    "$BASH" "$PLUGIN_DIR/bin/collie" review "$1" 2>&1
    return 0
  fi
  return 1
}

rule() { local s="" i; for ((i = 0; i < $1; i++)); do s="$s$2"; done; printf '%s' "$s"; }

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
  awk -F'\t' -v ev="$d/events.log" "$AWK_KV"'
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
        if (f[2] == "agent_session" && kvs(f[3], "run") == $1) sid = kvs(f[3], "id")
        if (f[2] == "run_exited" && kvs(f[3], "run") == $1) end = f[1]
        if (f[2] == "run_handoff" && kvs(f[3], "to") == $1) pk = kvs(f[3], "packet")
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
# age, the Objective, the last decision, runs, and per repo its branch, PRs
# and progress.
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
  [ ! -f "$d/RESUME.md" ] || printf 'resume note: %s\n' "$d/RESUME.md"
  case $STATUS in done | archived) printf 'finished %s\n' "$(finished_at "$id")" ;; esac
  echo
  echo "objective:"
  awk '$0 == "## Objective" { f = 1; next }
    f && /^## / { exit }
    f && NF && n++ < 5 { print "  " $0 }
    END { if (!n) print "  (empty)" }' "$d/TASK.md"
  echo
  a=$(dep_lines "$id")
  [ -z "$a" ] || printf '%s\n\n' "$a"
  last_decision "$d"
  # the newest runs; ▸ marks the one enter goes to (see _target)
  a=$(run_history "$id")
  printf 'runs:%s\n' "$([ "$(grep -c . <<<"$a")" -le 5 ] || printf '  (newest 5 of %s; u: all)' "$(grep -c . <<<"$a")")"
  [ -n "$a" ] || echo "  (none)"
  [ -z "$a" ] || awk -F'\t' -v w="$(cut -f2 <<<"$top")" '
    NR <= 5 { print ($5 == w && w != "-" ? "▸ " : "  ") ($1 == "-" ? "-" : "#" $1) "  " $2 "  " $3 "  " $4 ($7 == "-" ? "" : "  " $7) }' <<<"$a"
  echo
  a=$(verify_results "$id")
  [ -z "$a" ] || printf 'verify:\n%s\n\n' "$a"
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
    a=$(awk -F'\t' -v n="$name" '
      $1 == n {
        s = s (s == "" ? "" : ", ") "#" $2 " " $3
      }
      END { print s }' "$d/pr.tsv" 2>/dev/null) || a=""
    [ -z "$a" ] || a="  $a"
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
