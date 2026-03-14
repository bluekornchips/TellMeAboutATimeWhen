#!/usr/bin/env bats
#
# Test suite for tools/github.sh
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	SCRIPT="${GIT_ROOT}/tools/github.sh"
	if [[ ! -f "$SCRIPT" ]]; then
		echo "setup:: Script not found: $SCRIPT" >&2
		return 1
	fi

	export GIT_ROOT
	export SCRIPT

	return 0
}

setup() {
	# shellcheck source=tools/github.sh
	# Temporarily disable exit on error to prevent script from exiting when sourced
	set +e
	source "$SCRIPT" || true
	set -e

	TEST_DIR=$(mktemp -d)
	export TEST_DIR
	trap 'rm -rf "$TEST_DIR"' EXIT
	export COMMIT
	export PR_FILE
	export REPO_PATH

	return 0
}

teardown() {
	return 0
}

create_test_repo() {
	local repo_dir="$1"
	local bare_repo
	local worktree_path
	local bare_base

	worktree_path="${repo_dir}"
	bare_base=$(dirname "${repo_dir}")
	bare_repo="${bare_base}/bare_$(basename "$repo_dir").git"

	if [[ -d "${worktree_path}" ]]; then
		rm -rf "${worktree_path}"
	fi

	git init --bare "${bare_repo}" >/dev/null 2>&1

	git -C "${bare_repo}" worktree add "${worktree_path}" >/dev/null 2>&1

	cd "${worktree_path}" || return 1

	git config user.name "Test User"
	git config user.email "test@example.com"

	echo "test file" >test.txt
	git add test.txt
	git commit -m "Initial commit" >/dev/null 2>&1

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

@test "check_github_dependencies:: does not auto-login when not CLI entry" {
	gh() {
		if [[ "$1" == "auth" && "$2" == "status" ]]; then
			return 1
		fi
		return 0
	}

	jq() {
		return 0
	}

	run check_github_dependencies "false"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "GitHub CLI is not authenticated"

	unset -f gh jq
}

# git_cmd
@test "git_cmd:: uses current directory when REPO_PATH is not set" {
	create_test_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"

	REPO_PATH=""
	run git_cmd rev-parse --git-dir
	[[ "$status" -eq 0 ]]
}

@test "git_cmd:: uses REPO_PATH when set" {
	create_test_repo "${TEST_DIR}/repo1"
	create_test_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"

	REPO_PATH="${TEST_DIR}/repo2"
	run git_cmd rev-parse --git-dir
	[[ "$status" -eq 0 ]]
	local repo2_git_dir
	repo2_git_dir=$(git -C "${TEST_DIR}/repo2" rev-parse --git-dir)
	[[ "$output" == "$repo2_git_dir" ]]
}

# resolve_remote_owner_repo
@test "resolve_remote_owner_repo:: extracts owner and name from HTTPS URL" {
	create_test_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
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

@test "resolve_remote_owner_repo:: extracts owner and name from SSH URL" {
	create_test_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
	git remote add origin "git@github.com:owner/repo.git" 2>/dev/null || git remote set-url origin "git@github.com:owner/repo.git"

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
	create_test_repo "${TEST_DIR}/repo1"
	create_test_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	cd "${TEST_DIR}/repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	REPO_PATH="${TEST_DIR}/repo2"
	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	local owner
	local name
	owner=$(echo "$output" | head -n 1)
	name=$(echo "$output" | tail -n 1)
	[[ "$owner" == "owner2" ]]
	[[ "$name" == "repo2" ]]
}

@test "resolve_remote_owner_repo:: fails with unsupported URL format" {
	create_test_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
	git remote add origin "unsupported://example.com/repo.git" 2>/dev/null || git remote set-url origin "unsupported://example.com/repo.git"

	run resolve_remote_owner_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Unsupported git remote URL format"
}

# write_pr_details
@test "write_pr_details:: fails when commit is not set" {
	local prs_file="${TEST_DIR}/test_prs.md"
	touch "$prs_file"

	COMMIT=""
	PR_FILE="$prs_file"

	run write_pr_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: fails when prs_file is not set" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT="abc123"
	PR_FILE=""
	run write_pr_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: writes PR details to file" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	local prs_file="${TEST_DIR}/test_prs.md"
	touch "$prs_file"

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"
	PR_FILE="$prs_file"

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
		fi
		return 0
	}

	run write_pr_details
	[[ "$status" -eq 0 ]]
	[[ -f "$prs_file" ]]

	unset -f gh jq
}

# validate_required_args
@test "validate_required_args:: fails with missing commit hash" {
	COMMIT=""
	run validate_required_args
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "validate_required_args:: succeeds with commit hash" {
	COMMIT="abc123"
	run validate_required_args
	[[ "$status" -eq 0 ]]
}

# validate_git_repo
@test "validate_git_repo:: fails when not in git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$no_repo_dir"

	REPO_PATH=""
	run validate_git_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not in a git repository"
}

@test "validate_git_repo:: succeeds when in git repository" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	REPO_PATH=""
	run validate_git_repo
	[[ "$status" -eq 0 ]]
}

