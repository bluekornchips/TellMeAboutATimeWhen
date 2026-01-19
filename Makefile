test:
	@if command -v bats >/dev/null 2>&1; then \
		clear && bats --verbose-run --timing \
		tests/tell-me-about-tests.sh tests/tools/check-github-tests.sh; \
	else \
		echo "Error: bats is not installed. Install it with:"; \
		echo "  brew install bats-core  # macOS"; \
		echo "  sudo apt-get install bats  # Ubuntu/Debian"; \
		exit 1; \
	fi

install:
	chmod +x tell-me-about.sh tests/tell-me-about-tests.sh
	@echo "Scripts are now executable"
