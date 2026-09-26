#!/usr/bin/env bats
#
# Test suite for tell-me-about.sh
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	if [[ -z "${GIT_ROOT}" ]]; then
		echo "Failed to get git root" >&2
		return 1
	fi

	SCRIPT="${GIT_ROOT}/tell-me-about.sh"
	HELPER="${GIT_ROOT}/tests/helpers/repo.sh"
	if [[ ! -f "${SCRIPT}" ]]; then
		echo "Script not found: ${SCRIPT}" >&2
		return 1
	fi

	if [[ ! -f "${HELPER}" ]]; then
		echo "Helper not found: ${HELPER}" >&2
		return 1
	fi

	# shellcheck disable=SC1090
	source "${HELPER}"
	init_shared_fixtures || return 1

	export GIT_ROOT
	export SCRIPT
	export HELPER

	return 0
}

setup() {
	TEST_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
	export TEST_DIR
	cd "${GIT_ROOT}" || return 1

	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	bats_unset_load_guards

	# shellcheck disable=SC1090
	source "${HELPER}"
	source "${SCRIPT}" || true

	# Unit tests call helpers without main; load shared libs via _setup.
	_setup || return 1

	unset PERIOD_START PERIOD_END RANGE_DATE1 RANGE_DATE2 AUTHOR GITHUB_LOGIN BRANCH REPO_PATH
	unset CHECK_GITHUB CHECK_JIRA CHECK_COWORKER SANITIZED_AUTHOR SANITIZED_BRANCH
	print_init
	COMMITS=()
	OUTPUT_DIR="${TEST_DIR}/output"
	export OUTPUT_DIR
	COWORKER_MCP_CONFIG="${TEST_DIR}/mcp.json"
	cat <<'EOF' >"${COWORKER_MCP_CONFIG}"
{
  "mcpServers": {
    "coworker": {}
  }
}
EOF
	export COWORKER_MCP_CONFIG

	return 0
}

# usage
@test "usage:: shows help correctly" {
	run "${SCRIPT}" --help
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Usage:"
	echo "${output}" | grep -q "Options:"
	echo "${output}" | grep -q "\\-\\-range"
	echo "${output}" | grep -q "\\-\\-tools"
}

@test "main:: fails with unknown option" {
	run "${SCRIPT}" --unknown-option
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option"
}

@test "main:: rejects removed individual tool flags" {
	run "${SCRIPT}" --jira
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option '--jira'"
}

@test "main:: fails when --tools has no value" {
	run "${SCRIPT}" --tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "\\-\\-tools requires"
}

@test "main:: fails with missing required arguments" {
	run "${SCRIPT}"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "main:: --range is required"
}

@test "main:: fails when --range is not provided" {
	create_worktree_repo "${TEST_DIR}/range_repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/range_repo:master" -a "Test User"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "main:: --range is required"
}

@test "main:: fails when --repo is not provided" {
	run "${SCRIPT}" -a "Test User" --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "at least one --repo is required"
}

@test "main:: rejects removed -p and -b flags" {
	run "${SCRIPT}" -p "${TEST_DIR}/repo" -b "master" -a "Test User" --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option"
}

@test "validate_repo:: fails with invalid repository path" {
	REPO_PATH="/nonexistent/path"
	AUTHOR="testuser"

	run validate_repo
	[[ "${status}" -eq 1 ]]
	echo "${output}" | grep -q "Invalid repository path"
}

@test "validate_enabled_tools:: rejects a non-username author when github is enabled" {
	run "${SCRIPT}" --repo "/nonexistent/path:master" -a "Test User" --range "2025-01-01" --tools github
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "is not a GitHub username"
}

@test "main:: fails when using --range option twice" {
	run "${SCRIPT}" --repo "/tmp:master" -a "test@example.com" --range "2025-01-01" --range "2025-06-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "main:: --range option can only be used once"
}

# configure_tools
@test "configure_tools:: enables all tools by default" {
	configure_tools ""

	[[ "${CHECK_GITHUB}" == "true" ]]
	[[ "${CHECK_JIRA}" == "true" ]]
	[[ "${CHECK_COWORKER}" == "true" ]]
}

