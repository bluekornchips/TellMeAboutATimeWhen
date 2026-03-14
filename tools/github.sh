#!/usr/bin/env bash
#
# Script to get pull request details for a git commit using GitHub CLI
#

# Only enable strict mode when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
fi

# Display usage information
#
# Side Effects:
# - Outputs usage information to stdout
#
# Returns:
# - 0 always
usage() {
	cat <<EOF
Usage: $(basename "$0") <commit_hash>

Get pull request details for a git commit using GitHub CLI.

Arguments:
  <commit_hash>  : Git commit hash (short or full)

Options:
  -h, --help     : Show this help message

EOF
}

COMMIT="${COMMIT:-}"
PR_FILE="${PR_FILE:-}"
REPO_PATH="${REPO_PATH:-}"

export COMMIT
export PR_FILE
export REPO_PATH

# Validation functions and configuration setup
# Runs git command with repository context
#
# Inputs:
# - $@: Git command arguments
#
# Outputs:
# - Outputs git command results to stdout
#
# Side Effects:
# - Writes errors to stderr
#
# Returns:
# - Git command exit status
git_cmd() {
	local git_args=("$@")

	if [[ -n "${REPO_PATH}" ]]; then
		git -C "${REPO_PATH}" "${git_args[@]}"
	else
		git "${git_args[@]}"
	fi
}

# Validates that required arguments are provided
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_required_args() {
	if [[ -z "${COMMIT}" ]]; then
		echo "validate_required_args:: Missing required argument: commit_hash" >&2
		usage
		return 1
	fi

	return 0
}

# Validates that we're in a git repository
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_git_repo() {
	if ! git_cmd rev-parse --git-dir >/dev/null 2>&1; then
		if [[ -n "${REPO_PATH}" ]]; then
			echo "validate_git_repo:: Not a git repository: ${REPO_PATH}" >&2
		else
			echo "validate_git_repo:: Not in a git repository" >&2
		fi
		return 1
	fi

	return 0
}

# Validates that commit hash exists in git history
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_commit_exists() {
	local full_hash

	if ! full_hash=$(git_cmd rev-parse "${COMMIT}" 2>/dev/null); then
		echo "validate_commit_exists:: Commit '${COMMIT}' not found in git history" >&2
		return 1
	fi

	return 0
}

