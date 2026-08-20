# Bats
TEST_FILES   := $(shell find . -name '*-tests.sh' -type f ! -path './.git/*')
BATS_JOBS    ?= $(shell nproc 2>/dev/null || echo 4)
BATS_COMMAND := bats --timing --verbose-run --formatter pretty --jobs $(BATS_JOBS) --no-parallelize-within-files

test: $(TEST_FILES)
	$(BATS_COMMAND) $(TEST_FILES)

lint:
	find . -name "*.sh" -type f -exec shellcheck {} +

install:
	find . -name "*.sh" -type f -exec chmod 744 {} \;
