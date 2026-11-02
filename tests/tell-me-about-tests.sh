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

	unset PERIOD_START PERIOD_END RANGE_DATE1 RANGE_DATE2 AUTHOR BRANCH REPO_PATH
	unset CHECK_GITHUB CHECK_JIRA CHECK_LINEAR CHECK_COWORKER SANITIZED_AUTHOR SANITIZED_BRANCH
	unset GITHUB_USER FAILED_TOOLS TOOLS INPUT_HELP
	FAILED_TOOLS=()
	print_init
	COMMITS=()
	REPOS=()
	TOOLS=""
	INPUT_HELP=0
	OUTPUT_DIR="${TEST_DIR}/output"
	export OUTPUT_DIR
	TELLME_CONFIG="${TEST_DIR}/no-such-tell-me-about.json"
	export TELLME_CONFIG
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

@test "usage:: shows help correctly" {
	run "${SCRIPT}" --help
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Usage:"
	echo "${output}" | grep -q "Options:"
	echo "${output}" | grep -q "\\-\\-range"
	echo "${output}" | grep -q "Non-interactive stdin skips failed tools"
	echo "${output}" | grep -q "\\-\\-tools"
	echo "${output}" | grep -q "\\-\\-github-user"
	echo "${output}" | grep -q "tell-me-about.json"
}

@test "main:: fails with unknown option" {
	run "${SCRIPT}" --unknown-option
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option"
}

@test "main:: rejects removed --repo, -a, -t, and -ghu flags" {
	run "${SCRIPT}" --repo "/tmp:master" --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option '--repo'"

	run "${SCRIPT}" -a "Test User" --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option '-a'"

	run "${SCRIPT}" -t coworker --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option '-t'"

	run "${SCRIPT}" -ghu octocat --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "Unknown option '-ghu'"
}

@test "main:: fails when --tools has no value" {
	run "${SCRIPT}" --tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "\\-\\-tools requires"
}

@test "main:: fails with missing required arguments" {
	run "${SCRIPT}"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "process_input:: --range is required"
}

@test "main:: fails when --range is not provided" {
	write_tellme_config "Test User" "${TEST_DIR}/range_repo:master"

	run "${SCRIPT}" --tools coworker
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "process_input:: --range is required"
}

@test "main:: fails when tell-me-about.json is absent" {
	TELLME_CONFIG="${TEST_DIR}/no-such-tell-me-about.json"
	export TELLME_CONFIG

	run "${SCRIPT}" --range "2025-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "load_tellme_config:: config file is required"
}

@test "validate_repo:: fails with invalid repository path" {
	REPO_PATH="/nonexistent/path"
	AUTHOR="testuser"

	run validate_repo
	[[ "${status}" -eq 1 ]]
	echo "${output}" | grep -q "Invalid repository path"
}

@test "validate_enabled_tools:: rejects a non-username author when github is enabled" {
	write_tellme_config "Test User" "/nonexistent/path:master"

	run "${SCRIPT}" --range "2025-01-01" --tools github
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q -- "--github-user is required"
}

@test "validate_enabled_tools:: accepts --github-user with a display-name author" {
	CHECK_JIRA="false"
	CHECK_LINEAR="false"
	CHECK_GITHUB="true"
	CHECK_COWORKER="false"
	AUTHOR="Test User"
	GITHUB_USER="octocat"

	check_github_dependencies() { return 0; }

	validate_enabled_tools
	[[ "${GITHUB_USER}" == "octocat" ]]
}

@test "main:: fails when using --range option twice" {
	write_tellme_config "test@example.com" "/tmp:master"

	run "${SCRIPT}" --range "2025-01-01" --range "2025-06-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "process_input:: --range option can only be used once"
}

@test "main:: rejects reversed --range dates" {
	create_worktree_repo "${TEST_DIR}/range_repo"
	write_tellme_config "Test User" "${TEST_DIR}/range_repo:master"

	run "${SCRIPT}" --range "2026-02-01" "2026-01-01" --tools coworker
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "is after end date"
}

