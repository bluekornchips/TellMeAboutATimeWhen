#!/usr/bin/env bats
#
# Test suite for tell-me-about.sh
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	if [[ -z "$GIT_ROOT" ]]; then
		echo "Failed to get git root" >&2
		return 1
	fi

	SCRIPT="$GIT_ROOT/tell-me-about.sh"
	if [[ ! -f "$SCRIPT" ]]; then
		echo "Script not found: $SCRIPT" >&2
		return 1
	fi

	export GIT_ROOT
	export SCRIPT

	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	export TEST_DIR

	trap 'rm -rf "$TEST_DIR"' EXIT

	# Source the script to make functions available for unit testing
	# shellcheck disable=SC1090
	set +e
	source "$SCRIPT" || true
	set +e

	# Reset global variables that may be set by functions
	unset PERIOD_START PERIOD_END
	OUTPUT_DIR="${TEST_DIR}/output"
	export OUTPUT_DIR

	return 0
}

teardown() {
	return 0
}

# Creates a test git repository with multiple commits and authors for testing
# Uses worktrees
create_test_repo() {
	local repo_dir="$1"
	local bare_repo
	local worktree_path

	bare_repo="${TEST_DIR}/bare_repo.git"
	worktree_path="${repo_dir}"

	git init --bare "${bare_repo}" >/dev/null 2>&1
	git -C "${bare_repo}" worktree add "${worktree_path}" >/dev/null 2>&1
	cd "${worktree_path}" || return 1

	git config user.name "Test User"
	git config user.email "test@example.com"

	echo "test file" >test.txt
	git add test.txt
	git commit -m "Initial commit" >/dev/null 2>&1

	local default_branch
	default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")
	if [[ "$default_branch" != "master" ]]; then
		git branch -m master >/dev/null 2>&1 || true
	fi

	# Create commits with different authors to test author filtering
	echo "change by author1" >>test.txt
	git add test.txt
	GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
		git commit --author="Author One <author1@example.com>" -m "Commit by author1" >/dev/null 2>&1

	echo "change by author2" >>test.txt
	git add test.txt
	GIT_COMMITTER_NAME="Author Two" GIT_COMMITTER_EMAIL="author2@example.com" \
		git commit --author="Author Two <author2@example.com>" -m "Commit by author2" >/dev/null 2>&1

	# Create test-branch for branch testing
	git checkout -b test-branch >/dev/null 2>&1
	echo "branch change" >>test.txt
	git add test.txt
	git commit -m "Branch commit" >/dev/null 2>&1

	local default_branch
	default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")
	git checkout "$default_branch" >/dev/null 2>&1

	return 0
}

########################################################
# Unit Tests
########################################################

@test "unit:: shows help correctly" {
	run "$SCRIPT" --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
	echo "$output" | grep -q "Options:"
	echo "$output" | grep -q "\\-\\-range"
}

@test "unit:: fails with unknown option" {
	run "$SCRIPT" --unknown-option
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Unknown option"
}

@test "unit:: fails with missing required arguments" {
	run "$SCRIPT"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Missing required arguments"
}

@test "unit:: fails with invalid repository path" {
	run "$SCRIPT" -p "/nonexistent/path" -b "master" -a "test@example.com"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Invalid repository path"
}

@test "unit:: fails when using --range option twice" {
	run "$SCRIPT" -p "/tmp" -b "master" -a "test@example.com" --range "2025-01-01" --range "2025-06-01"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "main:: --range option can only be used once"
}

@test "unit:: fails with invalid date format in --range" {
	local bare_repo="${TEST_DIR}/date_test_bare.git"
	local test_repo="${TEST_DIR}/date_test_repo"

	git init --bare "${bare_repo}" >/dev/null 2>&1
	git -C "${bare_repo}" worktree add "${test_repo}" >/dev/null 2>&1

	cd "${test_repo}" || return 1
	git config user.name "Test User"
	git config user.email "test@example.com"
	echo "test" >file.txt
	git add file.txt
	git commit -m "Initial commit" >/dev/null 2>&1

	local default_branch
	default_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")
	if [[ "$default_branch" != "master" ]]; then
		git branch -m master >/dev/null 2>&1 || true
	fi

	run "$SCRIPT" -p "$test_repo" -b "master" -a "Test User" --range "invalid-date"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "determine_period_dates:: Failed to parse date"
}

# parse_date
@test "parse_date:: parses valid ISO date format" {
	local result
	result=$(parse_date "2026-01-19")
	[[ "$result" == "2026-01-19" ]]
}

@test "parse_date:: parses valid ISO date format with different date" {
	local result
	result=$(parse_date "2025-12-31")
	[[ "$result" == "2025-12-31" ]]
}

