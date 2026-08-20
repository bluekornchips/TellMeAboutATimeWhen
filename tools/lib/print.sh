#!/usr/bin/env bash
#
# Summary card helpers for tell-me-about.sh result output.
# Colors, section separators, and labeled fields only.
#

if declare -F print_init >/dev/null 2>&1; then
	return 0
fi

COLOR_RESET=""
COLOR_BOLD=""
COLOR_COMMIT=""
COLOR_JIRA=""
COLOR_GITHUB=""
COLOR_PATH=""
COLOR_SEPARATOR=""
COLOR_LABEL=""

# Initializes color globals, always enabled
#
# Returns:
# - 0 always
print_init() {
	COLOR_RESET=$'\033[0m'
	COLOR_BOLD=$'\033[1m'
	COLOR_COMMIT=$'\033[38;5;39m'
	COLOR_JIRA=$'\033[38;5;208m'
	COLOR_GITHUB=$'\033[38;5;141m'
	COLOR_PATH=$'\033[38;5;244m'
	COLOR_SEPARATOR=$'\033[38;5;240m'
	COLOR_LABEL=$'\033[1;38;5;255m'

	return 0
}

# Prints an ASCII separator line
#
# Side Effects:
# - Writes a separator line to stdout
#
# Returns:
# - 0 always
print_section() {
	local width="${COLUMNS:-80}"
	local i

	if ! [[ "${width}" =~ ^[0-9]+$ ]]; then
		width=80
	elif [[ "${width}" -gt 120 ]]; then
		width=120
	elif [[ "${width}" -lt 20 ]]; then
		width=20
	fi

	printf '\n'
	printf '%s' "${COLOR_SEPARATOR}"
	for ((i = 0; i < width; i++)); do
		printf '-'
	done
	printf '%s\n' "${COLOR_RESET}"

	return 0
}

# Prints a labeled summary field
#
# Inputs:
# - $1: label
# - $2: value
# - $3: role, commit|jira|github|path|default
#
# Side Effects:
# - Writes one labeled field line to stdout
#
# Returns:
# - 0 always
print_field() {
	local label="${1:-}"
	local value="${2:-}"
	local role="${3:-default}"
	local color=""
	local padded_label

	if [[ -z "${label}" ]]; then
		return 0
	fi

	case "${role}" in
	commit) color="${COLOR_COMMIT}${COLOR_BOLD}" ;;
	jira) color="${COLOR_JIRA}" ;;
	github) color="${COLOR_GITHUB}" ;;
	*) color="${COLOR_PATH}" ;;
	esac

	padded_label=$(printf '%-8s' "${label}:")
	printf '%s%s%s %s%s%s\n' \
		"${COLOR_LABEL}" "${padded_label}" "${COLOR_RESET}" \
		"${color}" "${value}" "${COLOR_RESET}"

	return 0
}

# Prints additional path values indented under the previous field
#
# Inputs:
# - $@: path values
#
# Side Effects:
# - Writes indented path lines to stdout
#
# Returns:
# - 0 always
print_paths() {
	local path_value

	for path_value in "$@"; do
		if [[ -n "${path_value}" ]]; then
			printf '         %s%s%s\n' "${COLOR_PATH}" "${path_value}" "${COLOR_RESET}"
		fi
	done

	return 0
}

print_init || true
