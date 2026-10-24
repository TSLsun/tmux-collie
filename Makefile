.PHONY: test lint check

test:
	bats test/

lint:
	shellcheck -x bin/collie collie.tmux agents/*.sh test/helper.bash

check: lint test
