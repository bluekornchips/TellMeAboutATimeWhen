#!/usr/bin/env bash
#
# Script to get JIRA ticket details and comments using Atlassian CLI
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
Usage: $(basename "$0") <ticket_id>

Get JIRA ticket details and comments using Atlassian CLI.

Arguments:
  <ticket_id>  : JIRA ticket ID (e.g., PROJ-123)

Options:
  -h, --help     : Show this help message

EOF
}

TICKET_ID="${TICKET_ID:-}"
COMMIT="${COMMIT:-}"
JIRA_FILE="${JIRA_FILE:-}"
REPO_PATH="${REPO_PATH:-}"

export TICKET_ID
export COMMIT
export JIRA_FILE
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

# Validates required arguments for CLI usage
#
# Inputs:
# - $1: Optional ticket id override
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_required_args() {
	local ticket_id="${1:-${TICKET_ID}}"

	if [[ -z "${ticket_id}" ]]; then
		echo "validate_required_args:: Missing required argument: ticket_id" >&2
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
			echo "validate_git_repo:: Not a git repository" >&2
		fi
		return 1
	fi

	return 0
}

# Validates Atlassian CLI dependency availability
#
# Inputs:
# - None
#
# Returns:
# - 0 on success
# - 1 on failure
check_jira_dependencies() {
	if ! command -v acli >/dev/null 2>&1; then
		echo "check_jira_dependencies:: Atlassian CLI (acli) is not installed or not in PATH" >&2
		return 1
	fi

	return 0
}

# Validates GitHub CLI dependency availability and auth
#
# Returns:
# - 0 on success
# - 1 on failure
check_github_dependencies() {
	if ! command -v gh >/dev/null 2>&1; then
		echo "check_github_dependencies:: GitHub CLI is not installed or not in PATH" >&2
		return 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		echo "check_github_dependencies:: jq is not installed or not in PATH" >&2
		return 1
	fi

	if ! gh auth status >/dev/null 2>&1; then
		echo "check_github_dependencies:: GitHub CLI is not authenticated" >&2
		return 1
	fi

	return 0
}

