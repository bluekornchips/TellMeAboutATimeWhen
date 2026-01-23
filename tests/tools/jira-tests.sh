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

	# Set default TICKET_ID for tests that need it
	TICKET_ID="PROJ-123"
	export TICKET_ID

	return 0
}

teardown() {
	rm -rf "$TEST_DIR"
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

# extract_jira_tickets
@test "extract_jira_tickets:: fails when commit is not set" {
	COMMIT=""
	run extract_jira_tickets
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit is not set"
}

@test "extract_jira_tickets:: returns empty when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	[[ -z "$output" ]]
}

@test "extract_jira_tickets:: extracts single ticket ID" {
	local test_repo="${TEST_DIR}/test_repo"
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Fix bug" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-123"
}

@test "extract_jira_tickets:: extracts multiple unique ticket IDs" {
	local test_repo="${TEST_DIR}/test_repo"
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Fix bug. Also see PROJ-456 and PROJ-123 again" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)

	run extract_jira_tickets
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-123"
	echo "$output" | grep -q "PROJ-456"
	local ticket_count
	ticket_count=$(echo "$output" | wc -l)
	[[ $ticket_count -eq 2 ]]
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
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
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
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
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
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test ticket" >/dev/null 2>&1

	COMMIT=$(git rev-parse HEAD)
	local output_path="${TEST_DIR}/output"
	mkdir -p "$output_path"

	run write_jira_details "$output_path"
	[[ "$status" -eq 0 ]]
	[[ -f "${output_path}/PROJ-123.txt" ]]
	grep -q "Ticket: PROJ-123" "${output_path}/PROJ-123.txt"
}

@test "write_jira_details:: returns success when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	mkdir -p "$test_repo"
	cd "$test_repo" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"
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
