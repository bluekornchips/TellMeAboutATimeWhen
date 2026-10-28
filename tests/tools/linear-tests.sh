#!/usr/bin/env bats
#
# Test suite for tools/linear.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/linear.sh" || return 1
	if [[ ! -f "${HELPER}" ]]; then
		echo "setup:: Helper not found: ${HELPER}" >&2
		return 1
	fi

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
	bats_source_libs "${SCRIPT}"
	export REPO_PATH
	LINEAR_API_KEY="test-linear-key"
	export LINEAR_API_KEY
	mock_linear_success

	return 0
}

issue_json() {
	local issue_id="${1:-PROJ-123}"

	jq -n --arg id "${issue_id}" '{
		data: {
			issue: {
				identifier: $id,
				title: "Test Ticket",
				description: "Body",
				url: "https://linear.app/team/issue/\($id)",
				state: { name: "In Progress" },
				assignee: { name: "Test User" },
				comments: {
					nodes: [
						{
							body: "Comment 1",
							createdAt: "2025-01-20T00:00:00.000Z",
							user: { name: "User A" }
						},
						{
							body: "Comment 2",
							createdAt: "2025-01-21T00:00:00.000Z",
							user: { name: "User B" }
						}
					]
				}
			}
		}
	}'
}

# shellcheck disable=SC2329
mock_linear_success() {
	linear_graphql_request() {
		local query="${1:-}"
		local variables_json="${2:-{}}"

		if [[ "${query}" == *"viewer"* ]]; then
			echo '{"data":{"viewer":{"id":"user-1"}}}'
			return 0
		fi

		local issue_id
		issue_id=$(echo "${variables_json}" | jq -r '.id // empty')
		if [[ -z "${issue_id}" ]]; then
			return 1
		fi

		issue_json "${issue_id}"
		return 0
	}
}

# shellcheck disable=SC2329
mock_linear_auth_failure() {
	linear_graphql_request() {
		echo '{"errors":[{"message":"Authentication required"}]}'
		return 0
	}
}

# shellcheck disable=SC2329
mock_linear_issue_failure() {
	linear_graphql_request() {
		local query="${1:-}"

		if [[ "${query}" == *"viewer"* ]]; then
			echo '{"data":{"viewer":{"id":"user-1"}}}'
			return 0
		fi

		echo '{"data":{"issue":null}}'
		return 0
	}
}

# shellcheck disable=SC2329
mock_linear_empty_comments() {
	linear_graphql_request() {
		local query="${1:-}"
		local variables_json="${2:-{}}"

		if [[ "${query}" == *"viewer"* ]]; then
			echo '{"data":{"viewer":{"id":"user-1"}}}'
			return 0
		fi

		local issue_id
		issue_id=$(echo "${variables_json}" | jq -r '.id // empty')
		jq -n --arg id "${issue_id}" '{
			data: {
				issue: {
					identifier: $id,
					title: "Test Ticket",
					description: "Body",
					url: "https://linear.app/team/issue/\($id)",
					state: { name: "In Progress" },
					assignee: null,
					comments: { nodes: [] }
				}
			}
		}'
		return 0
	}
}

# check_linear_dependencies
@test "check_linear_dependencies:: fails when curl is not installed" {
	command() {
		if [[ "$1" == "-v" && "$2" == "curl" ]]; then
			return 1
		fi
		builtin command "$@"
	}

	run check_linear_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "curl is required"

	unset -f command
}

@test "check_linear_dependencies:: fails when jq is not installed" {
	command() {
		if [[ "$1" == "-v" && "$2" == "jq" ]]; then
			return 1
		fi
		builtin command "$@"
	}

	run check_linear_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "jq is required"

	unset -f command
}

@test "check_linear_dependencies:: succeeds when curl and jq are available" {
	run check_linear_dependencies
	[[ "$status" -eq 0 ]]
}

# get_issue_details_for_id
@test "get_issue_details_for_id:: fails when issue_id is not set" {
	run get_issue_details_for_id ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "issue_id is not set"
}