@test "configure_tools:: enables only selected tools" {
	configure_tools "jira,coworker"

	[[ "${CHECK_GITHUB}" == "false" ]]
	[[ "${CHECK_JIRA}" == "true" ]]
	[[ "${CHECK_COWORKER}" == "true" ]]
}

@test "configure_tools:: fails for an unknown tool" {
	run configure_tools "jira,gitlab"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown tool 'gitlab'"
}

@test "configure_tools:: fails for empty list entries" {
	run configure_tools "jira,,coworker"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Invalid tool list"
}

# validate_enabled_tools
@test "validate_enabled_tools:: succeeds when enabled tools pass checks" {
	CHECK_JIRA="true"
	CHECK_GITHUB="true"
	CHECK_COWORKER="true"

	check_jira_dependencies() { return 0; }
	validate_jira_auth() { return 0; }
	check_github_dependencies() { return 0; }
	check_coworker_dependencies() { return 0; }
	resolve_mcp_config() {
		echo "${COWORKER_MCP_CONFIG}"
		return 0
	}
	check_coworker_mcp() { return 0; }

	run validate_enabled_tools
	[[ "${status}" -eq 0 ]]
}

@test "validate_enabled_tools:: skips disabled tools" {
	CHECK_JIRA="false"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	check_jira_dependencies() {
		echo "check_jira_dependencies:: should not run" >&2
		return 1
	}
	check_github_dependencies() {
		echo "check_github_dependencies:: should not run" >&2
		return 1
	}
	check_coworker_dependencies() {
		echo "check_coworker_dependencies:: should not run" >&2
		return 1
	}

	run validate_enabled_tools
	[[ "${status}" -eq 0 ]]
	[[ -z "${output}" ]]
}

@test "validate_enabled_tools:: fails when jira dependencies are missing" {
	CHECK_JIRA="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	check_jira_dependencies() {
		echo "check_jira_dependencies:: Atlassian CLI (acli) is not installed or not in PATH" >&2
		return 1
	}
	validate_jira_auth() { return 0; }

	run validate_enabled_tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Atlassian CLI (acli) is not installed"
}

@test "validate_enabled_tools:: fails when github is not authenticated" {
	CHECK_JIRA="false"
	CHECK_GITHUB="true"
	CHECK_COWORKER="false"

	check_github_dependencies() {
		echo "check_github_dependencies:: GitHub CLI is not authenticated" >&2
		return 1
	}

	run validate_enabled_tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "GitHub CLI is not authenticated"
}

@test "validate_enabled_tools:: fails when coworker MCP is missing" {
	CHECK_JIRA="false"
	CHECK_GITHUB="false"
	CHECK_COWORKER="true"

	check_coworker_dependencies() { return 0; }
	resolve_mcp_config() {
		echo "${COWORKER_MCP_CONFIG}"
		return 0
	}
	check_coworker_mcp() {
		echo "check_coworker_mcp:: Coworker MCP is not configured" >&2
		return 1
	}

	run validate_enabled_tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Coworker MCP is not configured"
}

@test "determine_period_dates:: fails with invalid date format in --range" {
	create_worktree_repo "${TEST_DIR}/date_test_repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/date_test_repo:master" -a "Test User" --range "invalid-date" --tools coworker
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: Failed to parse"
}

# parse_date
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

# determine_period_dates
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

# sanitize_names
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

# apply_repo
@test "apply_repo:: splits on last colon" {
	apply_repo "/Volumes/My:Drive/repo:main"
	[[ "${REPO_PATH}" == "/Volumes/My:Drive/repo" ]]
	[[ "${BRANCH}" == "main" ]]
}

@test "apply_repo:: resolves TELLME_REPOS_ROOT" {
	TELLME_REPOS_ROOT="${TEST_DIR}/repos-root"
	mkdir -p "${TELLME_REPOS_ROOT}/repo-a"

	apply_repo "repo-a:master"
	[[ "${REPO_PATH}" == "${TELLME_REPOS_ROOT}/repo-a" ]]
	[[ "${BRANCH}" == "master" ]]
}