# Validates GitHub CLI dependencies and authentication
#
# Inputs:
# - $1: is_cli_entry, optional flag indicating if run from CLI entry point (default: false)
#
# Side Effects:
# - Attempts authentication when run from CLI entry point
#
# Returns:
# - 0 on success
# - 1 on failure
check_github_dependencies() {
	local missing=0
	local is_cli_entry="${1:-false}"

	if ! command -v jq >/dev/null 2>&1; then
		echo "check_github_dependencies:: jq is required for GitHub operations but is not installed" >&2
		missing=1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "check_github_dependencies:: GitHub CLI (gh) is not installed" >&2
		missing=1
	elif ! gh auth status >/dev/null 2>&1; then
		if [[ "${is_cli_entry}" == "true" ]]; then
			echo "check_github_dependencies:: GitHub CLI is not authenticated" >&2
			echo "check_github_dependencies:: Running 'gh auth login --web --hostname github.com'" >&2
			if ! gh auth login --web --hostname github.com; then
				echo "check_github_dependencies:: Failed to authenticate with GitHub CLI" >&2
				missing=1
			elif ! gh auth status >/dev/null 2>&1; then
				echo "check_github_dependencies:: Authentication completed but status check failed" >&2
				missing=1
			fi
		else
			echo "check_github_dependencies:: GitHub CLI is not authenticated" >&2
			missing=1
		fi
	fi

	if [[ "${missing}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# Helper functions used by main functionality
# Resolves repository owner and name from git remote
#
# Side Effects:
# - Outputs owner and name to stdout on separate lines
#
# Returns:
# - 0 on success
# - 1 on failure
resolve_remote_owner_repo() {
	local remote_url
	local repo_owner
	local repo_name

	if ! remote_url=$(git_cmd config --get remote.origin.url 2>/dev/null); then
		if [[ -n "${REPO_PATH}" ]]; then
			echo "resolve_remote_owner_repo:: Failed to get git remote URL from ${REPO_PATH}" >&2
		else
			echo "resolve_remote_owner_repo:: Failed to get git remote URL" >&2
		fi
		return 1
	fi

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

	echo "${repo_owner}"
	echo "${repo_name}"

	return 0
}

# Core logic functions
# Gets pull request details for a commit using GitHub CLI
#
# Side Effects:
# - Outputs PR details to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
get_pr_details() {
	local commit="${COMMIT}"
	local full_hash
	local remote_info
	local repo_owner
	local repo_name
	local repo_slug
	local pr_list
	local pr_numbers
	local pr_number

	if ! full_hash=$(git_cmd rev-parse "${commit}" 2>/dev/null); then
		echo "get_pr_details:: Failed to resolve commit hash: ${commit}" >&2
		return 1
	fi

	if ! remote_info=$(resolve_remote_owner_repo); then
		return 1
	fi

	repo_owner=$(echo "${remote_info}" | head -n 1)
	repo_name=$(echo "${remote_info}" | tail -n 1)
	repo_slug="${repo_owner}/${repo_name}"

	if ! pr_list=$(gh api "/repos/${repo_owner}/${repo_name}/commits/${full_hash}/pulls" 2>/dev/null); then
		return 1
	fi

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
			if ! gh pr view "${pr_number}" --repo "${repo_slug}" --json number,title,url,state,mergedAt,createdAt,body 2>/dev/null; then
				continue
			fi
		fi
	done <<<"${pr_numbers}"

	return 0
}

# Writes PR details for a commit to a file
#
# Side Effects:
# - Overwrites PR details to the output file as formatted JSON
#
# Returns:
# - 0 on success
# - 1 on failure
write_pr_details() {
	local pr_data

	if [[ -z "${COMMIT}" || -z "${PR_FILE}" ]]; then
		echo "write_pr_details:: commit or pr_file is not set" >&2
		return 1
	fi

	if ! check_github_dependencies; then
		return 1
	fi

	if ! validate_git_repo; then
		return 1
	fi

	if ! pr_data=$(get_pr_details 2>/dev/null); then
		if ! echo "[]" >"${PR_FILE}" 2>/dev/null; then
			echo "write_pr_details:: Failed to create PR file: ${PR_FILE}" >&2
			return 1
		fi
		return 0
	fi

	if [[ -z "${pr_data}" ]]; then
		if ! echo "[]" >"${PR_FILE}" 2>/dev/null; then
			echo "write_pr_details:: Failed to create PR file: ${PR_FILE}" >&2
			return 1
		fi
		return 0
	fi

	if ! echo "${pr_data}" | jq -s '.' >"${PR_FILE}" 2>/dev/null; then
		echo "write_pr_details:: Failed to format PR data as JSON" >&2
		return 1
	fi

	return 0
}

# Main entry point
github_main() {
	local commit_hash=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			return 0
			;;
		*)
			if [[ -z "${commit_hash}" ]]; then
				commit_hash="$1"
			else
				echo "github_main:: Unknown option '$1'" >&2
				echo "github_main:: Use '$(basename "$0") --help' for usage information" >&2
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -n "${commit_hash}" ]]; then
		COMMIT="${commit_hash}"
		export COMMIT
	fi

	if ! validate_required_args; then
		return 1
	fi

	if ! validate_git_repo; then
		return 1
	fi

	if ! validate_commit_exists; then
		return 1
	fi

	if ! check_github_dependencies "true"; then
		return 1
	fi

	if ! get_pr_details; then
		return 1
	fi

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	github_main "$@"
	exit $?
fi