@test "validate_git_repo:: uses REPO_PATH when set" {
	create_test_repo "${TEST_DIR}/repo1"
	create_test_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"

	REPO_PATH="${TEST_DIR}/repo2"
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

# validate_commit_exists
@test "validate_commit_exists:: fails with invalid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT="nonexistent123"
	run validate_commit_exists
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "not found in git history"
}

@test "validate_commit_exists:: succeeds with valid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	run validate_commit_exists
	[[ "$status" -eq 0 ]]
}

@test "get_pr_details:: fails when commit hash cannot be resolved" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT="test123"
	export COMMIT
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	git() {
		if [[ "$1" == "rev-parse" ]]; then
			return 1
		fi
		command git "$@"
	}

	run get_pr_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to resolve commit hash"

	unset -f git
}

@test "get_pr_details:: fails when git remote URL cannot be retrieved" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote remove origin 2>/dev/null || true

	run get_pr_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Failed to get git remote URL"
}

@test "get_pr_details:: uses REPO_PATH when set" {
	create_test_repo "${TEST_DIR}/repo1"
	create_test_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	cd "${TEST_DIR}/repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	COMMIT=$(git -C "${TEST_DIR}/repo2" rev-parse HEAD)
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

	run get_pr_details
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'

	unset -f gh jq
}

@test "get_pr_details:: fails with unsupported remote URL format" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote add origin "unsupported://example.com/repo.git" 2>/dev/null || git remote set-url origin "unsupported://example.com/repo.git"

	run get_pr_details
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Unsupported git remote URL format"
}

@test "get_pr_details:: returns empty when no PRs found" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	# shellcheck disable=SC2329
	gh() {
		if [[ "$1" == "api" ]]; then
			echo "[]"
		fi
		return 0
	}

	run get_pr_details
	[[ "$status" -eq 1 ]]
}

@test "get_pr_details:: outputs PR details when PRs found" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	export COMMIT

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

	run get_pr_details
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'
	echo "$output" | grep -q '"title":"Test PR"'
	echo "$output" | grep -q '"state":"MERGED"'
}

@test "github_main:: shows help correctly" {
	run github_main --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
}

@test "github_main:: fails with missing commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run github_main
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}

@test "github_main:: fails when not in git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$no_repo_dir"

	run github_main "abc123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not in a git repository"
}

@test "github_main:: fails with invalid commit hash" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run github_main "nonexistent123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "not found in git history"
}

@test "github_main:: handles unknown options as second argument" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	COMMIT=$(git rev-parse HEAD)
	run github_main "$COMMIT" --unknown-option
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Unknown option"
}

@test "integration:: script execution with help flag" {
	run "$SCRIPT" --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
}

@test "integration:: script execution fails without arguments" {
	create_test_repo "$TEST_DIR"
	cd "$TEST_DIR"

	run "$SCRIPT"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing required argument"
}