# get_commits
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

@test "get_commits:: matches merge commits by GITHUB_LOGIN when it differs from AUTHOR" {
	create_worktree_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	BRANCH="master"
	AUTHOR="author@example.com"
	GITHUB_LOGIN="octocat"
	PERIOD_START="2020-01-01"
	PERIOD_END="2030-12-31"

	git -C "${REPO_PATH}" checkout -b octocat-feature >/dev/null 2>&1
	echo "feature change" >>"${REPO_PATH}/test.txt"
	git -C "${REPO_PATH}" add test.txt
	git -C "${REPO_PATH}" commit -m "Feature commit" >/dev/null 2>&1
	git -C "${REPO_PATH}" checkout master >/dev/null 2>&1
	git -C "${REPO_PATH}" merge --no-ff -m "Merge pull request #1 from octocat/octocat-feature" octocat-feature >/dev/null 2>&1

	get_commits
	[[ "${#COMMITS[@]}" -eq 1 ]]
}

########################################################
# Integration Tests
########################################################

@test "integration:: basic commit analysis works" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2020-01-01" --tools coworker

	if [[ "${status}" -ne 0 ]]; then
		echo "Script failed: ${output}" >&3
	fi
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"

	local output_dir="${OUTPUT_DIR}/repo/master/author_one"
	[[ -d "${output_dir}" ]]

	shopt -s nullglob
	local commit_diffs=("${output_dir}"/*/diff.txt)
	shopt -u nullglob
	[[ ${#commit_diffs[@]} -eq 1 ]]
	grep -q "Commit by author1" "${commit_diffs[0]}"
}

@test "integration:: handles time range parameter" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2020-01-01" --tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"
}

@test "integration:: handles different branch" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:test-branch" -a "Test User" --range "2020-01-01" --tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"
}

@test "integration:: handles author not found" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "NonExistent Author" --range "2020-01-01" --tools coworker

	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "not found in the commit history"
}

@test "integration:: output includes commit details and diffs" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2020-01-01" --tools coworker

	[[ "${status}" -eq 0 ]]

	local output_dir="${OUTPUT_DIR}/repo/master/author_one"
	[[ -d "${output_dir}" ]]

	shopt -s nullglob
	local commit_diffs=("${output_dir}"/*/diff.txt)
	shopt -u nullglob
	[[ ${#commit_diffs[@]} -eq 1 ]]
	grep -q "Commit by author1" "${commit_diffs[0]}"
}

@test "integration:: --range flag works with date range" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2020-01-01" "2030-12-31" --tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"

	local output_dir="${OUTPUT_DIR}/repo/master/author_one"
	[[ -d "${output_dir}" ]]

	shopt -s nullglob
	local commit_diffs=("${output_dir}"/*/diff.txt)
	shopt -u nullglob
	[[ ${#commit_diffs[@]} -eq 1 ]]
	grep -q "Commit by author1" "${commit_diffs[0]}"
}

@test "integration:: --range flag works with single date" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2020-01-01" --tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"
}

@test "integration:: --range flag filters commits correctly" {
	create_analyzer_repo "${TEST_DIR}/repo"

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:master" -a "Author One" --range "2000-01-01" "2001-12-31" --tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "(0 commits)"
}

@test "integration:: branch name sanitization" {
	create_analyzer_repo "${TEST_DIR}/repo"

	(
		cd "${TEST_DIR}/repo"
		git checkout -b "feature/my-feature" >/dev/null 2>&1
		echo "feature commit" >>test.txt
		git add test.txt
		GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
			git commit --author="Author One <author1@example.com>" -m "Feature commit" >/dev/null 2>&1
	)

	run "${SCRIPT}" --repo "${TEST_DIR}/repo:feature/my-feature" -a "Author One" --range "2020-01-01" --tools coworker

	[[ "${status}" -eq 0 ]]

	local output_dir="${OUTPUT_DIR}/repo/feature_my-feature/author_one"
	[[ -d "${output_dir}" ]]
}

@test "integration:: --repo analyzes multiple repositories" {
	create_analyzer_repo "${TEST_DIR}/repo-one"
	create_analyzer_repo "${TEST_DIR}/repo-two"

	run "${SCRIPT}" \
		--repo "${TEST_DIR}/repo-one:master" \
		--repo "${TEST_DIR}/repo-two:master" \
		-a "Author One" \
		--range "2020-01-01" \
		--tools coworker

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "=== ${TEST_DIR}/repo-one:master (1 commit) ==="
	echo "${output}" | grep -q "=== ${TEST_DIR}/repo-two:master (1 commit) ==="
	grep -q "Commit by author1" "${OUTPUT_DIR}/repo-one/master/author_one/"*/diff.txt
	grep -q "Commit by author1" "${OUTPUT_DIR}/repo-two/master/author_one/"*/diff.txt
}

@test "integration:: continues after one repo fails" {
	create_analyzer_repo "${TEST_DIR}/repo-two"

	run "${SCRIPT}" \
		--repo "/nonexistent/path:master" \
		--repo "${TEST_DIR}/repo-two:master" \
		-a "Author One" \
		--range "2020-01-01" \
		--tools coworker

	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Invalid repository path"
	grep -q "Commit by author1" "${OUTPUT_DIR}/repo-two/master/author_one/"*/diff.txt
}

@test "process_commits:: invokes github write helpers" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_GITHUB="true"
	CHECK_JIRA="false"
	CHECK_COWORKER="false"

	write_pr_details() {
		local commit="$1"
		local pr_file="$2"
		printf '%s\n' '[]' >"${pr_file}"
		return 0
	}

	COMMITS=()
	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%h -n 1)
	COMMITS=("${sha}")

	run process_commits
	[[ "${status}" -eq 0 ]]
	[[ -f "${OUTPUT_PATH}/${sha}/pr.json" ]]
}