@test "get_issue_details_for_id:: outputs issue details and comments" {
	run get_issue_details_for_id "PROJ-123"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Issue: PROJ-123"
	echo "$output" | grep -q "Title: Test Ticket"
	echo "$output" | grep -q "Comment 1"
}

@test "get_issue_details_for_id:: fails when the issue is missing" {
	unset -f linear_graphql_request
	mock_linear_issue_failure
	run get_issue_details_for_id "PROJ-123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to retrieve issue details"
}

@test "get_issue_details_for_id:: succeeds when comments are empty" {
	unset -f linear_graphql_request
	mock_linear_empty_comments
	run get_issue_details_for_id "PROJ-123"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Issue: PROJ-123"
	echo "$output" | grep -q "Comments:"
	echo "$output" | grep -q "(none)"
}

# write_linear_details
@test "write_linear_details:: fails when commit is not set" {
	local linear_file="${TEST_DIR}/output/linear.txt"
	mkdir -p "$(dirname "${linear_file}")"

	run write_linear_details "" "${linear_file}"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or linear_file is not set"
}

@test "write_linear_details:: fails when linear_file is not set" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)

	run write_linear_details "${commit}" ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or linear_file is not set"
}

@test "write_linear_details:: fails when commit directory does not exist" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local linear_file="${TEST_DIR}/nonexistent/linear.txt"

	run write_linear_details "${commit}" "${linear_file}"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Commit directory does not exist"
}

@test "write_linear_details:: writes issue details to file" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test ticket" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""
	local linear_file="${TEST_DIR}/output/linear.txt"
	mkdir -p "$(dirname "${linear_file}")"

	run write_linear_details "${commit}" "${linear_file}"
	[[ "$status" -eq 0 ]]
	[[ -f "${linear_file}" ]]
	grep -q "Issue: PROJ-123" "${linear_file}"
}

@test "write_linear_details:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_worktree_repo "${test_repo1}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-111: First repo" >/dev/null 2>&1
	create_worktree_repo "${test_repo2}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-222: Second repo" >/dev/null 2>&1

	local commit
	commit=$(git -C "${test_repo2}" rev-parse HEAD)
	REPO_PATH="${test_repo2}"
	local linear_file="${TEST_DIR}/output/linear.txt"
	mkdir -p "$(dirname "${linear_file}")"

	run write_linear_details "${commit}" "${linear_file}"
	[[ "$status" -eq 0 ]]
	[[ -f "${linear_file}" ]]
	grep -q "Issue: PROJ-222" "${linear_file}"
	! grep -q "PROJ-111" "${linear_file}"
}

@test "write_linear_details:: returns success when no issues found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No issue here" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local linear_file="${TEST_DIR}/output/linear.txt"
	mkdir -p "$(dirname "${linear_file}")"

	run write_linear_details "${commit}" "${linear_file}"
	[[ "$status" -eq 0 ]]
	[[ ! -f "${linear_file}" ]]
}

# validate_linear_auth
@test "validate_linear_auth:: succeeds when the viewer query returns an id" {
	run validate_linear_auth
	[[ "$status" -eq 0 ]]
}

@test "validate_linear_auth:: fails when LINEAR_API_KEY is missing" {
	unset LINEAR_API_KEY
	run validate_linear_auth
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "LINEAR_API_KEY is not set"
	echo "$output" | grep -q "linear.app/settings/account/security"
}

@test "validate_linear_auth:: fails when authentication check fails" {
	unset -f linear_graphql_request
	mock_linear_auth_failure
	run validate_linear_auth
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Linear GraphQL authentication failed"
}

@test "linear_graphql_request:: fails when query is not set" {
	unset -f linear_graphql_request
	# shellcheck disable=SC1090
	source "${SCRIPT}"

	run linear_graphql_request ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "query is not set"
}

@test "integration:: rejects direct script execution" {
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	run assert_rejects_direct_execution "${SCRIPT}"
	[[ "$status" -eq 0 ]]
}
