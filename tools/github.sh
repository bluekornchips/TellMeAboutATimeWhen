#!/usr/bin/env bash
#
# GitHub helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
#

# Validates GitHub CLI dependencies and authentication
#
# Returns:
# - 0 on success
# - 1 on failure
check_github_dependencies() {
	local missing=0

	if ! command -v jq >/dev/null 2>&1; then
		echo "check_github_dependencies:: jq is required for GitHub operations but is not installed" >&2
		missing=1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "check_github_dependencies:: GitHub CLI (gh) is not installed" >&2
		missing=1
	elif ! gh auth status >/dev/null 2>&1; then
		echo "check_github_dependencies:: GitHub CLI is not authenticated" >&2
		missing=1
	fi

	if [[ "${missing}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# Gets pull request details for a commit using GitHub CLI
#
# Inputs:
# - $1: commit hash
#
# Outputs:
# - PR JSON objects to stdout, one per matching pull request
#
# Returns:
# - 0 on success
# - 1 on failure
get_pr_details() {
	local commit="${1:-}"
	local full_hash
	local repo_slug
	local pr_list
	local pr_numbers
	local pr_number

	if [[ -z "${commit}" ]]; then
		echo "get_pr_details:: commit is not set" >&2
		return 1
	fi

	if ! full_hash=$(git_cmd rev-parse "${commit}" 2>/dev/null); then
		echo "get_pr_details:: Failed to resolve commit hash: ${commit}" >&2
		return 1
	fi

	repo_slug=$(resolve_remote_owner_repo) || return 1

	pr_list=$(gh api "/repos/${repo_slug}/commits/${full_hash}/pulls" 2>/dev/null) || return 1

	if [[ -z "${pr_list}" ]] || [[ "${pr_list}" == "[]" ]] || [[ "${pr_list}" == "null" ]]; then
		return 1
	fi

	if ! pr_numbers=$(echo "${pr_list}" | jq -r '.[].number' 2>/dev/null); then
		echo "get_pr_details:: Failed to parse PR numbers" >&2
		return 1
	fi

	if [[ -z "${pr_numbers}" ]]; then
		return 1
	fi

	while IFS= read -r pr_number; do
		if [[ -n "${pr_number}" ]]; then
			gh pr view "${pr_number}" --repo "${repo_slug}" --json number,title,url,state,mergedAt,createdAt,body 2>/dev/null || continue
		fi
	done <<<"${pr_numbers}"

	return 0
}

# Returns whether a PR artifact should be refreshed
#
# Inputs:
# - $1: pr.json path
#
# Returns:
# - 0 when refresh is needed
# - 1 when the existing file can be kept
needs_pr_refresh() {
	local pr_file="${1:-}"
	local pr_file_contents=""

	if [[ -z "${pr_file}" ]]; then
		return 0
	fi

	if [[ ! -f "${pr_file}" ]]; then
		return 0
	fi

	if ! pr_file_contents=$(<"${pr_file}"); then
		return 0
	fi

	if [[ "${pr_file_contents}" == "[]" ]]; then
		return 0
	fi

	return 1
}

# Writes PR details for a commit to a JSON file
#
# Inputs:
# - $1: commit hash
# - $2: output file
#
# Returns:
# - 0 on success
# - 1 on failure
write_pr_details() {
	local commit="${1:-}"
	local pr_file="${2:-}"
	local pr_data

	if [[ -z "${commit}" || -z "${pr_file}" ]]; then
		echo "write_pr_details:: commit or pr_file is not set" >&2
		return 1
	fi

	check_github_dependencies || return 1
	git_validate_repo || return 1

	if ! pr_data=$(get_pr_details "${commit}" 2>/dev/null); then
		pr_data=""
	fi

	if [[ -z "${pr_data}" ]]; then
		if ! printf '%s\n' "[]" >"${pr_file}" 2>/dev/null; then
			echo "write_pr_details:: Failed to create PR file: ${pr_file}" >&2
			return 1
		fi
	else
		if ! printf '%s\n' "${pr_data}" | jq -s '.' >"${pr_file}" 2>/dev/null; then
			echo "write_pr_details:: Failed to format PR data as JSON" >&2
			return 1
		fi
	fi

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	echo "github.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	exit 1
fi
