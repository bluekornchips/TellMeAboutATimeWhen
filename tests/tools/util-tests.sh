#!/usr/bin/env bats
#
# Test suite for tools/lib/util.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/lib/util.sh" || return 1
	# shellcheck disable=SC1090
	source "${HELPER}"
	init_shared_fixtures || return 1

	return 0
}

setup() {
	TEST_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
	export TEST_DIR
	cd "${GIT_ROOT}" || return 1
	# shellcheck disable=SC1090
	source "${HELPER}"
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	bats_source_libs
	export REPO_PATH

	return 0
}

@test "require_cmd:: fails when command is missing" {
	run require_cmd "definitely-missing-cmd-$$"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "is required but is not installed"
}

@test "require_cmd:: succeeds when command exists" {
	run require_cmd "bash"
	[[ "$status" -eq 0 ]]
}

@test "array_contains:: finds and misses values" {
	run array_contains "b" "a" "b" "c"
	[[ "$status" -eq 0 ]]

	run array_contains "z" "a" "b" "c"
	[[ "$status" -eq 1 ]]
}