@test "process_involvement_prs:: writes indexes and prints per-role counts" {
	OUTPUT_PATH="${TEST_DIR}/out-prs"
	mkdir -p "${OUTPUT_PATH}"

	write_involvement_prs() {
		local root="$1"
		mkdir -p "${root}/prs/merged" "${root}/prs/reviewed" "${root}/prs/commented"
		printf '%s\n' '[]' >"${root}/prs/merged/index.json"
		printf '%s\n' '[{"number":1},{"number":2}]' >"${root}/prs/reviewed/index.json"
		printf '%s\n' '[{"number":1}]' >"${root}/prs/commented/index.json"
		return 0
	}

	run process_involvement_prs
	[[ "${status}" -eq 0 ]]
	[[ -f "${OUTPUT_PATH}/prs/merged/index.json" ]]
	echo "${output}" | grep -q "merged 0, reviewed 2, commented 1"
	echo "${output}" | grep -q "prs/reviewed/index.json"
	echo "${output}" | grep -q "prs/commented/index.json"
}

@test "process_repo:: invokes involvement helper when github enabled" {
	create_analyzer_repo "${TEST_DIR}/repo"
	local called_file="${TEST_DIR}/involvement-called"
	AUTHOR="Author One"
	BRANCH="master"
	PERIOD_START="2020-01-01"
	PERIOD_END="2030-01-01"
	CHECK_GITHUB="true"
	CHECK_JIRA="false"
	CHECK_COWORKER="false"

	write_pr_details() {
		local commit="$1"
		local pr_file="$2"
		printf '%s\n' '[]' >"${pr_file}"
		return 0
	}
	write_involvement_prs() {
		printf 'called\n' >"${called_file}"
		mkdir -p "${OUTPUT_PATH}/prs/merged" "${OUTPUT_PATH}/prs/reviewed" "${OUTPUT_PATH}/prs/commented"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/merged/index.json"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/reviewed/index.json"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/commented/index.json"
		return 0
	}

	run process_repo "${TEST_DIR}/repo:master"
	[[ "${status}" -eq 0 ]]
	[[ -f "${called_file}" ]]
}

