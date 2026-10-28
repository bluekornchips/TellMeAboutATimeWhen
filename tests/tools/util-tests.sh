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

fake_fetch() {
	local ticket_id="${1:-}"

	if [[ -z "${ticket_id}" ]]; then
		return 1
	fi

	echo "Ticket: ${ticket_id}"
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

@test "extract_ticket_ids:: fails when commit is not set" {
	run extract_ticket_ids ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit is not set"
}

@test "extract_ticket_ids:: returns empty when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	[[ -z "$output" ]]
}

@test "extract_ticket_ids:: extracts single ticket ID" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Fix bug" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-123"
}

@test "extract_ticket_ids:: extracts alphanumeric project keys like TEAM" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "TEAM-456: Platform work" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "TEAM-456"
}

@test "extract_ticket_ids:: extracts alphanumeric keys from merge commit branch names" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "Merge pull request #12 from org/feature/TEAM-789-login" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "TEAM-789"
}

@test "extract_ticket_ids:: extracts multiple unique ticket IDs" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-1 and PROJ-2 plus PROJ-1 again" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-1"
	echo "$output" | grep -q "PROJ-2"
	[[ $(echo "$output" | grep -c "PROJ-1") -eq 1 ]]
}

@test "extract_ticket_ids:: uses REPO_PATH when set" {
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

	run extract_ticket_ids "${commit}"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "PROJ-222"
	echo "$output" | grep -v -q "PROJ-111"
}

@test "needs_text_refresh:: true when missing or empty" {
	local artifact_file="${TEST_DIR}/artifact.txt"

	run needs_text_refresh "${artifact_file}"
	[[ "$status" -eq 0 ]]

	: >"${artifact_file}"
	run needs_text_refresh "${artifact_file}"
	[[ "$status" -eq 0 ]]

	echo "ticket" >"${artifact_file}"
	run needs_text_refresh "${artifact_file}"
	[[ "$status" -eq 1 ]]
}

@test "write_ticket_details:: fails when commit is not set" {
	local output_file="${TEST_DIR}/output/tickets.txt"
	mkdir -p "$(dirname "${output_file}")"

	run write_ticket_details "" "${output_file}" fake_fetch write_ticket_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or output file is not set"
}

@test "write_ticket_details:: fails when output file is not set" {
	run write_ticket_details "abc123" "" fake_fetch write_ticket_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or output file is not set"
}

@test "write_ticket_details:: fails when commit directory does not exist" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local output_file="${TEST_DIR}/nonexistent/tickets.txt"

	run write_ticket_details "${commit}" "${output_file}" fake_fetch write_ticket_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Commit directory does not exist"
}

@test "write_ticket_details:: writes fetched details to file" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "PROJ-123: Test ticket" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""
	local output_file="${TEST_DIR}/output/tickets.txt"
	mkdir -p "$(dirname "${output_file}")"

	run write_ticket_details "${commit}" "${output_file}" fake_fetch write_ticket_details
	[[ "$status" -eq 0 ]]
	[[ -f "${output_file}" ]]
	grep -q "Ticket: PROJ-123" "${output_file}"
}

@test "write_ticket_details:: returns success when no tickets found" {
	local test_repo="${TEST_DIR}/test_repo"
	create_worktree_repo "${test_repo}"
	echo "test" >file.txt
	git add file.txt
	git commit -m "No ticket here" >/dev/null 2>&1

	local commit
	commit=$(git rev-parse HEAD)
	local output_file="${TEST_DIR}/output/tickets.txt"
	mkdir -p "$(dirname "${output_file}")"

	run write_ticket_details "${commit}" "${output_file}" fake_fetch write_ticket_details
	[[ "$status" -eq 0 ]]
	[[ ! -f "${output_file}" ]]
}
