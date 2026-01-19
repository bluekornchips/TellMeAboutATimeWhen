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

# Validation functions and configuration setup
# Validate that required arguments are provided
#
# Inputs:
# - $1: commit_hash
#
# Side Effects:
# - Exits with error message if validation fails
validate_required_args() {
	local commit_hash="$1"

	if [[ -z "$commit_hash" ]]; then
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
# Inputs:
# - $1: commit_hash
#
# Side Effects:
# - None
validate_commit_exists() {
	local commit_hash="$1"
	local full_hash

	if ! full_hash=$(git rev-parse "$commit_hash" 2>/dev/null); then
		echo "validate_commit_exists:: Commit '$commit_hash' not found in git history" >&2
		return 1
	fi

	return 0
}

# Core logic functions
# Get pull request details for a commit using GitHub CLI
#
# Inputs:
# - $1: commit_hash
#
# Side Effects:
# - Outputs PR details to stdout
get_pr_details() {
	local commit="$1"

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

	cat <<EOF

Pull Request Details
========================================

EOF
	while read -r pr_number; do
		if [[ -n "$pr_number" ]]; then
			local pr_details
			if ! pr_details=$(gh pr view "$pr_number" --json number,title,url,state,mergedAt,createdAt,body 2>/dev/null); then
				continue
			fi
			if [[ -n "$pr_details" ]]; then
				if ! echo "$pr_details" | jq -r '
					"PR #\(.number): \(.title)",
					"URL: \(.url)",
					"State: \(.state)",
					"Created: \(.createdAt)",
					(if .mergedAt then "Merged: \(.mergedAt)" else empty end),
					"",
					"Description:",
					.body,
					"---"
				' 2>/dev/null; then
					continue
				fi
			fi
		fi
	done <<<"$pr_numbers"

	return 0
}

# Main entry point
main() {
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

	# Validate required arguments
	if ! validate_required_args "$commit_hash"; then
		return 1
	fi

	# Validate git repository
	if ! validate_git_repo; then
		return 1
	fi

	# Validate commit exists
	if ! validate_commit_exists "$commit_hash"; then
		return 1
	fi

	# Get PR details
	if ! get_pr_details "$commit_hash"; then
		return 1
	fi

	return 0
}

# Allow script to be executed directly with arguments, or sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
