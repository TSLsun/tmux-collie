#!/usr/bin/env bash
# Counts the processes bin/collie starts across the bats suite (or the given
# .bats files), per test and per function. Not part of `make test`: the shims
# make the suite several times slower.
#
#   test/spawns.sh [-k] [bats files...]    (-k: keep the logs, print their dir)
#
# How: every external command goes through a PATH shim that logs its pid when
# its parent is a collie process; collie itself runs under xtrace (via
# BASH_ENV, xtrace fd needs bash 4.1+) with the pid in PS4, so forks that
# never exec (subshells, $(func), builtin pipeline stages) show up as pids
# with no exec. processes = execs + those forks. sleep is not shimmed: tests
# symlink `command -v sleep` as a stand-in agent. Each collie invocation's own
# pid is not counted (the caller started it).
set -euo pipefail

keep=0
[ "${1:-}" != -k ] || { keep=1; shift; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -gt 0 ] || set -- "$root"/test/*.bats
bash=$(command -v bash)
"$bash" -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]' || {
  echo "spawns.sh: needs bash 5 as 'bash' on PATH (xtrace fd)" >&2
  exit 1
}

out=$(mktemp -d "${TMPDIR:-/tmp}/collie-spawns.XXXXXX")
shim="$out/shim"
mkdir -p "$shim" "$out/log"

cat >"$out/shim.sh" <<'EOF'
#!/bin/sh
n=${0##*/}
case $(/bin/ps -o args= -p "$PPID") in
  *bin/collie*) echo "x $$ $n" >>"$SPAWN_LOG/${BATS_TEST_FILENAME##*/}:${BATS_TEST_NUMBER:-0}" ;;
esac
# search only behind the shim dir: a test's stub dir sits in front of it and
# its stub execs `command -v tmux` (this shim) again, which would loop
IFS=:
past=0
for d in $PATH; do
  if [ "$past" = 1 ]; then
    [ -x "$d/$n" ] && exec "$d/$n" "$@"
  elif [ "$d" = "$SPAWN_SHIM" ]; then
    past=1
  fi
done
echo "shim: $n: not found" >&2
exit 127
EOF
chmod +x "$out/shim.sh"
for c in git tmux awk sed cut grep head tail sort paste tr wc date basename \
  dirname mkdir mv rm rmdir ln cat ps seq fzf bash sh less env \
  terminal-notifier osascript notify-send; do
  ln -s "$out/shim.sh" "$shim/$c"
done

# only collie scripts trace: hooks, fake agents and the shims stay quiet
cat >"$out/bash_env" <<'EOF'
case $0 in
  */bin/collie)
    exec {__spawn_fd}>>"$SPAWN_LOG/${BATS_TEST_FILENAME##*/}:${BATS_TEST_NUMBER:-0}"
    echo "m $$ $1" >&$__spawn_fd
    BASH_XTRACEFD=$__spawn_fd
    PS4='+ $BASHPID ${FUNCNAME[0]:-main} '
    set -x
    ;;
esac
EOF

PATH="$shim:$PATH" SPAWN_SHIM="$shim" SPAWN_LOG="$out/log" BASH_ENV="$out/bash_env" \
  COLLIE_BASH="$bash" bats "$@" >"$out/bats.out" 2>&1 || {
  tail -n 20 "$out/bats.out" >&2
  echo "spawns.sh: bats failed (logs in $out)" >&2
  exit 1
}

# per log: mains (m), execs (x), traced commands (+ pid function command).
# A traced pid that is neither a main nor an exec is a fork that stayed bash.
# Offenders: traced external commands by function, forks by their first
# traced function (execs of the shimmed names counted as traced, so their sum
# can differ a little from the exec total).
awk -v ext="$(ls "$shim" | tr '\n' ' ')" '
  BEGIN { n = split(ext, e, " "); for (i = 1; i <= n; i++) isext[e[i]] = 1 }
  FNR == 1 { t = FILENAME; sub(/.*\//, "", t); tests[t] = 1 }
  $1 == "m" { main[t, $2] = 1; next }
  $1 == "x" { ex[t, $2] = 1; nx[t]++; next }
  /^\++ [0-9]+ / {
    if (!((t, $2) in first)) { first[t, $2] = $3; pids[++np] = t SUBSEP $2 }
    if ($4 in isext) by[$3 " " $4]++
  }
  END {
    for (i = 1; i <= np; i++) {
      split(pids[i], k, SUBSEP)
      if ((k[1], k[2]) in main || (k[1], k[2]) in ex) continue
      nf[k[1]]++; by[first[k[1], k[2]] " (fork)"]++
    }
    for (t in tests) {
      x += nx[t]; f += nf[t]; nt++
      printf "%s\t%d\n", t, nx[t] + nf[t] > "/dev/stderr"
    }
    printf "total %d processes (%d execs, %d forks) in %d tests\n", x + f, x, f, nt
    for (b in by) printf "%7d  %s\n", by[b], b | "sort -rn | head -n 25"
  }
' "$out"/log/* 2>"$out/per-test.tsv"

if [ "$keep" -eq 1 ]; then echo "logs: $out"; else rm -rf "$out"; fi
