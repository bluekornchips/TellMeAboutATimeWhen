#!/usr/bin/env bash
#
# Shared git helpers for the orchestrator and tools.
#

declare -F git_cmd >/dev/null 2>&1 && return 0

# Runs git with optional repository path from REPO_PATH
#
# Inputs:
# - $@: Git command arguments
#
# Outputs:
# - Git command stdout
#
# Returns:
# - Git command exit status
git_cmd() {
	local git_args=("$@")

	if [[ -n "${REPO_PATH}" ]]; then
		git -C "${REPO_PATH}" "${git_args[@]}" || return 1
	else
		git "${git_args[@]}" || return 1
	fi

	return 0
}

# Resolves repository owner and name from origin remote
#
# Outputs:
# - owner/repo slug to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
resolve_remote_owner_repo() {
	local remote_url
	if ! remote_url=$(git_cmd config --get remote.origin.url 2>/dev/null); then
		if [[ -n "${REPO_PATH}" ]]; then
			echo "resolve_remote_owner_repo:: Failed to get git remote URL from ${REPO_PATH}" >&2
		else
			echo "resolve_remote_owner_repo:: Failed to get git remote URL" >&2
		fi
		return 1
	fi

	local repo_owner
	local repo_name
	if [[ "${remote_url}" =~ ^https://github.com/([^/]+)/([^/]+) ]]; then
		repo_owner="${BASH_REMATCH[1]}"
		repo_name="${BASH_REMATCH[2]%.git}"
	elif [[ "${remote_url}" =~ ^git@github.com:([^/]+)/([^/]+) ]]; then
		repo_owner="${BASH_REMATCH[1]}"
		repo_name="${BASH_REMATCH[2]%.git}"
	else
		echo "resolve_remote_owner_repo:: Unsupported git remote URL format: ${remote_url}" >&2
		return 1
	fi

	if [[ -z "${repo_owner}" ]] || [[ -z "${repo_name}" ]]; then
		echo "resolve_remote_owner_repo:: Failed to extract repository owner and name from remote URL" >&2
		return 1
	fi

	echo "${repo_owner}/${repo_name}"

	return 0
}

# Validates that git_cmd can resolve a repository
#
# Returns:
# - 0 on success
# - 1 on validation failure
git_validate_repo() {
	if ! git_cmd rev-parse --git-dir >/dev/null 2>&1; then
		if [[ -n "${REPO_PATH}" ]]; then
			echo "git_validate_repo:: Not a git repository: ${REPO_PATH}" >&2
		else
			echo "git_validate_repo:: Not in a git repository" >&2
		fi
		return 1
	fi

	return 0
}
