#!/usr/bin/env bats
#
# Test suite for tools/github.sh
#

GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
SCRIPT="${GIT_ROOT}/tools/github.sh"
# shellcheck source=tools/github.sh
[[ ! -f "$SCRIPT" ]] && echo "setup:: Script not found: $SCRIPT" >&2 && return 1

setup_file() {
	return 0
}

setup() {
	# shellcheck source=tools/github.sh
	source "$SCRIPT"

	TEST_DIR=$(mktemp -d)
	export TEST_DIR

	trap 'rm -rf "$TEST_DIR"' EXIT ERR

	return 0
}

teardown() {
	[[ -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	return 0
}

create_test_repo() {
	local repo_dir="$1"

	cd "$repo_dir" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"

	echo "test file" >test.txt
	git add test.txt
	git commit -m "Initial commit" >/dev/null 2>&1

	return 0
}

# validate_required_args
@test "validate_required_args:: fails with missing commit hash" {
	run validate_required_args ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "validate_required_args:: succeeds with commit hash" {
	run validate_required_args "abc123"
	[[ "$status" -eq 0 ]]
}

# validate_git_repo
@test "validate_git_repo:: fails when not in git repository" {
	cd "$TEST_DIR"
	rm -rf .git 2>/dev/null || true

	run validate_git_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not in a git repository"
}

@test "validate_git_repo:: succeeds when in git repository" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run validate_git_repo
	[[ "$status" -eq 0 ]]
}

# validate_commit_exists
@test "validate_commit_exists:: fails with invalid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run validate_commit_exists "nonexistent123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "not found in git history"
}

@test "validate_commit_exists:: succeeds with valid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	local commit_hash
	commit_hash=$(git rev-parse HEAD)

	run validate_commit_exists "$commit_hash"
	[[ "$status" -eq 0 ]]
}

# main
@test "main:: shows help correctly" {
	run main --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
}

@test "main:: fails with missing commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run main
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "main:: fails when not in git repository" {
	cd "$TEST_DIR"
	rm -rf .git 2>/dev/null || true

	run main "abc123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not in a git repository"
}

@test "main:: fails with invalid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run main "nonexistent123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "not found in git history"
}

@test "main:: handles unknown options as second argument" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	local commit_hash
	commit_hash=$(git rev-parse HEAD)

	run main "$commit_hash" --unknown-option
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Unknown option"
}

# Integration tests
@test "integration:: script execution with help flag" {
	run "$SCRIPT" --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
}

@test "integration:: script execution fails without arguments" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run "$SCRIPT"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}
