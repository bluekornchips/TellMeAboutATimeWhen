#!/usr/bin/env bats
#
# Test suite for tools/jira.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/jira.sh" || return 1
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

	return 0
}

# Mock helpers for acli command
# shellcheck disable=SC2329
mock_acli_success() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			local ticket_id="$4"
			echo "Ticket: ${ticket_id}"
			echo "Summary: Test Ticket"
			echo "Status: In Progress"
			echo "Assignee: Test User"
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "comment" && "$4" == "list" && "$5" == "--key" ]]; then
			echo "Comment 1 by User A on 2025-01-20"
			echo "Comment 2 by User B on 2025-01-21"
		elif [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
		else
			return 1
		fi

		return 0
	}
}

# shellcheck disable=SC2329
mock_acli_auth_failure() {
	acli() {
		if [[ "$1" == "jira" ]]; then
			return 1
		fi

		return 0
	}
}

# shellcheck disable=SC2329
mock_acli_view_failure() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			return 1
		else
			return 1
		fi

		return 0
	}
}

# shellcheck disable=SC2329
mock_acli_comment_failure() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			local ticket_id="$4"
			echo "Ticket: ${ticket_id}"
			echo "Summary: Test Ticket"
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "comment" && "$4" == "list" && "$5" == "--key" ]]; then
			return 1
		else
			return 1
		fi

		return 0
	}
}

# Default mock for most tests
mock_acli_success

# check_jira_dependencies
@test "check_jira_dependencies:: fails when acli is not installed" {
	command() {
		if [[ "$1" == "-v" && "$2" == "acli" ]]; then
			return 1
		fi
		command "$@"
	}

	run check_jira_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Atlassian CLI.*not installed"

	unset -f command
}

@test "check_jira_dependencies:: succeeds when acli is available" {
	run check_jira_dependencies
	[[ "$status" -eq 0 ]]
}

# get_ticket_details_for_id
@test "get_ticket_details_for_id:: fails when ticket_id is not set" {
	run get_ticket_details_for_id ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "ticket_id is not set"
}

@test "get_ticket_details_for_id:: outputs ticket details" {
	run get_ticket_details_for_id "PROJ-123"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Ticket: PROJ-123"
	echo "$output" | grep -q "Summary: Test Ticket"
}

@test "get_ticket_details_for_id:: fails when acli view fails" {
	unset -f acli
	mock_acli_view_failure
	run get_ticket_details_for_id "PROJ-123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to retrieve ticket details"
}

@test "get_ticket_details_for_id:: warns but succeeds when comment list call fails" {
	unset -f acli
	mock_acli_comment_failure
	run get_ticket_details_for_id "PROJ-123"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Ticket: PROJ-123"
	echo "$output" | grep -q "Failed to retrieve comments"
}

# write_jira_details
@test "write_jira_details:: fails when commit is not set" {
	local jira_file="${TEST_DIR}/output/jira.txt"
	mkdir -p "$(dirname "${jira_file}")"

	run write_jira_details "" "${jira_file}"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or jira_file is not set"
}

@test "write_jira_details:: fails when jira_file is not set" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)

	run write_jira_details "${commit}" ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or jira_file is not set"
}

@test "write_jira_details:: fails when commit directory does not exist" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local jira_file="${TEST_DIR}/nonexistent/jira.txt"

	run write_jira_details "${commit}" "${jira_file}"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Commit directory does not exist"
}

@test "write_jira_details:: writes ticket details to file" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test ticket" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""
	local jira_file="${TEST_DIR}/output/jira.txt"
	mkdir -p "$(dirname "${jira_file}")"

	run write_jira_details "${commit}" "${jira_file}"
	[[ "$status" -eq 0 ]]
	[[ -f "${jira_file}" ]]
	grep -q "Ticket: PROJ-123" "${jira_file}"
}

@test "write_jira_details:: uses REPO_PATH when set" {
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
	local jira_file="${TEST_DIR}/output/jira.txt"
	mkdir -p "$(dirname "${jira_file}")"

	run write_jira_details "${commit}" "${jira_file}"
	[[ "$status" -eq 0 ]]
	[[ -f "${jira_file}" ]]
	grep -q "Ticket: PROJ-222" "${jira_file}"
	! grep -q "PROJ-111" "${jira_file}"
}

@test "write_jira_details:: returns success when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local jira_file="${TEST_DIR}/output/jira.txt"
	mkdir -p "$(dirname "${jira_file}")"

	run write_jira_details "${commit}" "${jira_file}"
	[[ "$status" -eq 0 ]]
	[[ ! -f "${jira_file}" ]]
}

# validate_jira_auth
@test "validate_jira_auth:: succeeds when acli jira auth status works" {
	run validate_jira_auth
	[[ "$status" -eq 0 ]]
}

@test "validate_jira_auth:: fails when authentication check fails" {
	unset -f acli
	mock_acli_auth_failure
	run validate_jira_auth
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Atlassian CLI is not authenticated"
	echo "$output" | grep -q "acli jira auth login"
}

@test "integration:: rejects direct script execution" {
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	run assert_rejects_direct_execution "${SCRIPT}"
	[[ "$status" -eq 0 ]]
}