@test "parse_date:: handles relative date '1 week ago'" {
	local result
	result=$(parse_date "1 week ago")
	[[ -n "$result" ]]
	[[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "parse_date:: fails with invalid date format" {
	run parse_date "invalid-date"
	[[ "$status" -ne 0 ]]
}

@test "parse_date:: fails with empty string" {
	run parse_date ""
	[[ "$status" -ne 0 ]]
}

@test "parse_date:: fails with malformed ISO date" {
	run parse_date "2026-13-45"
	[[ "$status" -ne 0 ]]
}

@test "parse_date:: fails with wrong date format" {
	run parse_date "01/19/2026"
	[[ "$status" -ne 0 ]]
}

# determine_period_dates
@test "determine_period_dates:: sets PERIOD_START and PERIOD_END with two dates" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2="2026-01-23"
	determine_period_dates
	[[ "$PERIOD_START" == "2026-01-19" ]]
	[[ "$PERIOD_END" == "2026-01-23" ]]
}

@test "determine_period_dates:: sets PERIOD_START and PERIOD_END with single date" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2=""
	determine_period_dates
	[[ "$PERIOD_START" == "2026-01-19" ]]
	[[ -n "$PERIOD_END" ]]
	[[ "$PERIOD_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "determine_period_dates:: sets PERIOD_START and PERIOD_END with no dates" {
	RANGE_DATE1=""
	RANGE_DATE2=""
	determine_period_dates
	[[ -n "$PERIOD_START" ]]
	[[ "$PERIOD_START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
	[[ -n "$PERIOD_END" ]]
	[[ "$PERIOD_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "determine_period_dates:: fails with invalid first date" {
	RANGE_DATE1="invalid-date"
	RANGE_DATE2="2026-01-23"
	run determine_period_dates
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "determine_period_dates:: Failed to parse date"
}

@test "determine_period_dates:: fails with invalid second date" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2="invalid-date"
	run determine_period_dates
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "determine_period_dates:: Failed to parse date"
}

@test "determine_period_dates:: fails with invalid single date" {
	RANGE_DATE1="invalid-date"
	RANGE_DATE2=""
	run determine_period_dates
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "determine_period_dates:: Failed to parse date"
}

########################################################
# Integration Tests
########################################################

@test "integration:: basic commit analysis works" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One"

	if [[ "$status" -ne 0 ]]; then
		echo "Script failed: $output" >&3
	fi
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit:"

	# Verify output directory and commit directory created
	local repo_name
	repo_name=$(basename "$TEST_DIR")
	local base_dir="${OUTPUT_DIR}/${repo_name}"
	local output_dir="$base_dir/master/author_one"
	[[ -d "$output_dir" ]]

	# Find commit directory (hash is unpredictable)
	shopt -s nullglob
	local commit_dirs=("$output_dir"/*)
	shopt -u nullglob
	[[ ${#commit_dirs[@]} -eq 1 ]]
	[[ -d "${commit_dirs[0]}" ]]
	[[ -f "${commit_dirs[0]}/diff.txt" ]]
	grep -q "Commit by author1" "${commit_dirs[0]}/diff.txt"

}

@test "integration:: handles time range parameter" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "1 week ago"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit:"
}

@test "integration:: handles different branch" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "test-branch" -a "Test User"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit:"
}

@test "integration:: handles author not found" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "NonExistent Author"

	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "not found in the commit history"
}

@test "integration:: output includes commit details and diffs" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One"

	[[ "$status" -eq 0 ]]

	local repo_name
	repo_name=$(basename "$TEST_DIR")
	local base_dir="${OUTPUT_DIR}/${repo_name}"
	local output_dir="$base_dir/master/author_one"
	[[ -d "$output_dir" ]]

	shopt -s nullglob
	local commit_dirs=("$output_dir"/*)
	shopt -u nullglob
	[[ ${#commit_dirs[@]} -eq 1 ]]
	[[ -d "${commit_dirs[0]}" ]]
	[[ -f "${commit_dirs[0]}/diff.txt" ]]

	grep -q "Commit by author1" "${commit_dirs[0]}/diff.txt"

}

@test "integration:: --range flag works with date range" {
	create_test_repo "$TEST_DIR"

	# Wide date range should include all commits
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "2020-01-01" "2030-12-31"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit:"

	local repo_name
	repo_name=$(basename "$TEST_DIR")
	local base_dir="${OUTPUT_DIR}/${repo_name}"
	local output_dir="$base_dir/master/author_one"
	[[ -d "$output_dir" ]]

	shopt -s nullglob
	local commit_dirs=("$output_dir"/*)
	shopt -u nullglob
	[[ ${#commit_dirs[@]} -eq 1 ]]
	[[ -d "${commit_dirs[0]}" ]]
	[[ -f "${commit_dirs[0]}/diff.txt" ]]
	grep -q "Commit by author1" "${commit_dirs[0]}/diff.txt"

}

@test "integration:: --range flag works with single date" {
	create_test_repo "$TEST_DIR"

	# Single date should be treated as --since, from that date to now
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "1 week ago"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit:"
}

@test "integration:: --range flag filters commits correctly" {
	create_test_repo "$TEST_DIR"

	# Narrow date range from 2000-2001 should exclude all test commits
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "2000-01-01" "2001-12-31"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "No commits found"
}

@test "integration:: branch name sanitization" {
	create_test_repo "$TEST_DIR"

	# Create branch with special characters to test sanitization
	(
		cd "$TEST_DIR"
		git checkout -b "feature/my-feature" >/dev/null 2>&1
		echo "feature commit" >>test.txt
		git add test.txt
		GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
			git commit --author="Author One <author1@example.com>" -m "Feature commit" >/dev/null 2>&1
	)

	run "$SCRIPT" -p "$TEST_DIR" -b "feature/my-feature" -a "Author One"

	[[ "$status" -eq 0 ]]

	# Verify slashes in branch name are sanitized to underscores in directory name
	local repo_name
	repo_name=$(basename "$TEST_DIR")
	local output_dir="${OUTPUT_DIR}/${repo_name}/feature_my-feature/author_one"
	[[ -d "$output_dir" ]]

}