# Validates Atlassian CLI authentication
#
# Returns:
# - 0 on success
# - 1 on failure
validate_jira_auth() {
	if ! acli jira auth status >/dev/null 2>&1; then
		cat <<EOF >&2
validate_jira_auth:: Atlassian CLI is not authenticated
validate_jira_auth:: Run one of the following commands to login
validate_jira_auth:: acli jira auth login --web
validate_jira_auth:: acli jira auth login --site <site> --email <email> --token
EOF
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
# Gets ticket details for a specific ticket ID
#
# Inputs:
# - $1: ticket_id, JIRA ticket ID
#
# Side Effects:
# - Outputs ticket details and comments to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
get_ticket_details_for_id() {
	local ticket_id="$1"
	local ticket_output
	local comments_output

	if [[ -z "${ticket_id}" ]]; then
		echo "get_ticket_details_for_id:: ticket_id is not set" >&2
		return 1
	fi

	if ! check_jira_dependencies; then
		return 1
	fi

	if ! validate_jira_auth; then
		return 1
	fi

	if ! ticket_output=$(acli jira workitem view "${ticket_id}" 2>/dev/null); then
		echo "get_ticket_details_for_id:: Failed to retrieve ticket details for: ${ticket_id}" >&2
		return 1
	fi

	echo "${ticket_output}"

	if comments_output=$(acli jira workitem comment list --key "${ticket_id}" 2>/dev/null); then
		if [[ -n "${comments_output}" ]]; then
			echo "${comments_output}"
		fi
	else
		echo "get_ticket_details_for_id:: Failed to retrieve comments for: ${ticket_id}" >&2
	fi

	return 0
}

# Extracts JIRA ticket IDs from a commit message
#
# Side Effects:
# - Outputs ticket IDs to stdout, one per line
#
# Returns:
# - 0 on success
# - 1 on failure
extract_jira_tickets() {
	local commit_message
	local ticket_ids=()
	local ticket_id
	local existing_id
	local found=0

	if [[ -z "${COMMIT}" ]]; then
		echo "extract_jira_tickets:: commit is not set" >&2
		return 1
	fi

	if ! commit_message=$(git_cmd log -1 --format="%B" "${COMMIT}" 2>/dev/null); then
		echo "extract_jira_tickets:: Failed to get commit message for ${COMMIT}" >&2
		return 1
	fi

	if [[ -z "${commit_message}" ]]; then
		return 0
	fi

	if command -v grep >/dev/null 2>&1; then
		while IFS= read -r ticket_id; do
			if [[ -n "${ticket_id}" ]]; then
				found=0
				for existing_id in "${ticket_ids[@]}"; do
					if [[ "${existing_id}" == "${ticket_id}" ]]; then
						found=1
						break
					fi
				done
				if ((found == 0)); then
					ticket_ids+=("${ticket_id}")
				fi
			fi
		done < <(echo "${commit_message}" | grep -oE '[A-Z]+-[0-9]+' 2>/dev/null || true)
	else
		while [[ "${commit_message}" =~ ([A-Z]+-[0-9]+) ]]; do
			ticket_id="${BASH_REMATCH[1]}"
			found=0
			for existing_id in "${ticket_ids[@]}"; do
				if [[ "${existing_id}" == "${ticket_id}" ]]; then
					found=1
					break
				fi
			done
			if ((found == 0)); then
				ticket_ids+=("${ticket_id}")
			fi
			commit_message="${commit_message#*"${BASH_REMATCH[1]}"}"
		done
	fi

	for ticket_id in "${ticket_ids[@]}"; do
		echo "${ticket_id}"
	done

	return 0
}

# Extracts pull request URLs from ticket description
#
# Inputs:
# - $1: ticket_id, JIRA ticket ID
#
# Side Effects:
# - Outputs pull request URLs to stdout, one per line
#
# Returns:
# - 0 on success
# - 1 on failure
extract_pr_urls_from_ticket() {
	local ticket_id="$1"
	local ticket_json=""
	local pr_urls=()
	local description_filter
	local description_text
	local description_raw_filter
	local description_raw
	local url
	local found=0
	local existing_url

	if [[ -z "${ticket_id}" ]]; then
		echo "extract_pr_urls_from_ticket:: ticket_id is not set" >&2
		return 1
	fi

	if ! check_jira_dependencies; then
		return 1
	fi

	if ! ticket_json=$(acli jira workitem view "${ticket_id}" --json 2>/dev/null); then
		return 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		echo "extract_pr_urls_from_ticket:: jq is not installed or not in PATH" >&2
		return 1
	fi

	description_filter="$(
		cat <<'EOF'
.fields.description.content[]? | select(.type=="paragraph") | .content[]? | select(.type=="inlineCard") | .attrs.url
EOF
	)"
	if ! description_text=$(jq -r "${description_filter}" <<<"${ticket_json}" 2>/dev/null); then
		return 1
	fi

	while IFS= read -r url; do
		if [[ -n "${url}" ]] && [[ "${url}" =~ github\.com.*pull ]]; then
			pr_urls+=("${url}")
		fi
	done <<<"${description_text}"

	description_raw_filter="$(
		cat <<'EOF'
.fields.description.content[]? | select(.type=="codeBlock") | .content[0].text
EOF
	)"
	if description_raw=$(jq -r "${description_raw_filter}" <<<"${ticket_json}" 2>/dev/null); then
		if [[ -n "${description_raw}" ]]; then
			while IFS= read -r url; do
				if [[ -n "${url}" ]] && [[ "${url}" =~ github\.com.*pull ]]; then
					found=0
					for existing_url in "${pr_urls[@]}"; do
						if [[ "${existing_url}" == "${url}" ]]; then
							found=1
							break
						fi
					done
					if ((found == 0)); then
						pr_urls+=("${url}")
					fi
				fi
			done < <(echo "${description_raw}" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' 2>/dev/null || true)
		fi
	fi

	for url in "${pr_urls[@]}"; do
		echo "${url}"
	done

	return 0
}

