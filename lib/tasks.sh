# shellcheck shell=bash
# Sourced by bin/collie: task files.

# --- task files -------------------------------------------------------------

valid_id() {
  local re='^[a-z0-9][a-z0-9-]{0,39}$'
  [[ $1 =~ $re ]]
}

# Sets the caller's id: the argument, else $COLLIE_TASK; must exist.
task_id() {
  id=${1:-${COLLIE_TASK:-}}
  [ -n "$id" ] || die "no task given (and \$COLLIE_TASK unset)"
  [ -f "$TASKS_DIR/$id/TASK.md" ] || die "no task '$id'"
}

# Sets FM to a frontmatter value ("" if unset). Sets a variable and reads in
# bash: an awk in a command substitution per field was two processes.
fm_get() { # file key
  local l n=0
  FM=""
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      [ "$l" = --- ] || return 0
      continue
    fi
    [ "$l" != --- ] || return 0
    case $l in "$2:"*)
      l=${l#"$2:"}
      FM=${l# }
      return 0
      ;;
    esac
  done <"$1"
}

fm_set() {
  fm_mutate "$1" set "$2" "$3"
}

fm_del() { # file key
  fm_mutate "$1" del "$2"
}

# Serialize the entire read/modify/rename, not just the rename. A subshell keeps
# cleanup traps local to this mutation (including when called under `if`).
# TASK.md.lock is independent of the lifecycle allocator's run.lock; callers
# may hold run.lock while updating metadata, never the reverse.
fm_mutate() (
  local file=$1 op=$2 key=$3 value=${4:-} lock receipt tmp='' attempts=0
  # Resolve directory aliases such as a worktree's .collie symlink so every
  # writer uses the same lock. Keep the temp beside the file for atomic rename.
  case $file in */*) ;; *) file="./$file" ;; esac
  file="$(cd "${file%/*}" && pwd -P)/${file##*/}" || return 1
  lock="$file.lock"
  # uutils mkdir on Ubuntu 26.04 can exit 0 after losing a creation race
  # (uutils/coreutils#13970). Its verbose receipt is emitted only on creation;
  # require both success and a receipt without parsing localized output.
  while ! receipt=$(mkdir -v "$lock" 2>/dev/null) || [ -z "$receipt" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 400 ]; then
      printf 'collie: timed out locking metadata %s\n' "$file" >&2
      return 1
    fi
    sleep 0.025
  done
  # Bash 3.2 unwinds locals before EXIT on a signal-triggered explicit exit.
  # Capture shell-quoted paths now, rather than looking up locals in the trap.
  # shellcheck disable=SC2064
  trap "rmdir $(printf '%q' "$lock")" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tmp=$(mktemp "$file.tmp.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -f $(printf '%q' "$tmp"); rmdir $(printf '%q' "$lock")" EXIT
  # Preserve the original permissions; never publish a partial transform.
  cp -p "$file" "$tmp" || return 1
  if [ "$op" = set ]; then
    VAL=$value awk -v k="$key" '
    BEGIN { v = ENVIRON["VAL"] }
    NR == 1 { print; next }
    !end && $0 == "---" { if (!found) print k ": " v; end = 1; print; next }
    !end && index($0, k ":") == 1 { print k ": " v; found = 1; next }
    { print }' "$file" >"$tmp" || return 1
  else
    awk -v k="$key" 'NR > 1 && !end && $0 == "---" { end = 1 }
      NR == 1 || end || index($0, k ":") != 1' "$file" >"$tmp" || return 1
  fi
  mv -f "$tmp" "$file" || return 1
)

# NOW: the current time in a strftime format (stamp_utc: in UTC). bash 4.2+
# formats it without forking date; bash 3.2 still runs date.
if [ $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1])) -ge 402 ]; then
  stamp() { printf -v NOW "%($1)T" -1; }
  stamp_utc() { TZ=UTC0 printf -v NOW "%($1)T" -1; }
else
  stamp() { NOW=$(date +"$1"); }
  stamp_utc() { NOW=$(date -u +"$1"); }
fi

log_event() {
  stamp_utc %Y-%m-%dT%H:%M:%SZ
  printf '%s\t%s\t%s\n' "$NOW" "$2" "${3:-}" >>"$TASKS_DIR/$1/events.log"
}

write_task_md() { # dir id title [objective] [ship]
  local tmpl="$CONFIG_DIR/TASK.md" ship="$CONFIG_DIR/SHIP.md"
  [ -f "$tmpl" ] || tmpl="$PLUGIN_DIR/templates/TASK.md"
  [ -f "$ship" ] || ship="$PLUGIN_DIR/templates/SHIP.md"
  stamp %Y-%m-%d
  {
    printf -- '---\nid: %s\ntitle: %s\npriority: P2\ncreated: %s\n---\n' \
      "$2" "$3" "$NOW"
    # objective goes under the template's "## Objective", else at the end
    OBJ=${4:-} awk 'BEGIN { o = ENVIRON["OBJ"] }
      { print }
      o != "" && !done && $0 == "## Objective" { print o; done = 1 }
      END { if (o != "" && !done) print "\n## Objective\n" o }' "$tmpl"
    # ship on: the commit/push/PR/CI rules go at the end
    [ "${5:-0}" = 0 ] || cat "$ship"
  } >"$1/TASK.md"
}

# Which open task (if any) owns a worktree path; a done/archived task keeps
# its old paths in repos.tsv but owns nothing.
task_owning() {
  local f
  for f in "$TASKS_DIR"/*/repos.tsv; do
    [ -f "$f" ] || continue
    if awk -F'\t' -v p="$1" '$4 == p { found = 1 } END { exit !found }' "$f"; then
      fm_get "${f%/*}/TASK.md" status
      case $FM in done | archived) continue ;; esac
      f=${f%/*}
      printf '%s\n' "${f##*/}"
      return
    fi
  done
}
