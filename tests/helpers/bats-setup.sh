#!/usr/bin/env bash
#
# Shared Bats bootstrap for tool and orchestrator suites.
#

# Resolves repo root and common paths for a relative script
#
# Inputs:
# - $1: script path relative to GIT_ROOT, e.g. tools/github.sh
#
# Side Effects:
# - Sets and exports GIT_ROOT, SCRIPT, HELPER
#
# Returns:
# - 0 on success
# - 1 on failure
bats_resolve_paths() {
	local script_rel="${1:-}"

	if [[ -z "${script_rel}" ]]; then
		echo "bats_resolve_paths:: script relative path is required" >&2
		return 1
	fi

	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	if [[ -z "${GIT_ROOT}" ]]; then
		echo "bats_resolve_paths:: Failed to get git root" >&2
		return 1
	fi

	SCRIPT="${GIT_ROOT}/${script_rel}"
	HELPER="${GIT_ROOT}/tests/helpers/repo.sh"

	if [[ ! -f "${SCRIPT}" ]]; then
		echo "bats_resolve_paths:: Script not found: ${SCRIPT}" >&2
		return 1
	fi

	export GIT_ROOT
	export SCRIPT
	export HELPER

	return 0
}

# Unsets library sentinel functions so sourced libs reinitialize
#
# Returns:
# - 0 always
bats_unset_load_guards() {
	unset -f print_init print_section print_field print_paths 2>/dev/null || true
	unset -f require_cmd array_contains 2>/dev/null || true
	unset -f git_cmd resolve_remote_owner_repo git_validate_repo 2>/dev/null || true
	unset -f parse_date determine_period_dates sanitize_names \
		append_unique_commit collect_merge_commits_for_author get_commits write_commit_details \
		2>/dev/null || true

	return 0
}

# Sources shared libs and an optional tool script
#
# Inputs:
# - $1: optional tool script path; when set, sourced with the direct-run guard
#
# Side Effects:
# - Sources print, util, and git libs
# - Optionally sources the tool script
#
# Returns:
# - 0 on success
# - 1 on failure
bats_source_libs() {
	local tool_script="${1:-}"

	bats_unset_load_guards

	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tools/lib/print.sh"
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tools/lib/util.sh"
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tools/lib/git.sh"

	if [[ -n "${tool_script}" ]]; then
		set +e
		# shellcheck disable=SC1090
		source "${tool_script}" || true
		set -e
	fi

	print_init

	return 0
}

# Asserts a sourced-only tool rejects direct execution
#
# Inputs:
# - $1: script path
#
# Returns:
# - 0 on success
# - 1 on failure
assert_rejects_direct_execution() {
	local script_path="${1:-}"
	local status
	local output

	if [[ -z "${script_path}" ]]; then
		echo "assert_rejects_direct_execution:: script_path is required" >&2
		return 1
	fi

	output=$("${script_path}" 2>&1) && status=0 || status=$?
	if [[ "${status}" -ne 1 ]]; then
		echo "assert_rejects_direct_execution:: expected exit 1, got ${status}" >&2
		return 1
	fi
	if ! echo "${output}" | grep -q "do not run it directly"; then
		echo "assert_rejects_direct_execution:: missing direct-run message" >&2
		return 1
	fi

	return 0
}
