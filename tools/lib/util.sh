#!/usr/bin/env bash
#
# Shared micro-helpers for tell-me-about tools and orchestrator.
#

declare -F require_cmd >/dev/null 2>&1 && return 0

# Checks that a command exists on PATH
#
# Inputs:
# - $1: command name
# - $2: error message prefix, optional, defaults to require_cmd
#
# Returns:
# - 0 when the command is available
# - 1 when missing
require_cmd() {
	local cmd="${1:-}"
	local prefix="${2:-require_cmd}"

	if [[ -z "${cmd}" ]]; then
		echo "${prefix}:: command name is required" >&2
		return 1
	fi

	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "${prefix}:: ${cmd} is required but is not installed" >&2
		return 1
	fi

	return 0
}

# Returns whether a needle appears in the remaining arguments
#
# Inputs:
# - $1: needle
# - $@: haystack values after the needle
#
# Returns:
# - 0 when found
# - 1 when missing
array_contains() {
	local needle="${1:-}"

	shift || true

	local item
	for item in "$@"; do
		[[ "${item}" == "${needle}" ]] && return 0
	done

	return 1
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

	local ticket_ids=()
	local ticket_id
	while [[ "${commit_message}" =~ ([A-Z][A-Z0-9]*-[0-9]+) ]]; do
		ticket_id="${BASH_REMATCH[1]}"
		if ! array_contains "${ticket_id}" "${ticket_ids[@]}"; then
			ticket_ids+=("${ticket_id}")
		fi
		commit_message="${commit_message#*"${BASH_REMATCH[1]}"}"
	done

	for ticket_id in "${ticket_ids[@]}"; do
		echo "${ticket_id}"
	done

	return 0
}

# Returns whether a text artifact should be refreshed
#
# Inputs:
# - $1: artifact path
#
# Returns:
# - 0 when refresh is needed
# - 1 when the existing file can be kept
needs_text_refresh() {
	local artifact_file="${1:-}"

	[[ -z "${artifact_file}" || ! -s "${artifact_file}" ]] && return 0

	return 1
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
#
# Returns:
# - 0 on success
# - 1 on failure
write_ticket_details() {
	local commit="${1:-}"
	local output_file="${2:-}"
	local fetch_fn="${3:-}"
	local caller="${4:-write_ticket_details}"

	if [[ -z "${commit}" || -z "${output_file}" ]]; then
		echo "${caller}:: commit or output file is not set" >&2
		return 1
	fi

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

	if [[ -z "${ticket_ids}" ]]; then
		return 0
	fi

	if ! : >"${output_file}"; then
		echo "${caller}:: Failed to write to output file: ${output_file}" >&2
		return 1
	fi

	local ticket_id
	local wrote=0
	while IFS= read -r ticket_id; do
		if [[ -n "${ticket_id}" ]]; then
			if "${fetch_fn}" "${ticket_id}" >>"${output_file}"; then
				printf '\n' >>"${output_file}"
				wrote=1
			else
				echo "${caller}:: Failed to fetch: ${ticket_id}" >&2
			fi
		fi
	done <<<"${ticket_ids}"

	if [[ "${wrote}" -eq 0 ]]; then
		rm -f "${output_file}"
	fi

	return 0
}
