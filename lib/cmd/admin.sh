# shellcheck shell=bash
# Sourced by bin/collie: doctor, repos, workspaces.

cmd_doctor() {
  local fail=0 v a d id name c b p
  echo "dependencies:"
  doc_line ok "bash $BASH_VERSION"
  if v=$(git --version 2>/dev/null); then doc_line ok "$v"; else doc_line FAIL "git not found"; fail=1; fi
  if v=$(tmux -V 2>/dev/null); then
    if awk '{ split($2, n, /[^0-9]+/); exit !(n[1] > 3 || (n[1] == 3 && n[2] >= 2)) }' <<<"$v"; then
      doc_line ok "$v"
    else
      doc_line FAIL "$v (need 3.2+ for popups and new-session -e)"
      fail=1
    fi
  else
    doc_line FAIL "tmux not found"
    fail=1
  fi
  if command -v fzf >/dev/null; then doc_line ok "fzf $(fzf --version | cut -d' ' -f1)"; else doc_line warn "fzf not found (dash, go without an id)"; fi
  if command -v lazygit >/dev/null; then doc_line ok "lazygit"; else doc_line warn "lazygit not found (menu: lazygit)"; fi

  echo "agents:"
  for a in "$PLUGIN_DIR"/agents/*.sh; do
    a=${a##*/}
    a=${a%.sh}
    if command -v "$a" >/dev/null; then
      doc_line ok "$a $("$a" --version 2>/dev/null | head -n 1)"
      [ "$a" != codex ] || doc_line note "codex: trust collie's hooks once via /hooks"
    else
      doc_line - "$a not installed"
    fi
  done
  a=${COLLIE_AGENT:-$(tmux_opt @collie-agent)}
  a=${a:-claude}
  if command -v "$a" >/dev/null; then doc_line ok "default agent: $a"; else doc_line FAIL "default agent '$a' not found"; fail=1; fi

  echo "tasks:"
  for d in "$TASKS_DIR"/*; do
    [ -f "$d/TASK.md" ] || continue
    fm_get "$d/TASK.md" status
    case $FM in done | archived) continue ;; esac
    id=${d##*/}
    while IFS=$TAB read -r name c b p; do
      if [ ! -d "$p" ]; then
        doc_line FAIL "$id: $name worktree missing: $p"
        fail=1
      elif ! git --git-dir="$c" worktree list --porcelain | grep -qxF "worktree $p"; then
        doc_line FAIL "$id: $name worktree not registered with git: $p"
        fail=1
      elif [ ! -L "$p/.collie" ]; then
        doc_line warn "$id: $name has no .collie link"
      fi
    done <"$d/repos.tsv"
    task_runs "$id" | awk -F'\t' -v id="$id" '$3 == "unknown" { print "  warn  " id ": run " $1 " (" $2 ") state unknown (session gone)" }'
  done
  return "$fail"
}

doc_line() { printf '  %-4s  %s\n' "$1" "$2"; }

cmd_repos() {
  discover
  printf '%s' "$REPOS"
}

cmd_workspaces() {
  local file="$CONFIG_DIR/workspaces"
  [ -f "$file" ] || return 0
  awk '/^[[:space:]]*(#|$)/ { next } { n = index($0, ":"); v = substr($0, n + 1); sub(/^[[:space:]]+/, "", v); print substr($0, 1, n - 1) "\t" v }' "$file"
}
