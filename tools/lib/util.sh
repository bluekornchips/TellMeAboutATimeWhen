#!/usr/bin/env bash
#
# Shared micro-helpers for tell-me-about tools and orchestrator.
#

if declare -F require_cmd >/dev/null 2>&1; then
	return 0
fi

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
	local item

	shift || true

	for item in "$@"; do
		if [[ "${item}" == "${needle}" ]]; then
			return 0
		fi
	done

	return 1
}
