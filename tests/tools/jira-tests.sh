#!/usr/bin/env bats
#
# Test suite for tools/jira.sh
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	SCRIPT="${GIT_ROOT}/tools/jira.sh"
	# shellcheck source=tools/jira.sh
	if [[ ! -f "$SCRIPT" ]]; then
		echo "setup:: Script not found: $SCRIPT" >&2
		return 1
	fi
	export GIT_ROOT
	export SCRIPT
	return 0
}

setup() {
	# shellcheck source=tools/jira.sh
	# Temporarily disable exit on error to prevent script from exiting when sourced
	set +e
	source "$SCRIPT" || true
	set -e

	TEST_DIR=$(mktemp -d)
	export TEST_DIR
	trap 'rm -rf "$TEST_DIR"' EXIT

	# Set default TICKET_ID for tests that need it
	TICKET_ID="PROJ-123"
	export TICKET_ID
	export REPO_PATH
	export COMMIT

	return 0
}

teardown() {
	return 0
}

# Helper function to create a test repo using worktree
create_test_repo_worktree() {
	local repo_dir="$1"
	local bare_repo
	bare_repo="${TEST_DIR}/bare_$(basename "$repo_dir").git"

	git init --bare "${bare_repo}" >/dev/null 2>&1
	git -C "${bare_repo}" worktree add "${repo_dir}" >/dev/null 2>&1

	cd "${repo_dir}" || return 1
	git config user.name "Test User"
	git config user.email "test@example.com"

	return 0
}

# Mock helpers for acli command
# shellcheck disable=SC2329
mock_acli_success() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			local ticket_id="$4"
			echo "Ticket: $ticket_id"
			echo "Summary: Test Ticket"
			echo "Status: In Progress"
			echo "Assignee: Test User"
			return 0
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "comment" && "$4" == "list" && "$5" == "--key" ]]; then
			echo "Comment 1 by User A on 2025-01-20"
			echo "Comment 2 by User B on 2025-01-21"
			return 0
		elif [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
			return 0
		fi
		return 1
	}
}

# shellcheck disable=SC2329
mock_acli_auth_failure() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			return 1
		fi
		return 1
	}
}

# shellcheck disable=SC2329
mock_acli_view_failure() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
			return 0
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			return 1
		fi
		return 1
	}
}

# shellcheck disable=SC2329
mock_acli_comment_failure() {
	acli() {
		if [[ "$1" == "jira" && "$2" == "auth" && "$3" == "status" ]]; then
			echo "Authenticated as test@example.com"
			return 0
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "view" ]]; then
			local ticket_id="$4"
			echo "Ticket: $ticket_id"
			echo "Summary: Test Ticket"
			return 0
		elif [[ "$1" == "jira" && "$2" == "workitem" && "$3" == "comment" && "$4" == "list" && "$5" == "--key" ]]; then
			return 1
		fi
		return 1
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

# git_cmd
@test "git_cmd:: uses current directory when REPO_PATH is not set" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"

	REPO_PATH=""
	run git_cmd rev-parse --git-dir
	[[ "$status" -eq 0 ]]
}

@test "git_cmd:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_test_repo_worktree "$test_repo1"
	create_test_repo_worktree "$test_repo2"

	REPO_PATH="$test_repo2"
	run git_cmd rev-parse --git-dir
	[[ "$status" -eq 0 ]]
	local repo2_git_dir
	repo2_git_dir=$(git -C "$test_repo2" rev-parse --git-dir)
	[[ "$output" == "$repo2_git_dir" ]]
}

# resolve_remote_owner_repo
@test "resolve_remote_owner_repo:: extracts owner and name from HTTPS URL" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	local owner
	local name
	owner=$(echo "$output" | head -n 1)
	name=$(echo "$output" | tail -n 1)
	[[ "$owner" == "owner" ]]
	[[ "$name" == "repo" ]]
}

@test "resolve_remote_owner_repo:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_test_repo_worktree "$test_repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	create_test_repo_worktree "$test_repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	REPO_PATH="$test_repo2"
	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	local owner
	local name
	owner=$(echo "$output" | head -n 1)
	name=$(echo "$output" | tail -n 1)
	[[ "$owner" == "owner2" ]]
	[[ "$name" == "repo2" ]]
}

# extract_jira_tickets
@test "extract_jira_tickets:: fails when commit is not set" {
	COMMIT=""
	run extract_jira_tickets
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit is not set"
}

@test "extract_jira_tickets:: returns empty when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	[[ -z "$output" ]]
}

@test "extract_jira_tickets:: extracts single ticket ID" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Fix bug" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-123"
}

@test "extract_jira_tickets:: extracts multiple unique ticket IDs" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Fix bug. Also see PROJ-456 and PROJ-123 again" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-123"
	echo "$output" | grep -q "PROJ-456"
	local ticket_count
	ticket_count=$(echo "$output" | wc -l)
	[[ "${ticket_count}" -eq 2 ]]
}

