#!/usr/bin/env bash
#
# GitHub helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
#

INVOLVEMENT_SCHEMA_VERSION="1"

# Returns whether a value is a GitHub username
#
# Inputs:
# - $1: candidate login
#
# Returns:
# - 0 when the value is a GitHub username
# - 1 otherwise
is_github_username() {
	local login="${1:-}"

	if [[ "${login}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		return 0
	fi

	return 1
}

# Sets GITHUB_USER from --github-user or a username-shaped AUTHOR
#
# Side Effects:
# - Sets GITHUB_USER when it can be derived from AUTHOR
#
# Returns:
# - 0 on success
# - 1 when a GitHub username cannot be resolved
set_github_user() {
	if [[ -n "${GITHUB_USER:-}" ]]; then
		if ! is_github_username "${GITHUB_USER}"; then
			echo "set_github_user:: GITHUB_USER '${GITHUB_USER}' is not a GitHub username" >&2
			return 1
		fi

		return 0
	fi

	if is_github_username "${AUTHOR:-}"; then
		GITHUB_USER="${AUTHOR}"
		return 0
	fi

	echo "set_github_user:: --github-user is required when --author is not a GitHub username" >&2

	return 1
}

# Validates GitHub CLI dependencies, authentication, and the author login
#
# Side Effects:
# - Sets GITHUB_USER via set_github_user
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

	if ! set_github_user; then
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

# Returns whether a commit-linked PR artifact should be refreshed
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

# Builds the involvement cache signature string
#
# Inputs:
# - $1: repository slug owner/repo
# - $2: GitHub login
# - $3: period start date
# - $4: period end date
#
# Outputs:
# - Signature string to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
involvement_signature() {
	local repo_slug="${1:-}"
	local login="${2:-}"
	local period_start="${3:-}"
	local period_end="${4:-}"

	if [[ -z "${repo_slug}" || -z "${login}" || -z "${period_start}" || -z "${period_end}" ]]; then
		echo "involvement_signature:: repo_slug, login, period_start, and period_end are required" >&2
		return 1
	fi

	printf 'v%s|%s|%s|%s|%s\n' \
		"${INVOLVEMENT_SCHEMA_VERSION}" \
		"${repo_slug}" \
		"${login}" \
		"${period_start}" \
		"${period_end}"

	return 0
}

# Returns whether involvement indexes match the current run
#
# A matching signature plus three valid JSON array files, including empty
# arrays, is treated as current.
#
# Inputs:
# - $1: analysis root path
# - $2: expected signature string
#
# Returns:
# - 0 when indexes are current
# - 1 when they should be refreshed
involvement_indexes_current() {
	local output_root="${1:-}"
	local expected="${2:-}"
	local prs_root="${output_root}/prs"
	local sig_file="${prs_root}/.signature"

	[[ -n "${output_root}" && -n "${expected}" ]] || return 1
	[[ -f "${sig_file}" ]] || return 1

	local actual
	if ! actual=$(<"${sig_file}"); then
		return 1
	fi

	[[ "${actual}" == "${expected}" ]] || return 1

	local role
	for role in merged reviewed commented; do
		local index_file="${prs_root}/${role}/index.json"
		[[ -f "${index_file}" ]] || return 1
		jq -e 'type == "array"' "${index_file}" >/dev/null 2>&1 || return 1
	done

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
# Refreshes all three roles together when the sidecar signature does not match
# the current repo, GitHub user, and date window. Empty arrays are valid cache
# hits. The signature is written only after every role search and index write
# succeeds.
#
# Inputs:
# - $1: analysis root path, typically OUTPUT_PATH
# - GITHUB_USER, PERIOD_START, PERIOD_END environment variables
#
# Side Effects:
# - Creates prs/{merged,reviewed,commented}/ directories
# - Writes index.json for each role
# - Writes prs/.signature after a successful refresh
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

	if [[ -z "${GITHUB_USER:-}" ]]; then
		echo "write_involvement_prs:: GITHUB_USER is not set" >&2
		return 1
	fi

	if [[ -z "${PERIOD_START:-}" || -z "${PERIOD_END:-}" ]]; then
		echo "write_involvement_prs:: PERIOD_START and PERIOD_END are required" >&2
		return 1
	fi

	local repo_slug
	repo_slug=$(resolve_remote_owner_repo) || return 1

	local expected_sig
	expected_sig=$(involvement_signature "${repo_slug}" "${GITHUB_USER}" \
		"${PERIOD_START}" "${PERIOD_END}") || return 1

	if involvement_indexes_current "${output_root}" "${expected_sig}"; then
		return 0
	fi

	local role
	local index_file
	local pr_data
	local fetch_failed=0
	for role in merged reviewed commented; do
		index_file="${output_root}/prs/${role}/index.json"

		if ! mkdir -p "${output_root}/prs/${role}" 2>/dev/null; then
			echo "write_involvement_prs:: Failed to create directory for role: ${role}" >&2
			return 1
		fi

		if ! pr_data=$(search_prs_by_involvement "${role}" "${GITHUB_USER}" "${repo_slug}"); then
			echo "write_involvement_prs:: Writing empty ${role} index, the fetch above failed" >&2
			pr_data="[]"
			fetch_failed=1
		fi

		if ! printf '%s\n' "${pr_data}" >"${index_file}" 2>/dev/null; then
			echo "write_involvement_prs:: Failed to write index: ${index_file}" >&2
			return 1
		fi
	done

	if [[ "${fetch_failed}" -ne 0 ]]; then
		rm -f "${output_root}/prs/.signature"
		return 0
	fi

	if ! printf '%s' "${expected_sig}" >"${output_root}/prs/.signature" 2>/dev/null; then
		echo "write_involvement_prs:: Failed to write involvement signature" >&2
		return 1
	fi

	return 0
}

# Reports that this library must be sourced, not executed
#
# Returns:
# - 1 always
main() {
	echo "github.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
