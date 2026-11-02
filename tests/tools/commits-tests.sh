#!/usr/bin/env bats
#
# Test suite for tools/lib/commits.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/lib/commits.sh" || return 1
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
	unset PERIOD_START PERIOD_END RANGE_DATE1 RANGE_DATE2 AUTHOR BRANCH REPO_PATH
	unset SANITIZED_AUTHOR SANITIZED_BRANCH
	COMMITS=()

	return 0
}

@test "parse_date:: parses valid ISO date format" {
	local result
	result=$(parse_date "2026-01-19")
	[[ "${result}" == "2026-01-19" ]]
}

@test "parse_date:: parses valid ISO date format with different date" {
	local result
	result=$(parse_date "2025-12-31")
	[[ "${result}" == "2025-12-31" ]]
}

@test "parse_date:: fails with relative date '1 week ago'" {
	run parse_date "1 week ago"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Invalid date format"
}

@test "parse_date:: fails with invalid date format" {
	run parse_date "invalid-date"
	[[ "${status}" -ne 0 ]]
}

@test "parse_date:: fails with empty string" {
	run parse_date ""
	[[ "${status}" -ne 0 ]]
}

@test "parse_date:: fails with malformed ISO date" {
	run parse_date "2026-13-45"
	[[ "${status}" -ne 0 ]]
}

@test "parse_date:: fails with wrong date format" {
	run parse_date "01/19/2026"
	[[ "${status}" -ne 0 ]]
}

@test "determine_period_dates:: sets PERIOD_START and PERIOD_END with two dates" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2="2026-01-23"
	determine_period_dates
	[[ "${PERIOD_START}" == "2026-01-19" ]]
	[[ "${PERIOD_END}" == "2026-01-23" ]]
}

@test "determine_period_dates:: sets PERIOD_START and PERIOD_END with single date" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2=""
	determine_period_dates
	[[ "${PERIOD_START}" == "2026-01-19" ]]
	[[ -n "${PERIOD_END}" ]]
	[[ "${PERIOD_END}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "determine_period_dates:: fails with no dates" {
	RANGE_DATE1=""
	RANGE_DATE2=""
	run determine_period_dates
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: --range requires at least one date"
}

@test "determine_period_dates:: fails with invalid first date" {
	RANGE_DATE1="invalid-date"
	RANGE_DATE2="2026-01-23"
	run determine_period_dates
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: Failed to parse"
}

@test "determine_period_dates:: fails with invalid second date" {
	RANGE_DATE1="2026-01-19"
	RANGE_DATE2="invalid-date"
	run determine_period_dates
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: Failed to parse"
}

@test "determine_period_dates:: fails with invalid single date" {
	RANGE_DATE1="invalid-date"
	RANGE_DATE2=""
	run determine_period_dates
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: Failed to parse"
}

@test "determine_period_dates:: fails when start is after end" {
	RANGE_DATE1="2026-02-01"
	RANGE_DATE2="2026-01-01"
	run determine_period_dates
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "is after end date"
}

@test "sanitize_names:: lowercases author and replaces slashes in branch" {
	sanitize_names "Author One" "feature/my-feature"
	[[ "${SANITIZED_AUTHOR}" == "author_one" ]]
	[[ "${SANITIZED_BRANCH}" == "feature_my-feature" ]]
}

@test "sanitize_names:: fails when author is empty" {
	run sanitize_names "" "main"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "author or branch is not set"
}

@test "get_commits:: selects commits by author" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	BRANCH="master"
	AUTHOR="Author One"
	PERIOD_START="2020-01-01"
	PERIOD_END="2030-12-31"

	get_commits
	[[ "${#COMMITS[@]}" -eq 1 ]]
}

@test "append_unique_commit:: deduplicates hashes" {
	COMMITS=()
	append_unique_commit "abc"
	append_unique_commit "abc"
	append_unique_commit "def"
	[[ "${#COMMITS[@]}" -eq 2 ]]
	[[ "${COMMITS[0]}" == "abc" ]]
	[[ "${COMMITS[1]}" == "def" ]]
}

@test "write_commit_details:: writes message and files when missing" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	local out_file="${TEST_DIR}/diff.txt"
	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%H -n 1)

	write_commit_details "${sha}" "${out_file}"
	[[ -s "${out_file}" ]]
	grep -q "Commit by author1" "${out_file}"
}
