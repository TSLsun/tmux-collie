# shellcheck shell=bash
# Sourced by bin/collie: dashboard PR and conflict caches.

# Each task's PRs: <task>/pr.tsv holds repo<TAB>number<TAB>state<TAB>CI
# lines. CI is pass, fail, pending or -; older caches lack the field. gh is
# slow and needs the network, so the dashboard reads the cache and refreshes it
# in the background once it is PR_TTL minutes old; sync and gc refresh inline.
PR_TTL=5

# Refreshes <task>/pr.tsv; a failed repository lookup keeps all its old rows.
# A cross-branch restoration is admitted only when its body explicitly says
# "restore ... from #N" on one line, referring to a PR on the task branch.
cmd__pr() { # id
  local d="$TASKS_DIR/$1" name c b p line related number state candidate detail out="" failed filter
  filter='"\(.number)\t\(if .isDraft and .state == "OPEN" then "draft" else .state | ascii_downcase end)\t\(
    [.statusCheckRollup[]? | if (.conclusion // "") != "" then .conclusion else (.state // .status) end]
    | if length == 0 then "-"
      elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail"
      elif all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
      else "pending" end)"'
  command -v gh >/dev/null || return 0
  [ -f "$d/repos.tsv" ] || return 0
  while IFS=$TAB read -r name c b p; do
    [ "$c" != - ] || continue
    failed=0
    if [ ! -d "$p" ] || ! line=$(cd "$p" && gh pr list --state all --head "$b" --limit 1000 --json number,state,isDraft,statusCheckRollup \
      --jq ".[] | $filter" \
      </dev/null 2>/dev/null); then
      failed=1
    else
      related=""
      while IFS=$TAB read -r number state; do
        [ -n "$number" ] || continue
        if ! state=$(cd "$p" && gh api --paginate -X GET search/issues \
          -F "q=repo:{owner}/{repo} is:pr \"$number\" in:body" -F per_page=100 \
          --jq "if .incomplete_results or .total_count > 1000 then error(\"incomplete search\") else .items[] | select((.body // \"\") | test(\"(?i)restore[^\\\\n]* from #$number([^0-9]|$)\")) | .number end" \
          </dev/null 2>/dev/null); then
          failed=1
          break
        fi
        while IFS= read -r candidate; do
          [ -n "$candidate" ] || continue
          if ! detail=$(cd "$p" && gh pr view "$candidate" --json number,state,isDraft,statusCheckRollup \
            --jq "$filter" </dev/null 2>/dev/null); then
            failed=1
            break
          fi
          related="$related$detail"$'\n'
        done <<<"$state"
        [ "$failed" -eq 0 ] || break
      done <<<"$line"
      [ -z "$related" ] || line="$line"$'\n'"${related%$'\n'}"
    fi
    if [ "$failed" -eq 1 ]; then
      line=$(awk -F'\t' -v n="$name" '$1 == n { sub(/^[^\t]*\t/, ""); print }' "$d/pr.tsv" 2>/dev/null) || line=""
    fi
    if [ -n "$line" ]; then
      line=$(printf '%s\n' "$line" | awk -F'\t' '!seen[$1]++')
      while IFS= read -r state; do out="$out$name$TAB$state"$'\n'; done <<<"$line"
    fi
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

