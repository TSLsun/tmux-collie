.PHONY: test lint check

# tests mostly wait on tmux/git, so run more jobs than cores; needs GNU parallel
JOBS ?= $(if $(shell command -v parallel),8,1)

test:
	bats --print-output-on-failure --jobs $(JOBS) test/

lint:
	shellcheck -x bin/collie collie.tmux agents/*.sh hooks/pre-push hooks/tmux-guard test/helper.bash test/tmux_diagnostics.bash
	# lib files share globals: one sets a variable another reads
	shellcheck -x -e SC2034,SC2153 lib/*.sh lib/cmd/*.sh
	zsh -n completions/_collie

check: lint test
