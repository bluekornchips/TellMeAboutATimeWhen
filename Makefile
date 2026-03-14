# Bats
TEST_FILES := $(shell find tests -name '*-tests.sh' -type f)
BATS_COMMAND := bats --timing --verbose-run

test: $(TEST_FILES)
	clear && $(BATS_COMMAND) $(TEST_FILES)

lint:
	find . -name "*.sh" -type f -exec shellcheck {} +

install:
	find . -name "*.sh" -type f -exec chmod 744 {} \;
