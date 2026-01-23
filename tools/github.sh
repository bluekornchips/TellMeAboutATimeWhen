#!/usr/bin/env bash
#
# Script to get pull request details for a git commit using GitHub CLI
#

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

export COMMIT
export PR_FILE

# Validation functions and configuration setup
# Validate that required arguments are provided
#
# Side Effects:
# - Exits with error message if validation fails
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
		echo "check_github_dependencies:: Running 'gh auth login --web --hostname github.com'" >&2
		if ! gh auth login --web --hostname github.com; then
			echo "check_github_dependencies:: Failed to authenticate with GitHub CLI" >&2
			missing=1
		elif ! gh auth status >/dev/null 2>&1; then
			echo "check_github_dependencies:: Authentication completed but status check failed" >&2
			missing=1
		fi
	fi

	if [[ "$missing" -ne 0 ]]; then
		return 1
	fi

	return 0
}

validate_required_args() {
	if [[ -z "$COMMIT" ]]; then
		echo "validate_required_args:: Missing required argument: commit_hash" >&2
		usage
		return 1
	fi

	return 0
}

# Validate that we're in a git repository
#
# Side Effects:
# - None
validate_git_repo() {
	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		echo "validate_git_repo:: Not in a git repository" >&2
		return 1
	fi

	return 0
}

# Validate that commit hash exists in git history
#
# Side Effects:
# - None
validate_commit_exists() {
	local full_hash

	if ! full_hash=$(git rev-parse "$COMMIT" 2>/dev/null); then
		echo "validate_commit_exists:: Commit '$COMMIT' not found in git history" >&2
		return 1
	fi

	return 0
}

# Core logic functions
# Get pull request details for a commit using GitHub CLI
#
# Side Effects:
# - Outputs PR details to stdout
get_pr_details() {
	local commit="$COMMIT"

	# Get full commit hash
	local full_hash
	full_hash=$(git rev-parse "$commit" 2>/dev/null)
	if [[ -z "$full_hash" ]]; then
		echo "get_pr_details:: Failed to resolve commit hash: $commit" >&2
		return 1
	fi

	# Get repository owner and name from git remote
	local remote_url
	remote_url=$(git config --get remote.origin.url 2>/dev/null)
	if [[ -z "$remote_url" ]]; then
		echo "get_pr_details:: Failed to get git remote URL" >&2
		return 1
	fi

	local repo_owner
	local repo_name
	if [[ "$remote_url" =~ ^https://github.com/([^/]+)/([^/]+) ]]; then
		repo_owner="${BASH_REMATCH[1]}"
		repo_name="${BASH_REMATCH[2]%.git}"
	elif [[ "$remote_url" =~ ^git@github.com:([^/]+)/([^/]+) ]]; then
		repo_owner="${BASH_REMATCH[1]}"
		repo_name="${BASH_REMATCH[2]%.git}"
	else
		echo "get_pr_details:: Unsupported git remote URL format: $remote_url" >&2
		return 1
	fi

	if [[ -z "$repo_owner" ]] || [[ -z "$repo_name" ]]; then
		echo "get_pr_details:: Failed to extract repository owner and name from remote URL" >&2
		return 1
	fi

	# Query GitHub API for PRs containing this commit
	local pr_list
	pr_list=$(gh api "/repos/${repo_owner}/${repo_name}/commits/${full_hash}/pulls" 2>/dev/null)

	if [[ -z "$pr_list" ]] || [[ "$pr_list" == "[]" ]] || [[ "$pr_list" == "null" ]]; then
		return 1
	fi

	# Extract PR numbers and get details for each
	local pr_numbers
	if ! pr_numbers=$(echo "$pr_list" | jq -r '.[].number' 2>/dev/null); then
		echo "get_pr_details:: Failed to parse PR numbers" >&2
		return 1
	fi
	if [[ -z "$pr_numbers" ]]; then
		return 1
	fi

	while read -r pr_number; do
		if [[ -n "$pr_number" ]]; then
			if ! gh pr view "$pr_number" --json number,title,url,state,mergedAt,createdAt,body 2>/dev/null; then
				continue
			fi
		fi
	done <<<"$pr_numbers"

	return 0
}

# Initialize PRs file by creating it if it doesn't exist
#
# Inputs:
# - $1: PRS_FILE path
#
# Side Effects:
# - Creates the PRS file if it doesn't exist
initialize_prs_file() {
	local prs_file="$1"

	if [[ -z "$prs_file" ]]; then
		echo "initialize_prs_file:: prs_file is not set" >&2
		return 1
	fi

	if ! touch "$prs_file" 2>/dev/null; then
		echo "initialize_prs_file:: Failed to create PRS file: $prs_file" >&2
		return 1
	fi

	return 0
}

# Write PR details for a commit to a file
#
# Side Effects:
# - Overwrites PR details to the output file as formatted JSON
write_pr_details() {
	if [[ -z "$COMMIT" || -z "$PR_FILE" ]]; then
		echo "write_pr_details:: commit or pr_file is not set" >&2
		return 1
	fi

	if ! check_github_dependencies; then
		return 1
	fi

	if ! validate_git_repo; then
		return 1
	fi

	local pr_data
	if ! pr_data=$(get_pr_details 2>/dev/null); then
		return 1
	fi

	if [[ -z "$pr_data" ]]; then
		return 1
	fi

	if ! echo "$pr_data" | jq -s '.' >"$PR_FILE" 2>/dev/null; then
		echo "write_pr_details:: Failed to format PR data as JSON" >&2
		return 1
	fi

	return 0
}

# Write PR details for a commit to a specific file
#
# Side Effects:
# - Overwrites PR details to the output file
write_pr_details_to_file() {
	if [[ -z "$COMMIT" || -z "$PR_FILE" ]]; then
		echo "write_pr_details_to_file:: commit or pr_file is not set" >&2
		return 1
	fi

	if ! write_pr_details; then
		return 1
	fi

	return 0
}

# Main entry point
github_main() {
	local commit_hash=""

	while [[ $# -gt 0 ]]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		*)
			if [[ -z "$commit_hash" ]]; then
				commit_hash="$1"
			else
				echo "main:: Unknown option '$1'" >&2
				echo "main:: Use '$(basename "$0") --help' for usage information" >&2
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -n "$commit_hash" ]]; then
		COMMIT="$commit_hash"
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

	if ! check_github_dependencies; then
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