@test "validate_enabled_tools:: succeeds when enabled tools pass checks" {
	CHECK_JIRA="true"
	CHECK_LINEAR="true"
	CHECK_GITHUB="true"
	CHECK_COWORKER="true"

	check_jira_dependencies() { return 0; }
	validate_jira_auth() { return 0; }
	check_linear_dependencies() { return 0; }
	validate_linear_auth() { return 0; }
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
	CHECK_LINEAR="false"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	check_jira_dependencies() {
		echo "check_jira_dependencies:: should not run" >&2
		return 1
	}
	check_linear_dependencies() {
		echo "check_linear_dependencies:: should not run" >&2
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
	CHECK_LINEAR="false"
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

@test "validate_enabled_tools:: fails when linear dependencies are missing" {
	CHECK_JIRA="false"
	CHECK_LINEAR="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	check_linear_dependencies() {
		echo "check_linear_dependencies:: curl is required but is not installed" >&2
		return 1
	}
	validate_linear_auth() { return 0; }

	run validate_enabled_tools
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "curl is required but is not installed"
}

@test "validate_enabled_tools:: fails when github is not authenticated" {
	CHECK_JIRA="false"
	CHECK_LINEAR="false"
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
	CHECK_LINEAR="false"
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
	write_tellme_config "Test User" "${TEST_DIR}/date_test_repo:master"

	run "${SCRIPT}" --range "invalid-date" --tools coworker
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "determine_period_dates:: Failed to parse"
}

@test "apply_repo:: splits on last colon" {
	apply_repo "/Volumes/My:Drive/repo:main"
	[[ "${REPO_PATH}" == "/Volumes/My:Drive/repo" ]]
	[[ "${BRANCH}" == "main" ]]
}

@test "integration:: writes commit diffs for a date range" {
	create_analyzer_repo "${TEST_DIR}/repo"
	write_tellme_config "Author One" "${TEST_DIR}/repo:master"

	run "${SCRIPT}" --range "2020-01-01" "2030-12-31"
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

@test "integration:: handles different branch and author miss" {
	create_analyzer_repo "${TEST_DIR}/repo"
	write_tellme_config "Test User" "${TEST_DIR}/repo:test-branch"

	run "${SCRIPT}" --range "2020-01-01"
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Commit:"

	write_tellme_config "NonExistent Author" "${TEST_DIR}/repo:master"
	run "${SCRIPT}" --range "2020-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "not found in the commit history"
}

@test "integration:: --range filters empty windows and sanitizes branch dirs" {
	create_analyzer_repo "${TEST_DIR}/repo"
	write_tellme_config "Author One" "${TEST_DIR}/repo:master"

	run "${SCRIPT}" --range "2000-01-01" "2001-12-31"
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "(0 commits)"

	(
		cd "${TEST_DIR}/repo"
		git checkout -b "feature/my-feature" >/dev/null 2>&1
		echo "feature commit" >>test.txt
		git add test.txt
		GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
			git commit --author="Author One <author1@example.com>" -m "Feature commit" >/dev/null 2>&1
	)
	write_tellme_config "Author One" "${TEST_DIR}/repo:feature/my-feature"
	run "${SCRIPT}" --range "2020-01-01" --tools coworker
	[[ "${status}" -eq 0 ]]
	[[ -d "${OUTPUT_DIR}/repo/feature_my-feature/author_one" ]]
}

@test "integration:: analyzes multiple repositories from config" {
	create_analyzer_repo "${TEST_DIR}/repo-one"
	create_analyzer_repo "${TEST_DIR}/repo-two"
	write_tellme_config "Author One" \
		"${TEST_DIR}/repo-one:master" \
		"${TEST_DIR}/repo-two:master"

	run "${SCRIPT}" --range "2020-01-01"

	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "=== ${TEST_DIR}/repo-one:master (1 commit) ==="
	echo "${output}" | grep -q "=== ${TEST_DIR}/repo-two:master (1 commit) ==="
	grep -q "Commit by author1" "${OUTPUT_DIR}/repo-one/master/author_one/"*/diff.txt
	grep -q "Commit by author1" "${OUTPUT_DIR}/repo-two/master/author_one/"*/diff.txt
	[[ -d "${OUTPUT_DIR}/repo-one/master/author_one/meetings" ]]
	[[ -d "${OUTPUT_DIR}/repo-two/master/author_one/meetings" ]]
	local meetings_cards
	meetings_cards=$(echo "${output}" | grep -c "Meetings:" || true)
	[[ "${meetings_cards}" -eq 2 ]]
	echo "${output}" | grep -q "repo-one/master/author_one/meetings"
	echo "${output}" | grep -q "repo-two/master/author_one/meetings"
}

@test "integration:: continues after one repo fails" {
	create_analyzer_repo "${TEST_DIR}/repo-two"
	write_tellme_config "Author One" \
		"/nonexistent/path:master" \
		"${TEST_DIR}/repo-two:master"

	run "${SCRIPT}" --range "2020-01-01"

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
	CHECK_LINEAR="false"
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
	CHECK_LINEAR="false"
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
	CHECK_LINEAR="false"
	CHECK_COWORKER="false"

	write_involvement_prs() {
		printf 'called\n' >"${called_file}"
		return 0
	}

	run process_repo "${TEST_DIR}/repo:master"
	[[ "${status}" -eq 0 ]]
	[[ ! -f "${called_file}" ]]
}

@test "process_repo:: writes meetings stub when coworker is enabled" {
	create_analyzer_repo "${TEST_DIR}/repo"
	AUTHOR="Author One"
	BRANCH="master"
	PERIOD_START="2020-01-01"
	PERIOD_END="2030-01-01"
	CHECK_GITHUB="false"
	CHECK_JIRA="false"
	CHECK_LINEAR="false"
	CHECK_COWORKER="true"

	run process_repo "${TEST_DIR}/repo:master"
	[[ "${status}" -eq 0 ]]
	[[ -d "${OUTPUT_DIR}/repo/master/author_one/meetings" ]]
	echo "${output}" | grep -q "meetings"
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
	CHECK_LINEAR="false"
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
	CHECK_LINEAR="false"
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

@test "process_commits:: invokes linear write helpers" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_JIRA="false"
	CHECK_LINEAR="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	write_linear_details() {
		local commit="$1"
		local linear_file="$2"
		printf '%s\n' 'Issue: PROJ-123' >"${linear_file}"
		return 0
	}

	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%h -n 1)
	COMMITS=("${sha}")

	run process_commits
	[[ "${status}" -eq 0 ]]
	[[ -s "${OUTPUT_PATH}/${sha}/linear.txt" ]]
	echo "${output}" | grep -q "Linear:"
}

