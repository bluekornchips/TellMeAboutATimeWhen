test:
	clear && bats --verbose-run --timing \
	tests/tell-me-about-tests.sh \
	tests/tools/github-tests.sh \
	tests/tools/jira-tests.sh;

lint:
	find . -name "*.sh" -type f | xargs shellcheck

install:
	find . -type f -executable -exec chmod 744 {} \;
	@echo "Scripts are now executable"
