#!/usr/bin/env bash
#
# GitHub helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
#

# Validates GitHub CLI dependencies, authentication, and the author login
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

	if ! resolve_github_login >/dev/null; then
		missing=1
	fi

	[[ "${missing}" -ne 0 ]] && return 1

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

	if [[ -z "${commit}" ]]; then
		echo "get_pr_details:: commit is not set" >&2
		return 1
	fi

	local full_hash
	if ! full_hash=$(git_cmd rev-parse "${commit}" 2>/dev/null); then
		echo "get_pr_details:: Failed to resolve commit hash: ${commit}" >&2
		return 1
	fi

	local repo_slug
	repo_slug=$(resolve_remote_owner_repo) || return 1

	local pr_list
	pr_list=$(gh api "/repos/${repo_slug}/commits/${full_hash}/pulls" 2>/dev/null) || return 1

	[[ -z "${pr_list}" || "${pr_list}" == "[]" || "${pr_list}" == "null" ]] && return 1

	local pr_numbers
	if ! pr_numbers=$(echo "${pr_list}" | jq -r '.[].number' 2>/dev/null); then
		echo "get_pr_details:: Failed to parse PR numbers" >&2
		return 1
	fi

	[[ -z "${pr_numbers}" ]] && return 1

	local pr_number
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

	[[ -z "${pr_file}" ]] && return 0
	[[ ! -f "${pr_file}" ]] && return 0

	local pr_file_contents
	if ! pr_file_contents=$(<"${pr_file}"); then
		return 0
	fi

	[[ "${pr_file_contents}" == "[]" ]] && return 0

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

	if [[ -z "${commit}" || -z "${pr_file}" ]]; then
		echo "write_pr_details:: commit or pr_file is not set" >&2
		return 1
	fi

	check_github_dependencies || return 1
	git_validate_repo || return 1

	local pr_data
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