@test "process_commits:: writes jira and linear artifacts together" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_JIRA="true"
	CHECK_LINEAR="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	write_jira_details() {
		local jira_file="$2"
		printf '%s\n' 'Ticket: PROJ-123' >"${jira_file}"
		return 0
	}
	write_linear_details() {
		local linear_file="$2"
		printf '%s\n' 'Issue: PROJ-123' >"${linear_file}"
		return 0
	}

	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%h -n 1)
	COMMITS=("${sha}")

	run process_commits
	[[ "${status}" -eq 0 ]]
	[[ -s "${OUTPUT_PATH}/${sha}/jira.txt" ]]
	[[ -s "${OUTPUT_PATH}/${sha}/linear.txt" ]]
	echo "${output}" | grep -q "Jira:"
	echo "${output}" | grep -q "Linear:"
}

@test "write_meetings_stub:: prints skill instructions for the analysis root" {
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"

	run write_meetings_stub "${OUTPUT_PATH}/meetings" "2026-08-01" "2026-08-07"
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

@test "configure_tools:: enables all tools by default" {
	configure_tools ""

	[[ "${CHECK_GITHUB}" == "true" ]]
	[[ "${CHECK_JIRA}" == "true" ]]
	[[ "${CHECK_LINEAR}" == "true" ]]
	[[ "${CHECK_COWORKER}" == "true" ]]
}

@test "configure_tools:: enables only selected tools" {
	configure_tools "jira,coworker"

	[[ "${CHECK_GITHUB}" == "false" ]]
	[[ "${CHECK_JIRA}" == "true" ]]
	[[ "${CHECK_LINEAR}" == "false" ]]
	[[ "${CHECK_COWORKER}" == "true" ]]
}

@test "configure_tools:: enables linear without jira" {
	configure_tools "linear,coworker"

	[[ "${CHECK_GITHUB}" == "false" ]]
	[[ "${CHECK_JIRA}" == "false" ]]
	[[ "${CHECK_LINEAR}" == "true" ]]
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

@test "validate_enabled_tools:: records failed tools for fail-open handling" {
	CHECK_JIRA="true"
	CHECK_LINEAR="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	check_jira_dependencies() {
		echo "check_jira_dependencies:: Atlassian CLI (acli) is not installed or not in PATH" >&2
		return 1
	}
	validate_jira_auth() { return 0; }
	check_linear_dependencies() { return 0; }
	validate_linear_auth() {
		echo "validate_linear_auth:: LINEAR_API_KEY is not set" >&2
		return 1
	}

	validate_enabled_tools || true
	[[ "${#FAILED_TOOLS[@]}" -eq 2 ]]
	[[ "${FAILED_TOOLS[0]}" == "jira" ]]
	[[ "${FAILED_TOOLS[1]}" == "linear" ]]
}

@test "disable_tools:: clears matching CHECK flags" {
	CHECK_JIRA="true"
	CHECK_LINEAR="true"
	CHECK_GITHUB="true"
	CHECK_COWORKER="true"

	run disable_tools jira linear
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "disabled jira"
	echo "${output}" | grep -q "disabled linear"

	disable_tools jira linear
	[[ "${CHECK_JIRA}" == "false" ]]
	[[ "${CHECK_LINEAR}" == "false" ]]
	[[ "${CHECK_GITHUB}" == "true" ]]
	[[ "${CHECK_COWORKER}" == "true" ]]
}

@test "disable_tools:: fails on unknown tool names" {
	run disable_tools nope
	[[ "${status}" -eq 1 ]]
	echo "${output}" | grep -q "Unknown tool"
}

@test "confirm_proceed_without_tools:: auto-proceeds on non-interactive stdin" {
	FAILED_TOOLS=("linear" "github")

	run confirm_proceed_without_tools
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Missing or invalid access for: linear,github"
	echo "${output}" | grep -q "proceeding without: linear,github"
}

@test "confirm_proceed_without_tools:: fails when FAILED_TOOLS is empty" {
	FAILED_TOOLS=()

	run confirm_proceed_without_tools
	[[ "${status}" -eq 1 ]]
	echo "${output}" | grep -q "no failed tools to confirm"
}

@test "process_input:: rejects missing, invalid, incomplete, and relative config" {
	TELLME_CONFIG="${TEST_DIR}/missing.json"
	export TELLME_CONFIG
	run process_input --range "2020-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "load_tellme_config:: config file is required"

	TELLME_CONFIG="${TEST_DIR}/bad.json"
	export TELLME_CONFIG
	cat <<'EOF' >"${TELLME_CONFIG}"
{"repos": [
EOF
	run process_input --range "2020-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "load_tellme_config::"

	TELLME_CONFIG="${TEST_DIR}/incomplete.json"
	export TELLME_CONFIG
	cat <<'EOF' >"${TELLME_CONFIG}"
{
  "repos": [
    {"path": "/repo-one", "branch": "main"},
    {"path": "/repo-two"}
  ]
}
EOF
	run process_input --range "2020-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "needs repos with path and branch"

	TELLME_CONFIG="${TEST_DIR}/relative.json"
	export TELLME_CONFIG
	cat <<'EOF' >"${TELLME_CONFIG}"
{
  "repos": [
    {"path": "repo-one", "branch": "main"}
  ]
}
EOF
	run process_input --range "2020-01-01"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "expand_repo_path:: path must resolve to an absolute POSIX path"
}

@test "process_input:: loads config, expands paths, and lets CLI win" {
	HOME="${TEST_DIR}/home"
	export HOME
	mkdir -p "${HOME}/from-tilde" "${TEST_DIR}/absolute-repo"

	TELLME_CONFIG="${TEST_DIR}/expand.json"
	export TELLME_CONFIG
	cat <<EOF >"${TELLME_CONFIG}"
{
  "author": "Config Author",
  "github_user": "configuser",
  "repos": [
    {"path": "${TEST_DIR}/absolute-repo", "branch": "master"},
    {"path": "~/from-tilde", "branch": "main"}
  ]
}
EOF
	unset AUTHOR GITHUB_USER
	TOOLS=""

	process_input --range "2020-01-01" --tools github --github-user overrideuser
	[[ "${#REPOS[@]}" -eq 2 ]]
	[[ "${REPOS[0]}" == "${TEST_DIR}/absolute-repo:master" ]]
	[[ "${REPOS[1]}" == "${HOME}/from-tilde:main" ]]
	[[ "${AUTHOR}" == "Config Author" ]]
	[[ "${TOOLS}" == "github" ]]
	[[ "${GITHUB_USER}" == "overrideuser" ]]
}

@test "process_commits:: disables github when enrichment fails" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_GITHUB="true"
	CHECK_JIRA="false"
	CHECK_LINEAR="false"
	CHECK_COWORKER="false"

	write_pr_details() {
		echo "write_pr_details:: boom" >&2
		return 1
	}

	local sha
	sha=$(git -C "${TEST_DIR}/repo" log --author="Author One" --format=%h -n 1)
	COMMITS=("${sha}")

	run process_commits
	[[ "${status}" -eq 0 ]]
	echo "${output}" | grep -q "Failed to write PR details"
	echo "${output}" | grep -q "disabling github"

	CHECK_GITHUB="true"
	process_commits
	[[ "${CHECK_GITHUB}" == "false" ]]
}

@test "process_commits:: disables linear after first mid-run failure" {
	create_analyzer_repo "${TEST_DIR}/repo"
	REPO_PATH="${TEST_DIR}/repo"
	OUTPUT_PATH="${TEST_DIR}/out"
	mkdir -p "${OUTPUT_PATH}"
	CHECK_JIRA="false"
	CHECK_LINEAR="true"
	CHECK_GITHUB="false"
	CHECK_COWORKER="false"

	local call_count_file="${TEST_DIR}/linear-calls"
	printf '0\n' >"${call_count_file}"
	write_linear_details() {
		local count
		count=$(cat "${call_count_file}")
		count=$((count + 1))
		printf '%s\n' "${count}" >"${call_count_file}"
		echo "write_linear_details:: boom" >&2
		return 1
	}

	local sha1
	local sha2
	sha1=$(git -C "${TEST_DIR}/repo" rev-parse --short HEAD)
	(
		cd "${TEST_DIR}/repo"
		printf 'second\n' >second.txt
		git add second.txt
		GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
			git commit --author="Author One <author1@example.com>" -m "second commit" >/dev/null 2>&1
	)
	sha2=$(git -C "${TEST_DIR}/repo" rev-parse --short HEAD)
	COMMITS=("${sha1}" "${sha2}")

	process_commits
	[[ "${CHECK_LINEAR}" == "false" ]]
	[[ "$(cat "${call_count_file}")" == "1" ]]
}
