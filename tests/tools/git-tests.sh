#!/usr/bin/env bats
#
# Test suite for tools/lib/git.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/lib/git.sh" || return 1
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

# git_cmd
@test "git_cmd:: uses current directory when REPO_PATH is not set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"

	REPO_PATH=""
	run git_cmd rev-parse --git-dir
	[[ "$status" -eq 0 ]]
}

@test "git_cmd:: uses REPO_PATH when set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	create_worktree_repo "${TEST_DIR}/repo2"
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
	create_worktree_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	[[ "$output" == "owner/repo" ]]
}

@test "resolve_remote_owner_repo:: extracts owner and name from SSH URL" {
	create_worktree_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
	git remote add origin "git@github.com:owner/repo.git" 2>/dev/null || git remote set-url origin "git@github.com:owner/repo.git"

	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	[[ "$output" == "owner/repo" ]]
}

@test "resolve_remote_owner_repo:: uses REPO_PATH when set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	create_worktree_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	cd "${TEST_DIR}/repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	REPO_PATH="${TEST_DIR}/repo2"
	run resolve_remote_owner_repo
	[[ "$status" -eq 0 ]]
	[[ "$output" == "owner2/repo2" ]]
}

@test "resolve_remote_owner_repo:: fails with unsupported URL format" {
	create_worktree_repo "${TEST_DIR}/repo1"
	cd "${TEST_DIR}/repo1"
	git remote add origin "unsupported://example.com/repo.git" 2>/dev/null || git remote set-url origin "unsupported://example.com/repo.git"

	run resolve_remote_owner_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Unsupported git remote URL format"
}

# git_validate_repo
@test "git_validate_repo:: fails when not in git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$no_repo_dir"

	REPO_PATH=""
	run git_validate_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not in a git repository"
}

@test "git_validate_repo:: succeeds when in git repository" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	REPO_PATH=""
	run git_validate_repo
	[[ "$status" -eq 0 ]]
}

@test "git_validate_repo:: uses REPO_PATH when set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	create_worktree_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"

	REPO_PATH="${TEST_DIR}/repo2"
	run git_validate_repo
	[[ "$status" -eq 0 ]]
}

@test "git_validate_repo:: fails when REPO_PATH is not a git repository" {
	local no_repo_dir="${TEST_DIR}/no_repo"
	mkdir -p "$no_repo_dir"
	cd "$TEST_DIR"

	REPO_PATH="$no_repo_dir"
	run git_validate_repo
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Not a git repository: ${no_repo_dir}"
}
