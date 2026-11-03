#!/usr/bin/env bash
#
# Ticket ID extraction and subject-prefix matching for commits and PR titles.
#

# Extracts unique KEY-123 identifiers from the first TICKET_PREFIX_LEN chars
#
# Matching is case-insensitive. IDs are printed uppercase.
#
# Inputs:
# - $1: message text, commit subject, or PR title
#
# Outputs:
# - Ticket IDs to stdout, one per line, uppercase
#
# Returns:
# - 0 on success
# - 1 when message is empty
extract_ticket_ids_from_text() {
	local message="${1:-}"

	if [[ -z "${message}" ]]; then
		echo "extract_ticket_ids_from_text:: message is not set" >&2
		return 1
	fi

	local prefix_len="${TICKET_PREFIX_LEN:-64}"
	local scan_text
	scan_text="$(printf '%s' "${message:0:${prefix_len}}" | tr '[:lower:]' '[:upper:]')"

	local ticket_ids=()
	local ticket_id
	while [[ "${scan_text}" =~ ([A-Z][A-Z0-9]*-[0-9]+) ]]; do
		ticket_id="${BASH_REMATCH[1]}"
		scan_text="${scan_text#*"${ticket_id}"}"
		if array_contains "${ticket_id}" "${ticket_ids[@]}"; then
			continue
		fi
		ticket_ids+=("${ticket_id}")
		echo "${ticket_id}"
	done

	return 0
}

# Returns whether a subject matches the loose type-scope prefix
#
# Checks only the first TICKET_PREFIX_LEN characters. Allows bug, ticket scopes,
# and : , or whitespace after the scope.
#
# Inputs:
# - $1: commit subject or PR title
#
# Returns:
# - 0 when the prefix matches
# - 1 when missing or malformed
validate_subject_prefix() {
	local title="${1:-}"

	if [[ -z "${title}" ]]; then
		echo "validate_subject_prefix:: title is not set" >&2
		return 1
	fi

	local subject_types=(build bug chore ci docs feat fix perf refactor revert style test)
	if [[ -n "${TICKET_SUBJECT_TYPES+x}" ]]; then
		subject_types=("${TICKET_SUBJECT_TYPES[@]}")
	fi

	local prefix_len="${TICKET_PREFIX_LEN:-64}"
	local prefix_lc
	prefix_lc="$(printf '%s' "${title:0:${prefix_len}}" | tr '[:upper:]' '[:lower:]')"

	local types_pattern
	types_pattern="$(printf '%s|' "${subject_types[@]}")"
	types_pattern="${types_pattern%|}"

	if ! printf '%s\n' "${prefix_lc}" | grep -Eq "^(${types_pattern})\\([^)]+\\)!?([,:]|[[:space:]])"; then
		echo "validate_subject_prefix:: prefix must match type-scope then : , or space" >&2
		echo "validate_subject_prefix:: allowed types: ${subject_types[*]}" >&2
		return 1
	fi

	return 0
}

# Extracts unique KEY-123 identifiers from a commit message
#
# Inputs:
# - $1: commit hash
#
# Outputs:
# - Ticket IDs to stdout, one per line
#
# Returns:
# - 0 on success
# - 1 on failure
extract_ticket_ids() {
	local commit="${1:-}"

	if [[ -z "${commit}" ]]; then
		echo "extract_ticket_ids:: commit is not set" >&2
		return 1
	fi

	local commit_message
	if ! commit_message=$(git_cmd log -1 --format="%B" "${commit}" 2>/dev/null); then
		echo "extract_ticket_ids:: Failed to get commit message for ${commit}" >&2
		return 1
	fi

	extract_ticket_ids_from_text "${commit_message}" || return 1

	return 0
}

# Writes fetched ticket details for IDs found in a commit message
#
# Inputs:
# - $1: commit hash
# - $2: output file
# - $3: fetch function name, called with one ticket ID
# - $4: caller name for error prefixes
#
# Side Effects:
# - Writes ticket details to the output file when tickets are found
# - Does not create an empty file when no tickets are found
# - Logs hard fetch failures, status 1, and stays quiet on status 2 not-found
#
# Returns:
# - 0 on success, including quiet not-found misses with no hard failures
# - 1 when setup fails or any fetch returns status 1
write_ticket_details() {
	local commit="${1:-}"
	local output_file="${2:-}"
	local caller="${4:-write_ticket_details}"

	if [[ -z "${commit}" || -z "${output_file}" ]]; then
		echo "${caller}:: commit or output file is not set" >&2
		return 1
	fi

	local fetch_fn="${3:-}"
	if [[ -z "${fetch_fn}" ]]; then
		echo "${caller}:: fetch function is not set" >&2
		return 1
	fi

	local commit_dir
	commit_dir=$(dirname "${output_file}")
	if [[ ! -d "${commit_dir}" ]]; then
		echo "${caller}:: Commit directory does not exist: ${commit_dir}" >&2
		return 1
	fi

	local ticket_ids
	ticket_ids=$(extract_ticket_ids "${commit}" 2>/dev/null) || return 1
	[[ -z "${ticket_ids}" ]] && return 0

	if ! : >"${output_file}"; then
		echo "${caller}:: Failed to write to output file: ${output_file}" >&2
		return 1
	fi

	local wrote=0
	local hard_failed=0
	local fetch_status
	local ticket_id
	while IFS= read -r ticket_id; do
		[[ -z "${ticket_id}" ]] && continue

		if "${fetch_fn}" "${ticket_id}" >>"${output_file}"; then
			printf '\n' >>"${output_file}"
			wrote=1
		else
			fetch_status=$?
			if [[ "${fetch_status}" -eq 1 ]]; then
				echo "${caller}:: Failed to fetch: ${ticket_id}" >&2
				hard_failed=1
			fi
		fi
	done <<<"${ticket_ids}"

	if [[ "${wrote}" -eq 0 ]]; then
		rm -f "${output_file}"
	fi

	[[ "${hard_failed}" -ne 0 ]] && return 1

	return 0
}

# Reports that this library must be sourced, not executed
#
# Returns:
# - 1 always
main() {
	echo "tickets.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