@test "process_repo:: skips involvement helper when github disabled" {
	create_analyzer_repo "${TEST_DIR}/repo"
	local called_file="${TEST_DIR}/involvement-skipped"
	AUTHOR="Author One"
	BRANCH="master"
	PERIOD_START="2020-01-01"
	PERIOD_END="2030-01-01"
	CHECK_GITHUB="false"
	CHECK_JIRA="false"
	CHECK_COWORKER="false"

	write_involvement_prs() {
		printf 'called\n' >"${called_file}"
		return 0
	}

	run process_repo "${TEST_DIR}/repo:master"
	[[ "${status}" -eq 0 ]]
	[[ ! -f "${called_file}" ]]
}

@test "process_repo:: invokes involvement helper when commit list is empty" {
	create_analyzer_repo "${TEST_DIR}/repo"
	local called_file="${TEST_DIR}/involvement-empty-commits"
	AUTHOR="Author One"
	BRANCH="master"
	PERIOD_START="2099-01-01"
	PERIOD_END="2099-01-02"
	CHECK_GITHUB="true"
	CHECK_JIRA="false"
	CHECK_COWORKER="false"

	write_involvement_prs() {
		printf 'called\n' >"${called_file}"
		mkdir -p "${OUTPUT_PATH}/prs/merged" "${OUTPUT_PATH}/prs/reviewed" "${OUTPUT_PATH}/prs/commented"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/merged/index.json"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/reviewed/index.json"
		printf '%s\n' '[]' >"${OUTPUT_PATH}/prs/commented/index.json"
		return 0
	}

	run process_repo "${TEST_DIR}/repo:master"
	[[ "${status}" -eq 0 ]]
	[[ -f "${called_file}" ]]
	echo "${output}" | grep -q "(0 commits)"
}

@test "process_commits:: invokes jira write helpers" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_JIRA="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	write_jira_details() {
		local commit="$1"
		local jira_file="$2"
		printf '%s\n' 'Ticket: PROJ-123' >"${jira_file}"
		return 0
	}

	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%h -n 1)
	COMMITS=("${sha}")

	run process_commits
	[[ "${status}" -eq 0 ]]
	[[ -s "${OUTPUT_PATH}/${sha}/jira.txt" ]]
	echo "${output}" | grep -q "Jira:"
}

@test "process_meetings:: verifies coworker MCP and prints skill instructions" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	REPO_NAME="repo"
	AUTHOR="Author One"
	BRANCH="master"
	OUTPUT_PATH="${TEST_DIR}/out"
	PERIOD_START="2026-08-01"
	PERIOD_END="2026-08-07"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_COWORKER="true"

	check_coworker_dependencies() {
		return 0
	}
	resolve_mcp_config() {
		echo "${COWORKER_MCP_CONFIG}"
		return 0
	}
	check_coworker_mcp() {
		return 0
	}

	run process_meetings
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Meetings:.*${OUTPUT_PATH}/meetings"
	echo "${output}" | grep -q "Window:.*2026-08-01 to 2026-08-07"
	echo "${output}" | grep -q "Parent:.*tell-me-about-a-time-when"
	echo "${output}" | grep -q "Child:.*weekly-update"
	echo "${output}" | grep -q "one-one-one"
	echo "${output}" | grep -q "brag-book"
	echo "${output}" | grep -q "monthly-update"
	[[ -d "${OUTPUT_PATH}/meetings" ]]
}

@test "set_default_author:: keeps an explicit AUTHOR" {
	AUTHOR="Explicit Author"
	set_default_author
	[[ "${AUTHOR}" == "Explicit Author" ]]
}

@test "validate_repo:: sets REPO_NAME and rejects unknown authors" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	AUTHOR="Author One"
	COMMITS=()

	validate_repo
	[[ "${REPO_NAME}" == "repo" ]]

	AUTHOR="Nobody Here"
	run validate_repo
	[[ "${status}" -eq 1 ]]
	echo "${output}" | grep -q "not found in the commit history"
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
