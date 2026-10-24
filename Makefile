.PHONY: test lint check

test:
	bats test/

lint:
	shellcheck -x bin/collie collie.tmux agents/*.sh hooks/pre-push test/helper.bash
	zsh -n completions/_collie

check: lint test
