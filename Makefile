.PHONY: test lint check

# Retain the existing worker setting; measured tradeoffs are in docs/TESTING.md.
# Parallel runs require GNU parallel; JOBS remains overridable.
JOBS ?= $(if $(shell command -v parallel),8,1)

test:
	BATS_TEST_TIMEOUT=120 bats --timing --print-output-on-failure --jobs $(JOBS) test/

lint:
	shellcheck -x bin/collie collie.tmux agents/*.sh hooks/pre-push hooks/tmux-guard test/helper.bash test/tmux_diagnostics.bash
	# lib files share globals: one sets a variable another reads
	shellcheck -x -e SC2034,SC2153 lib/*.sh lib/cmd/*.sh
	zsh -n completions/_collie

check: lint test
