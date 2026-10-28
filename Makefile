TEST_FILES   := $(shell find . -name '*-tests.sh' -type f ! -path './.git/*')
SHELL_FILES  := $(shell find . -name '*.sh' -type f ! -path './.git/*' ! -name '*-tests.sh')
BATS_JOBS    ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)
BATS_COMMAND := bats --timing --verbose-run --formatter pretty --jobs $(BATS_JOBS) --no-parallelize-within-files

.PHONY: test shellcheck install syntax

.DEFAULT_GOAL := ci

test:
	@TERM="$${TERM:-xterm}" $(BATS_COMMAND) $(TEST_FILES)

syntax:
	@bash -n $(SHELL_FILES)

shellcheck:
	@shellcheck $(SHELL_FILES)

install:
	@find . -name '*.sh' -type f ! -path './.git/*' -exec chmod 744 {} \;

ci: syntax shellcheck test