# Gets JIRA ticket details and comments using Atlassian CLI
#
# Side Effects:
# - Outputs ticket details and comments to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
get_ticket_details() {
	if [[ -z "${TICKET_ID}" ]]; then
		echo "get_ticket_details:: ticket_id is not set" >&2
		return 1
	fi

	if ! get_ticket_details_for_id "${TICKET_ID}"; then
		return 1
	fi

	return 0
}

# Writes JIRA ticket details for a commit to files
#
# Inputs:
# - $1: output_path, output path directory
#
# Side Effects:
# - Creates ticket detail files in the output directory
#
# Returns:
# - 0 on success
# - 1 on failure
write_jira_details() {
	local output_path="$1"
	local ticket_ids
	local ticket_id
	local ticket_file

	if [[ -z "${COMMIT}" || -z "${output_path}" ]]; then
		echo "write_jira_details:: commit or output_path is not set" >&2
		return 1
	fi

	if [[ ! -d "${output_path}" ]]; then
		echo "write_jira_details:: Output path does not exist: ${output_path}" >&2
		return 1
	fi

	if ! check_jira_dependencies; then
		return 1
	fi

	if ! ticket_ids=$(extract_jira_tickets 2>/dev/null); then
		return 1
	fi

	if [[ -z "${ticket_ids}" ]]; then
		return 0
	fi

	while IFS= read -r ticket_id; do
		if [[ -n "${ticket_id}" ]]; then
			ticket_file="${output_path}/${ticket_id}.txt"
			if get_ticket_details_for_id "${ticket_id}" >"${ticket_file}" 2>/dev/null; then
				echo "write_jira_details:: Wrote ticket details to ${ticket_file}"
			fi
		fi
	done <<<"${ticket_ids}"

	return 0
}

# Writes JIRA ticket details for a commit to a single file
#
# Inputs:
# - COMMIT: Commit hash, from environment
# - JIRA_FILE: Output file path, from environment
# - REPO_PATH: Repository path, from environment
#
# Side Effects:
# - Writes all ticket details to the output file, always overwrites
#
# Returns:
# - 0 on success
# - 1 on failure
write_jira_details_to_file() {
	local commit_dir
	local ticket_ids
	local ticket_id

	if [[ -z "${COMMIT}" || -z "${JIRA_FILE}" ]]; then
		echo "write_jira_details_to_file:: commit or jira_file is not set" >&2
		return 1
	fi

	commit_dir=$(dirname "${JIRA_FILE}")
	if [[ ! -d "${commit_dir}" ]]; then
		echo "write_jira_details_to_file:: Commit directory does not exist: ${commit_dir}" >&2
		return 1
	fi

	if ! check_jira_dependencies; then
		return 1
	fi

	if ! ticket_ids=$(extract_jira_tickets 2>/dev/null); then
		return 1
	fi

	if [[ -z "${ticket_ids}" ]]; then
		return 0
	fi

	if ! : >"${JIRA_FILE}"; then
		echo "write_jira_details_to_file:: Failed to write to jira_file: ${JIRA_FILE}" >&2
		return 1
	fi

	while IFS= read -r ticket_id; do
		if [[ -n "${ticket_id}" ]]; then
			if get_ticket_details_for_id "${ticket_id}" >>"${JIRA_FILE}"; then
				printf '\n' >>"${JIRA_FILE}"
			else
				echo "write_jira_details_to_file:: Failed to fetch ticket: ${ticket_id}" >&2
			fi
		fi
	done <<<"${ticket_ids}"

	return 0
}

