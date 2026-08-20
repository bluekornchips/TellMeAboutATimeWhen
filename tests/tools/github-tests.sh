#!/usr/bin/env bats
#
# Test suite for tools/github.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/github.sh" || return 1
	if [[ ! -f "$HELPER" ]]; then
		echo "setup:: Helper not found: $HELPER" >&2
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
	source "$HELPER"
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	bats_source_libs "$SCRIPT"
	export REPO_PATH

	return 0
}

# check_github_dependencies
@test "check_github_dependencies:: fails when jq is not installed" {
	command() {
		if [[ "$1" == "-v" ]]; then
			if [[ "$2" == "jq" ]]; then
				return 1
			elif [[ "$2" == "gh" ]]; then
				return 0
			fi
		fi
		command "$@"
	}

	gh() {
		if [[ "$1" == "auth" && "$2" == "status" ]]; then
			return 0
		fi
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "jq is required"

	unset -f command gh
}

@test "check_github_dependencies:: fails when gh is not installed" {
	command() {
		if [[ "$1" == "-v" ]]; then
			if [[ "$2" == "jq" ]]; then
				return 0
			elif [[ "$2" == "gh" ]]; then
				return 1
			fi
		fi
		command "$@"
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "GitHub CLI.*not installed"

	unset -f command jq
}

@test "check_github_dependencies:: succeeds when dependencies are available" {
	gh() {
		if [[ "$1" == "auth" && "$2" == "status" ]]; then
			return 0
		fi
		return 0
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 0 ]]

	unset -f gh jq
}

@test "check_github_dependencies:: fails when not authenticated" {
	gh() {
		if [[ "$1" == "auth" && "$2" == "status" ]]; then
			return 1
		fi
		return 0
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "GitHub CLI is not authenticated"

	unset -f gh jq
}

# needs_pr_refresh
@test "needs_pr_refresh:: true when missing or empty array" {
	local prs_file="${TEST_DIR}/pr.json"

	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 0 ]]

	echo '[]' >"${prs_file}"
	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 0 ]]

	echo '[{"number":1}]' >"${prs_file}"
	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 1 ]]
}

# write_pr_details
@test "write_pr_details:: fails when commit is not set" {
	local prs_file="${TEST_DIR}/test_prs.json"
	touch "$prs_file"

	run write_pr_details "" "$prs_file"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: fails when prs_file is not set" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	run write_pr_details "abc123" ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: writes PR details to file" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	local prs_file="${TEST_DIR}/test_prs.json"
	commit=$(git rev-parse HEAD)
	touch "$prs_file"

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	gh() {
		if [[ "$1" == "auth" && "$2" == "status" ]]; then
			return 0
		elif [[ "$1" == "api" ]]; then
			echo '[{"number": 123}]'
		elif [[ "$1" == "pr" && "$2" == "view" ]]; then
			echo '{"number": 123, "title": "Test PR"}'
		fi
		return 0
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		elif [[ "$1" == "-s" ]]; then
			cat >/dev/null
			echo '[{"number":123,"title":"Test PR"}]'
		fi
		return 0
	}

	run write_pr_details "$commit" "$prs_file"
	[[ "$status" -eq 0 ]]
	[[ -f "$prs_file" ]]

	unset -f gh jq
}

@test "get_pr_details:: fails when commit hash cannot be resolved" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	git() {
		if [[ "$1" == "rev-parse" ]]; then
			return 1
		fi
		command git "$@"
	}

	run get_pr_details "test123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to resolve commit hash"

	unset -f git
}

@test "get_pr_details:: fails when git remote URL cannot be retrieved" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote remove origin 2>/dev/null || true

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Failed to get git remote URL"
}

@test "get_pr_details:: uses REPO_PATH when set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	create_worktree_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	cd "${TEST_DIR}/repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	local commit
	commit=$(git -C "${TEST_DIR}/repo2" rev-parse HEAD)
	REPO_PATH="${TEST_DIR}/repo2"

	gh() {
		if [[ "$1" == "api" ]]; then
			echo '[{"number": 123}]'
		elif [[ "$1" == "pr" && "$2" == "view" ]]; then
			printf '%s\n' '{"number":123,"title":"Test PR"}'
		fi
		return 0
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		fi
		return 0
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'

	unset -f gh jq
}

@test "get_pr_details:: fails with unsupported remote URL format" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote add origin "unsupported://example.com/repo.git" 2>/dev/null || git remote set-url origin "unsupported://example.com/repo.git"

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Unsupported git remote URL format"
}

@test "get_pr_details:: returns empty when no PRs found" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	# shellcheck disable=SC2329
	gh() {
		if [[ "$1" == "api" ]]; then
			echo "[]"
		fi
		return 0
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]
}

@test "get_pr_details:: outputs PR details when PRs found" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	gh() {
		if [[ "$1" == "api" ]]; then
			echo '[{"number": 123}]'
		elif [[ "$1" == "pr" && "$2" == "view" ]]; then
			printf '%s\n' '{"number":123,"title":"Test PR","url":"https://github.com/owner/repo/pull/123","state":"MERGED","mergedAt":"2025-01-20T10:00:00Z","createdAt":"2025-01-19T10:00:00Z","body":"Test PR body"}'
		fi
		return 0
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		fi
		return 0
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'
	echo "$output" | grep -q '"title":"Test PR"'
	echo "$output" | grep -q '"state":"MERGED"'
}

@test "integration:: rejects direct script execution" {
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	run assert_rejects_direct_execution "$SCRIPT"
	[[ "$status" -eq 0 ]]
}
