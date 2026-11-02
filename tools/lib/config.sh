#!/usr/bin/env bash
#
# tell-me-about.json resolve, path expand, and load helpers
#

declare -F resolve_tellme_config >/dev/null 2>&1 && return 0

# Resolves the tell-me-about.json path
#
# Outputs:
# - Config path on stdout
#
# Returns:
# - 0 always
resolve_tellme_config() {
	if [[ -n "${TELLME_CONFIG:-}" ]]; then
		echo "${TELLME_CONFIG}"
		return 0
	fi

	local lib_dir
	local root
	lib_dir=$(dirname "${BASH_SOURCE[0]}")
	if [[ "${lib_dir}" != /* ]]; then
		lib_dir="$(cd "${lib_dir}" && pwd)"
	fi
	root="$(cd "${lib_dir}/../.." && pwd)"

	echo "${root}/tell-me-about.json"

	return 0
}

# Expands leading ~ in a repo path and requires an absolute result
#
# Inputs:
# - $1: raw path from JSON
#
# Outputs:
# - Expanded absolute path on stdout
#
# Returns:
# - 0 on success
# - 1 when expansion fails or the result is not absolute
expand_repo_path() {
	local raw="${1:-}"

	if [[ -z "${raw}" ]]; then
		echo "expand_repo_path:: path is required" >&2
		return 1
	fi

	# shellcheck disable=SC2016 # literal $( detects command substitution in paths
	local dollar_paren='$('
	local backtick
	printf -v backtick '%s' '`'
	if [[ "${raw}" == *"${dollar_paren}"* || "${raw}" == *"${backtick}"* ]]; then
		echo "expand_repo_path:: path must not contain command substitution" >&2
		return 1
	fi

	local path="${raw}"
	local tilde='~'
	local tilde_slash="${tilde}/"
	if [[ "${path}" == "${tilde}" || "${path}" == "${tilde_slash}"* ]]; then
		if [[ -z "${HOME:-}" ]]; then
			echo "expand_repo_path:: HOME is not set" >&2
			return 1
		fi
		if [[ "${path}" == "${tilde}" ]]; then
			path="${HOME}"
		else
			path="${HOME}/${path:2}"
		fi
	fi

	if [[ "${path}" != /* ]]; then
		echo "expand_repo_path:: path must resolve to an absolute POSIX path: ${raw}" >&2
		return 1
	fi

	echo "${path}"

	return 0
}

# Loads repos and optional identity fields from tell-me-about.json
#
# Inputs:
# - $1: config file path
#
# Side Effects:
# - Appends expanded path:branch entries to REPOS
# - Sets AUTHOR and GITHUB_USER when unset and present in JSON
#
# Returns:
# - 0 on success
# - 1 on missing file, invalid JSON, or invalid repos
load_tellme_config() {
	local config_file="${1:-}"

	if [[ -z "${config_file}" || ! -f "${config_file}" ]]; then
		echo "load_tellme_config:: config file is required: ${config_file}" >&2
		return 1
	fi

	require_cmd jq load_tellme_config || return 1

	if ! jq -e '
		type == "object" and
		(.repos | type == "array" and length > 0) and
		all(.repos[];
			(.path | type == "string" and length > 0) and
			(.branch | type == "string" and length > 0)
		)
	' "${config_file}" >/dev/null 2>&1; then
		echo "load_tellme_config:: ${config_file} needs repos with path and branch" >&2
		return 1
	fi

	local raw_path branch expanded
	while IFS= read -r raw_path; do
		if ! IFS= read -r branch; then
			echo "load_tellme_config:: ${config_file} needs repos with path and branch" >&2
			return 1
		fi
		expanded=$(expand_repo_path "${raw_path}") || return 1
		REPOS+=("${expanded}:${branch}")
	done < <(jq -r '.repos[] | .path, .branch' "${config_file}")

	if [[ "${#REPOS[@]}" -eq 0 ]]; then
		echo "load_tellme_config:: ${config_file} needs repos with path and branch" >&2
		return 1
	fi

	local value
	value=$(jq -r '.author // empty' "${config_file}")
	if [[ -z "${AUTHOR:-}" && -n "${value}" ]]; then
		AUTHOR="${value}"
	fi

	value=$(jq -r '.github_user // empty' "${config_file}")
	if [[ -z "${GITHUB_USER:-}" && -n "${value}" ]]; then
		GITHUB_USER="${value}"
	fi

	return 0
}