# Searches GitHub for commits referencing a JIRA ticket
#
# Inputs:
# - $1: ticket_id, JIRA ticket ID
#
# Side Effects:
# - Outputs commit information to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
search_github_commits_for_ticket() {
	local ticket_id="$1"
	local remote_info
	local repo_owner
	local repo_name
	local search_query
	local results
	local jq_filter

	if [[ -z "${ticket_id}" ]]; then
		echo "search_github_commits_for_ticket:: ticket_id is not set" >&2
		return 1
	fi

	if ! check_github_dependencies; then
		return 1
	fi

	if ! validate_git_repo; then
		return 1
	fi

	if ! remote_info=$(resolve_remote_owner_repo 2>/dev/null); then
		return 1
	fi

	repo_owner=$(echo "${remote_info}" | head -n 1)
	repo_name=$(echo "${remote_info}" | tail -n 1)

	if [[ -z "${repo_owner}" ]] || [[ -z "${repo_name}" ]]; then
		echo "search_github_commits_for_ticket:: Repository owner or name is not set" >&2
		return 1
	fi

	search_query="${ticket_id} repo:${repo_owner}/${repo_name} type:commit"
	if ! results=$(gh search commits --json sha,author,commit,url --limit 20 -- "${search_query}" 2>/dev/null); then
		echo "search_github_commits_for_ticket:: Failed to search commits" >&2
		return 1
	fi

	if [[ -z "${results}" ]] || [[ "${results}" == "[]" ]]; then
		echo "search_github_commits_for_ticket:: No commits found for ticket" >&2
		return 1
	fi

	jq_filter="$(
		cat <<'EOF'
.[] | "Commit: \(.sha)\nAuthor: \(.author.login // .commit.author.name)\nMessage: \(.commit.message | split("\n")[0])\nURL: \(.url)\n"
EOF
	)"
	if ! jq -r "${jq_filter}" <<<"${results}" 2>/dev/null; then
		echo "search_github_commits_for_ticket:: Failed to parse commit results" >&2
		return 1
	fi

	return 0
}

# Searches GitHub for pull requests referencing a JIRA ticket
#
# Inputs:
# - $1: ticket_id, JIRA ticket ID
#
# Side Effects:
# - Outputs pull request information to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
search_github_prs_for_ticket() {
	local ticket_id="$1"
	local remote_info
	local repo_owner
	local repo_name
	local search_query
	local results
	local jq_filter

	if [[ -z "${ticket_id}" ]]; then
		echo "search_github_prs_for_ticket:: ticket_id is not set" >&2
		return 1
	fi

	if ! check_github_dependencies; then
		return 1
	fi

	if ! validate_git_repo; then
		return 1
	fi

	if ! remote_info=$(resolve_remote_owner_repo 2>/dev/null); then
		return 1
	fi

	repo_owner=$(echo "${remote_info}" | head -n 1)
	repo_name=$(echo "${remote_info}" | tail -n 1)

	if [[ -z "${repo_owner}" ]] || [[ -z "${repo_name}" ]]; then
		echo "search_github_prs_for_ticket:: Repository owner or name is not set" >&2
		return 1
	fi

	search_query="${ticket_id} repo:${repo_owner}/${repo_name} type:pr"
	if ! results=$(gh search prs --json number,title,url,state,author --limit 20 -- "${search_query}" 2>/dev/null); then
		echo "search_github_prs_for_ticket:: Failed to search pull requests" >&2
		return 1
	fi

	if [[ -z "${results}" ]] || [[ "${results}" == "[]" ]]; then
		echo "search_github_prs_for_ticket:: No pull requests found for ticket" >&2
		return 1
	fi

	jq_filter="$(
		cat <<'EOF'
.[] | "PR #\(.number): \(.title)\nState: \(.state)\nAuthor: \(.author.login)\nURL: \(.url)\n"
EOF
	)"
	if ! jq -r "${jq_filter}" <<<"${results}" 2>/dev/null; then
		echo "search_github_prs_for_ticket:: Failed to parse pull request results" >&2
		return 1
	fi

	return 0
}

# Main entry point
jira_main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			return 0
			;;
		*)
			if [[ -z "${TICKET_ID}" ]]; then
				TICKET_ID="$1"
			else
				echo "jira_main:: Unknown option '$1'" >&2
				echo "jira_main:: Use '$(basename "$0") --help' for usage information" >&2
				return 1
			fi
			shift
			;;
		esac
	done

	if ! validate_required_args; then
		return 1
	fi

	if ! check_jira_dependencies; then
		return 1
	fi

	if ! validate_jira_auth; then
		return 1
	fi

	if ! get_ticket_details; then
		return 1
	fi

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	jira_main "$@"
	exit $?
fi
