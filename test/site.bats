#!/usr/bin/env bats

load helper

# The homepage (docs/index.md) shows commands as examples; a renamed or
# removed command must fail here rather than linger on the site.
@test "site: every collie command on the homepage exists" {
  local cmds c missing=""
  # in code only: a line or prompt starting with it, or `collie <cmd>` inline
  cmds=$(grep -oE '(^|\$ |`)collie [a-z][a-z-]*' "$COLLIE_ROOT/docs/index.md" | awk '{ print $NF }' | sort -u)
  [ -n "$cmds" ]
  for c in $cmds; do
    grep -qE "^cmd_${c}\(\)" "$COLLIE_ROOT"/lib/*.sh "$COLLIE_ROOT"/lib/cmd/*.sh || missing="$missing $c"
  done
  [ -z "$missing" ] || { echo "not a collie command:$missing"; false; }
}
