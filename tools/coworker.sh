#!/usr/bin/env bash
#
# Coworker helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
#

# Resolves the Cursor MCP config file path
#
# Outputs:
# - Config path to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
resolve_mcp_config() {
	if [[ -n "${COWORKER_MCP_CONFIG}" ]]; then
		echo "${COWORKER_MCP_CONFIG}"
		return 0
	fi

	if [[ -n "${HOME}" && -f "${HOME}/.cursor/mcp.json" ]]; then
		echo "${HOME}/.cursor/mcp.json"
		return 0
	fi

	echo "resolve_mcp_config:: Coworker MCP config not found. Expected ${HOME}/.cursor/mcp.json" >&2

	return 1
}

# Validates jq is available
#
# Returns:
# - 0 on success
# - 1 on failure
check_coworker_dependencies() {
	if ! command -v jq >/dev/null 2>&1; then
		echo "check_coworker_dependencies:: jq is required but is not installed" >&2
		return 1
	fi

	return 0
}

# Checks that a Coworker MCP server is present in the config file
#
# Inputs:
# - $1: mcp_config_path
#
# Returns:
# - 0 on success
# - 1 on failure
check_coworker_mcp() {
	local mcp_config="$1"

	if [[ -z "${mcp_config}" ]]; then
		echo "check_coworker_mcp:: mcp_config_path is required" >&2
		return 1
	fi

	if [[ ! -f "${mcp_config}" ]]; then
		echo "check_coworker_mcp:: Coworker MCP is not configured. Missing file: ${mcp_config}" >&2
		return 1
	fi

	if ! jq -e '[((.mcpServers // .) | keys[]) | select(test("coworker"; "i"))] | length > 0' "${mcp_config}" >/dev/null 2>&1; then
		echo "check_coworker_mcp:: Coworker MCP is not configured in ${mcp_config}" >&2
		return 1
	fi

	return 0
}

# Creates the meetings directory and prints the coworker summary card
#
# Inputs:
# - $1: meetings directory path
# - $2: period start date
# - $3: period end date
#
# Side Effects:
# - Creates meetings_dir when missing
# - Writes meetings path, window, and skill paths to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
write_meetings_stub() {
	local meetings_dir="${1:-}"
	local period_start="${2:-}"
	local period_end="${3:-}"

	if [[ -z "${meetings_dir}" ]]; then
		echo "write_meetings_stub:: meetings_dir is not set" >&2
		return 1
	fi

	if [[ -z "${period_start}" || -z "${period_end}" ]]; then
		echo "write_meetings_stub:: period_start and period_end are required" >&2
		return 1
	fi

	if ! mkdir -p "${meetings_dir}" 2>/dev/null; then
		echo "write_meetings_stub:: Failed to create meetings directory: ${meetings_dir}" >&2
		return 1
	fi

	print_section
	check_coworker_dependencies || return 1
	local mcp_config
	mcp_config=$(resolve_mcp_config) || return 1
	if ! check_coworker_mcp "${mcp_config}"; then
		echo "write_meetings_stub:: Coworker MCP is not configured" >&2
		return 1
	fi

	print_field "Meetings" "${meetings_dir}" "commit"
	print_field "Window" "${period_start} to ${period_end}" "path"
	print_field "Parent" ".cursor/skills/tell-me-about-a-time-when" "path"
	print_field "Child" ".cursor/skills/weekly-update" "path"
	print_paths \
		".cursor/skills/one-one-one" \
		".cursor/skills/brag-book" \
		".cursor/skills/monthly-update"

	return 0
}

# Reports that this library must be sourced, not executed
#
# Returns:
# - 1 always
main() {
	echo "coworker.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
