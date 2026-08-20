#!/usr/bin/env bash
#
# Shared git fixtures for Bats tests.
#
# Prefer creating templates once in setup_file, then clone per test:
# - SHARED_SEED_REPO: minimal repo with a seed commit on master
# - SHARED_ANALYZER_REPO: multi-author analyzer fixture
#
# create_worktree_repo and create_analyzer_repo clone those shared templates
# when set, otherwise they build a fresh repo for backward compatibility.
#

# Copies a fixture repo into dest and cds into it
#
# Inputs:
# - $1: source_repo
# - $2: dest_repo, must be under a system temp root
#
# Returns:
# - 0 on success
# - 1 on failure
clone_fixture_repo() {
	local source_repo="$1"
	local dest_repo="$2"
	local tmp_root

	if [[ -z "${source_repo}" || -z "${dest_repo}" ]]; then
		echo "clone_fixture_repo:: source and dest are required" >&2
		return 1
	fi

	if [[ ! -d "${source_repo}/.git" && ! -f "${source_repo}/.git" ]]; then
		echo "clone_fixture_repo:: source is not a git repo: ${source_repo}" >&2
		return 1
	fi

	tmp_root="${BATS_FILE_TMPDIR:-${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}}"
	if [[ "${dest_repo}" != "${tmp_root}/"* && "${dest_repo}" != "/tmp/"* ]]; then
		echo "clone_fixture_repo:: refusing to remove path outside of tmp: ${dest_repo}" >&2
		return 1
	fi

	rm -rf "${dest_repo}"
	mkdir -p "$(dirname "${dest_repo}")"
	if ! cp -a "${source_repo}" "${dest_repo}"; then
		echo "clone_fixture_repo:: Failed to copy ${source_repo} to ${dest_repo}" >&2
		return 1
	fi

	git -C "${dest_repo}" config user.name "Test User"
	git -C "${dest_repo}" config user.email "test@example.com"

	cd "${dest_repo}" || return 1

	return 0
}

# Creates a standalone seed repository with one empty commit on master
#
# Inputs:
# - $1: repo_dir, must be under a system temp root
#
# Returns:
# - 0 on success
# - 1 on failure
create_seed_repo() {
	local repo_dir="$1"
	local tmp_root

	if [[ -z "${repo_dir}" ]]; then
		echo "create_seed_repo:: repo_dir is required" >&2
		return 1
	fi

	tmp_root="${BATS_FILE_TMPDIR:-${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}}"
	if [[ "${repo_dir}" != "${tmp_root}/"* && "${repo_dir}" != "/tmp/"* ]]; then
		echo "create_seed_repo:: refusing to remove path outside of tmp: ${repo_dir}" >&2
		return 1
	fi

	rm -rf "${repo_dir}"
	mkdir -p "${repo_dir}"

	git init "${repo_dir}" >/dev/null 2>&1
	git -C "${repo_dir}" config user.name "Test User"
	git -C "${repo_dir}" config user.email "test@example.com"
	git -C "${repo_dir}" commit --allow-empty -m "seed" >/dev/null 2>&1
	git -C "${repo_dir}" branch -M master >/dev/null 2>&1

	cd "${repo_dir}" || return 1

	return 0
}

# Creates a git repo at repo_dir with a seed commit
#
# When SHARED_SEED_REPO is set, clones that template instead of rebuilding.
#
# Inputs:
# - $1: repo_dir
#
# Returns:
# - 0 on success
# - 1 on failure
create_worktree_repo() {
	local repo_dir="$1"

	if [[ -n "${SHARED_SEED_REPO:-}" && -d "${SHARED_SEED_REPO}" ]]; then
		clone_fixture_repo "${SHARED_SEED_REPO}" "${repo_dir}" || return 1
		return 0
	fi

	create_seed_repo "${repo_dir}" || return 1

	return 0
}

# Builds the multi-author analyzer fixture from scratch
#
# Inputs:
# - $1: repo_dir
#
# Returns:
# - 0 on success
# - 1 on failure
build_analyzer_repo() {
	local repo_dir="$1"
	local default_branch

	create_seed_repo "${repo_dir}" || return 1

	echo "test file" >"${repo_dir}/test.txt"
	git -C "${repo_dir}" add test.txt
	git -C "${repo_dir}" commit -m "Initial commit" >/dev/null 2>&1

	default_branch=$(git -C "${repo_dir}" symbolic-ref --short HEAD 2>/dev/null || echo "master")
	if [[ "${default_branch}" != "master" ]]; then
		git -C "${repo_dir}" branch -m master >/dev/null 2>&1 || true
	fi

	echo "change by author1" >>"${repo_dir}/test.txt"
	git -C "${repo_dir}" add test.txt
	GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
		git -C "${repo_dir}" commit --author="Author One <author1@example.com>" -m "Commit by author1" >/dev/null 2>&1

	echo "change by author2" >>"${repo_dir}/test.txt"
	git -C "${repo_dir}" add test.txt
	GIT_COMMITTER_NAME="Author Two" GIT_COMMITTER_EMAIL="author2@example.com" \
		git -C "${repo_dir}" commit --author="Author Two <author2@example.com>" -m "Commit by author2" >/dev/null 2>&1

	git -C "${repo_dir}" checkout -b test-branch >/dev/null 2>&1
	echo "branch change" >>"${repo_dir}/test.txt"
	git -C "${repo_dir}" add test.txt
	git -C "${repo_dir}" commit -m "Branch commit" >/dev/null 2>&1

	git -C "${repo_dir}" checkout master >/dev/null 2>&1

	cd "${repo_dir}" || return 1

	return 0
}

# Creates a fixture repo with multiple authors and a test-branch
#
# When SHARED_ANALYZER_REPO is set, clones that template instead of rebuilding.
#
# Inputs:
# - $1: repo_dir
#
# Returns:
# - 0 on success
# - 1 on failure
create_analyzer_repo() {
	local repo_dir="$1"

	if [[ -n "${SHARED_ANALYZER_REPO:-}" && -d "${SHARED_ANALYZER_REPO}" ]]; then
		clone_fixture_repo "${SHARED_ANALYZER_REPO}" "${repo_dir}" || return 1
		return 0
	fi

	build_analyzer_repo "${repo_dir}" || return 1

	return 0
}

# Creates shared seed and analyzer templates for a Bats file
#
# Side Effects:
# - Sets and exports SHARED_SEED_REPO and SHARED_ANALYZER_REPO under BATS_FILE_TMPDIR
#
# Returns:
# - 0 on success
# - 1 on failure
init_shared_fixtures() {
	local fixture_root
	local previous_cwd

	previous_cwd="${PWD}"
	fixture_root="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}/tellme-fixtures"
	mkdir -p "${fixture_root}"

	SHARED_SEED_REPO=""
	SHARED_ANALYZER_REPO=""
	export SHARED_SEED_REPO
	export SHARED_ANALYZER_REPO

	create_seed_repo "${fixture_root}/seed" || return 1
	build_analyzer_repo "${fixture_root}/analyzer" || return 1

	SHARED_SEED_REPO="${fixture_root}/seed"
	SHARED_ANALYZER_REPO="${fixture_root}/analyzer"
	export SHARED_SEED_REPO
	export SHARED_ANALYZER_REPO

	cd "${previous_cwd}" || return 1

	return 0
}