@test "extract_jira_tickets:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_test_repo_worktree "$test_repo1"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-111: First repo" >/dev/null 2>&1
	create_test_repo_worktree "$test_repo2"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-222: Second repo" >/dev/null 2>&1

	COMMIT=$(git -C "$test_repo2" rev-parse HEAD)
	REPO_PATH="$test_repo2"

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-222"
	echo "$output" | grep -v -q "PROJ-111"
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

# write_jira_details
@test "write_jira_details:: fails when commit is not set" {
	local output_path="${TEST_DIR}/output"
	mkdir -p "$output_path"

	COMMIT=""
	run write_jira_details "$output_path"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or output_path is not set"
}

@test "write_jira_details:: fails when output_path is not set" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)

	run write_jira_details ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or output_path is not set"
}

@test "write_jira_details:: fails when output_path does not exist" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	local output_path="${TEST_DIR}/nonexistent"

	run write_jira_details "$output_path"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Output path does not exist"
}

@test "write_jira_details:: writes ticket details to file" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test ticket" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""
	local output_path="${TEST_DIR}/output"
	mkdir -p "$output_path"

	run write_jira_details "$output_path"
	[[ "$status" -eq 0 ]]
	[[ -f "${output_path}/PROJ-123.txt" ]]
	grep -q "Ticket: PROJ-123" "${output_path}/PROJ-123.txt"
}

@test "write_jira_details:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_test_repo_worktree "$test_repo1"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-111: First repo" >/dev/null 2>&1
	create_test_repo_worktree "$test_repo2"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-222: Second repo" >/dev/null 2>&1

	COMMIT=$(git -C "$test_repo2" rev-parse HEAD)
	REPO_PATH="$test_repo2"
	local output_path="${TEST_DIR}/output"
	mkdir -p "$output_path"

	run write_jira_details "$output_path"
	[[ "$status" -eq 0 ]]
	[[ -f "${output_path}/PROJ-222.txt" ]]
	grep -q "Ticket: PROJ-222" "${output_path}/PROJ-222.txt"
	[[ ! -f "${output_path}/PROJ-111.txt" ]]
}

@test "write_jira_details:: returns success when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	local output_path="${TEST_DIR}/output"
	mkdir -p "$output_path"

	run write_jira_details "$output_path"
	[[ "$status" -eq 0 ]]
	[[ ! -f "${output_path}/PROJ-123.txt" ]]
}

# validate_git_repo
@test "validate_git_repo:: fails when not in git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$no_repo_dir"

	REPO_PATH=""
	run validate_git_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not a git repository"
}

@test "validate_git_repo:: succeeds when in git repository" {
	local test_repo="${TEST_DIR}/test_repo"
	create_test_repo_worktree "$test_repo"

	REPO_PATH=""
	run validate_git_repo
	[[ "$status" -eq 0 ]]
}

@test "validate_git_repo:: uses REPO_PATH when set" {
	local test_repo1="${TEST_DIR}/repo1"
	local test_repo2="${TEST_DIR}/repo2"
	create_test_repo_worktree "$test_repo1"
	create_test_repo_worktree "$test_repo2"

	REPO_PATH="$test_repo2"
	run validate_git_repo
	[[ "$status" -eq 0 ]]
}

@test "validate_git_repo:: fails when REPO_PATH is not a git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$TEST_DIR"

	REPO_PATH="$no_repo_dir"
	run validate_git_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not a git repository: ${no_repo_dir}"
}

# validate_required_args
@test "validate_required_args:: fails with missing ticket id" {
	TICKET_ID=""
	run validate_required_args
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "validate_required_args:: succeeds with ticket id" {
	run validate_required_args "PROJ-123"
	[[ "$status" -eq 0 ]]
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

# get_ticket_details
@test "get_ticket_details:: outputs raw ticket details and comments" {
	run get_ticket_details
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Ticket: PROJ-123"
	echo "$output" | grep -q "Summary: Test Ticket"
	echo "$output" | grep -q "Comment 1 by User A"
}

@test "get_ticket_details:: fails when first acli workitem view call fails" {
	unset -f acli
	mock_acli_view_failure
	run get_ticket_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to retrieve ticket details"
}

@test "get_ticket_details:: warns but succeeds when comment list call fails" {
	unset -f acli
	mock_acli_comment_failure
	run get_ticket_details
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Ticket: PROJ-123"
	echo "$output" | grep -q "Failed to retrieve comments"
}

# jira_main
@test "jira_main:: shows help correctly" {
	run jira_main --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
}

@test "jira_main:: fails with missing ticket id" {
	TICKET_ID=""
	run jira_main
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "jira_main:: handles unknown options as second argument" {
	run jira_main "PROJ-123" --unknown-option
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
	TICKET_ID=""
	run "$SCRIPT"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}
