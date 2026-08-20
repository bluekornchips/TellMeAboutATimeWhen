#!/usr/bin/env bats
#
# Test suite for tools/lib/print.sh, summary card helpers only.
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	SCRIPT="${GIT_ROOT}/tools/lib/print.sh"
	if [[ ! -f "${SCRIPT}" ]]; then
		echo "setup:: Script not found: ${SCRIPT}" >&2

		return 1
	fi

	export GIT_ROOT
	export SCRIPT

	return 0
}

setup() {
	unset COLOR_RESET COLOR_COMMIT
	unset -f print_init print_section print_field print_paths 2>/dev/null || true

	# shellcheck disable=SC1090
	source "${SCRIPT}"
	print_init

	return 0
}

@test "print_section:: and field write ASCII summary to stdout" {
	local stdout_file
	local stderr_file
	stdout_file="$(mktemp)"
	stderr_file="$(mktemp)"
	COLUMNS=40
	export COLUMNS

	print_section >"${stdout_file}" 2>"${stderr_file}"
	print_field "Commit" "abc123" "commit" >>"${stdout_file}" 2>>"${stderr_file}"
	[[ ! -s "${stderr_file}" ]]
	grep -q -- "----------" "${stdout_file}"
	! grep -q "━" "${stdout_file}"
	grep -q "Commit:" "${stdout_file}"
	grep -q "abc123" "${stdout_file}"

	rm -f "${stdout_file}" "${stderr_file}"
}

@test "print_init:: always enables color" {
	print_init
	[[ -n "${COLOR_COMMIT}" ]]
	[[ -n "${COLOR_RESET}" ]]
}

@test "print_paths:: prints indented extra paths" {
	local stdout_file
	stdout_file="$(mktemp)"

	print_paths ".cursor/skills/one-one-one" ".cursor/skills/brag-book" >"${stdout_file}"
	grep -q "one-one-one" "${stdout_file}"
	grep -q "brag-book" "${stdout_file}"

	rm -f "${stdout_file}"
}
