#!/usr/bin/env bash
#
# Jira helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
#

# Validates Atlassian CLI dependency availability
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

# Gets ticket details for a specific ticket ID
#
# Inputs:
# - $1: ticket_id, JIRA ticket ID
#
# Outputs:
# - Ticket details and comments to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
get_ticket_details_for_id() {
	local ticket_id="$1"

	if [[ -z "${ticket_id}" ]]; then
		echo "get_ticket_details_for_id:: ticket_id is not set" >&2
		return 1
	fi

	local ticket_output
	if ! ticket_output=$(acli jira workitem view "${ticket_id}" 2>/dev/null); then
		echo "get_ticket_details_for_id:: Failed to retrieve ticket details for: ${ticket_id}" >&2
		return 1
	fi

	echo "${ticket_output}"

	local comments_output
	if comments_output=$(acli jira workitem comment list --key "${ticket_id}" 2>/dev/null); then
		if [[ -n "${comments_output}" ]]; then
			echo "${comments_output}"
		fi
	else
		echo "get_ticket_details_for_id:: Failed to retrieve comments for: ${ticket_id}" >&2
	fi

	return 0
}

# Writes JIRA ticket details for a commit to a single file
#
# Inputs:
# - $1: commit hash
# - $2: output file
#
# Side Effects:
# - Writes ticket details to the output file when tickets are found
# - Does not create an empty file when no tickets are found
#
# Returns:
# - 0 on success
# - 1 on failure
write_jira_details() {
	local commit="${1:-}"
	local jira_file="${2:-}"

	if [[ -z "${commit}" || -z "${jira_file}" ]]; then
		echo "write_jira_details:: commit or jira_file is not set" >&2
		return 1
	fi

	local commit_dir
	commit_dir=$(dirname "${jira_file}")
	if [[ ! -d "${commit_dir}" ]]; then
		echo "write_jira_details:: Commit directory does not exist: ${commit_dir}" >&2
		return 1
	fi

	check_jira_dependencies || return 1
	validate_jira_auth || return 1
	write_ticket_details "${commit}" "${jira_file}" get_ticket_details_for_id write_jira_details || return 1

	return 0
}

# Reports that this library must be sourced, not executed
#
# Returns:
# - 1 always
main() {
	echo "jira.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
