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
  VAL=$3 awk -v k="$2" '
    BEGIN { v = ENVIRON["VAL"] }
    NR == 1 { print; next }
    !end && $0 == "---" { if (!found) print k ": " v; end = 1; print; next }
    !end && index($0, k ":") == 1 { print k ": " v; found = 1; next }
    { print }' "$1" >"$1.tmp"
  mv "$1.tmp" "$1"
}

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

# Which task (if any) owns a worktree path.
task_owning() {
  local f
  for f in "$TASKS_DIR"/*/repos.tsv; do
    [ -f "$f" ] || continue
    if awk -F'\t' -v p="$1" '$4 == p { found = 1 } END { exit !found }' "$f"; then
      f=${f%/*}
      printf '%s\n' "${f##*/}"
      return
    fi
  done
}