# Resolves the GitHub login for involvement searches
#
# AUTHOR must be the GitHub username. There is no fallback to the authenticated
# account, so a run for another person never reports the caller's pull requests.
#
# Inputs:
# - AUTHOR environment variable
#
# Outputs:
# - GitHub login to stdout
#
# Returns:
# - 0 on success
# - 1 when AUTHOR is missing or is not a GitHub username
resolve_github_login() {
	if [[ -z "${AUTHOR:-}" ]]; then
		echo "resolve_github_login:: AUTHOR is not set" >&2
		return 1
	fi

	if [[ ! "${AUTHOR}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		echo "resolve_github_login:: AUTHOR '${AUTHOR}' is not a GitHub username" >&2
		echo "resolve_github_login:: Pass -a with the GitHub username when the github tool is enabled" >&2
		return 1
	fi

	printf '%s\n' "${AUTHOR}"

	return 0
}

# Searches pull requests for one involvement role in the configured period
#
# GitHub PR search has no merged-by qualifier, so the merged role lists merged
# pull requests in the window and filters on mergedBy locally.
#
# Inputs:
# - $1: role, merged|reviewed|commented
# - $2: GitHub login
# - $3: repository slug owner/repo
# - PERIOD_START and PERIOD_END environment variables
#
# Outputs:
# - JSON array of PR objects with involvement stamped to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
search_prs_by_involvement() {
	local role="${1:-}"
	local login="${2:-}"
	local repo_slug="${3:-}"

	if [[ -z "${role}" || -z "${login}" || -z "${repo_slug}" ]]; then
		echo "search_prs_by_involvement:: role, login, or repo_slug is not set" >&2
		return 1
	fi

	if [[ -z "${PERIOD_START:-}" || -z "${PERIOD_END:-}" ]]; then
		echo "search_prs_by_involvement:: PERIOD_START and PERIOD_END are required" >&2
		return 1
	fi

	local fields="number,title,url,state,author,createdAt,updatedAt,closedAt"
	local limit
	local query
	local selector
	case "${role}" in
	merged)
		# No server-side merged-by filter exists, so the whole merged window is
		# fetched and narrowed locally. Busy repos need a high limit.
		limit=1000
		query=(gh pr list --repo "${repo_slug}" --state merged --limit "${limit}"
			--search "merged:${PERIOD_START}..${PERIOD_END}"
			--json "${fields},mergedAt,mergedBy")
		# shellcheck disable=SC2016 # $login is a jq argument, not a shell variable
		selector='map(select(.mergedBy.login == $login))'
		;;
	reviewed)
		limit=100
		query=(gh search prs --repo "${repo_slug}" --limit "${limit}" --json "${fields}"
			--reviewed-by "${login}" --updated "${PERIOD_START}..${PERIOD_END}")
		selector='.'
		;;
	commented)
		limit=100
		query=(gh search prs --repo "${repo_slug}" --limit "${limit}" --json "${fields}"
			--commenter "${login}" --updated "${PERIOD_START}..${PERIOD_END}")
		selector='.'
		;;
	*)
		echo "search_prs_by_involvement:: Unknown role '${role}'" >&2
		return 1
		;;
	esac

	local error_file
	error_file=$(mktemp "${TMPDIR:-/tmp}/tellme-gh-XXXXXX") || return 1

	local query_output
	if ! query_output=$("${query[@]}" 2>"${error_file}"); then
		echo "search_prs_by_involvement:: Failed to fetch ${role} PRs for ${login}" >&2
		echo "search_prs_by_involvement:: $(tr '\n' ' ' <"${error_file}")" >&2
		rm -f "${error_file}"
		return 1
	fi
	rm -f "${error_file}"

	local fetched
	fetched=$(printf '%s\n' "${query_output:-[]}" | jq 'length' 2>/dev/null) || fetched=0
	if [[ "${fetched}" -ge "${limit}" ]]; then
		echo "search_prs_by_involvement:: ${role} hit the ${limit} result limit, results may be incomplete" >&2
	fi

	local stamped
	if ! stamped=$(printf '%s\n' "${query_output:-[]}" |
		jq -c --arg involvement "${role}" --arg login "${login}" \
			"${selector}"' | unique_by(.number) | map(. + {involvement: $involvement})' 2>/dev/null); then
		echo "search_prs_by_involvement:: Failed to format ${role} results" >&2
		return 1
	fi

	printf '%s\n' "${stamped}"

	return 0
}

# Writes involvement PR indexes under OUTPUT_PATH/prs/{role}/index.json
#
# A role whose search fails gets an empty index so one API miss does not
# abort the remaining roles.
#
# Inputs:
# - $1: analysis root path, typically OUTPUT_PATH
# - AUTHOR, PERIOD_START, PERIOD_END environment variables
#
# Side Effects:
# - Creates prs/{merged,reviewed,commented}/ directories
# - Writes index.json for each role
#
# Returns:
# - 0 on success
# - 1 on dependency, login, or path errors
write_involvement_prs() {
	local output_root="${1:-}"

	if [[ -z "${output_root}" ]]; then
		echo "write_involvement_prs:: output_root is not set" >&2
		return 1
	fi

	check_github_dependencies || return 1
	git_validate_repo || return 1

	local login
	login=$(resolve_github_login) || return 1

	local repo_slug
	repo_slug=$(resolve_remote_owner_repo) || return 1

	local role
	local index_file
	local pr_data
	for role in merged reviewed commented; do
		index_file="${output_root}/prs/${role}/index.json"

		if ! mkdir -p "${output_root}/prs/${role}" 2>/dev/null; then
			echo "write_involvement_prs:: Failed to create directory for role: ${role}" >&2
			return 1
		fi

		needs_pr_refresh "${index_file}" || continue

		if ! pr_data=$(search_prs_by_involvement "${role}" "${login}" "${repo_slug}"); then
			echo "write_involvement_prs:: Writing empty ${role} index, the fetch above failed" >&2
			pr_data="[]"
		fi

		if ! printf '%s\n' "${pr_data}" >"${index_file}" 2>/dev/null; then
			echo "write_involvement_prs:: Failed to write index: ${index_file}" >&2
			return 1
		fi
	done

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	echo "github.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	exit 1
fi
