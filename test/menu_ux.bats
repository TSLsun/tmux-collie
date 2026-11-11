#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo
  cd "$REPO/main"
}
teardown() { teardown_env; }

stub_tmux() {
  mkdir -p "$TMP/stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$TMP/stub/tmux"
  chmod +x "$TMP/stub/tmux"
}

@test "menu: to-do, next and back are global; peek appears only in task sessions" {
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu main cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"to-do"$'\n'"i"$'\n'*"_popup "*"collie todo"* ]]
  [[ "$output" == *"next for you"$'\n'"n"$'\n'"run-shell '"*"collie next -c cl'"* ]]
  [[ "$output" == *"back to last session"$'\n'"l"$'\n'"switch-client -l"* ]]
  [[ "$output" != *$'\n'"peek task"$'\n'* ]]

  collie new x -r proj --no-window
  PATH="$TMP/stub:$PATH" run collie _menu x cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"to-do"$'\n'"i"$'\n'*"_popup "*"collie todo"* ]]
  [[ "$output" == *"next for you"$'\n'"n"$'\n'"run-shell '"*"collie next -c cl'"* ]]
  [[ "$output" == *"back to last session"$'\n'"l"$'\n'"switch-client -l"* ]]
  [[ "$output" == *"peek task"$'\n'"p"$'\n'*"_popup -w"*"peek x"* ]]
}

@test "menu: the to-do popup opens and says when nothing waits" {
  export LESS=FRX TERM=xterm-256color
  tmux new-session -d -s main -x 100 -y 30
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  python3 - <<'PY'
import fcntl, os, pty, select, struct, subprocess, termios, time

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
client = subprocess.Popen(["tmux", "attach-session", "-t", "main"],
                          stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
try:
    def receive(until, timeout=10):
        data = b""
        end = time.monotonic() + timeout
        while until not in data and time.monotonic() < end:
            if select.select([master], [], [], 0.2)[0]:
                data += os.read(master, 65536)
        return data

    receive(b"main")
    os.write(master, b"\x02h")
    receive(b"to-do")
    os.write(master, b"i")
    output = receive(b"nothing waits on you")
    assert b"nothing waits on you" in output, output
    os.write(master, b"\x1b")
finally:
    client.kill()
    client.wait()
    os.close(master)
PY
}
