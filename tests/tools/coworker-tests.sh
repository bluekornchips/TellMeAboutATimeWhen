#!/usr/bin/env bats
#
# Test suite for tools/coworker.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/coworker.sh" || return 1

	return 0
}

setup() {
	TEST_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
	export TEST_DIR
	export COWORKER_MCP_CONFIG="${TEST_DIR}/mcp.json"
	cd "${GIT_ROOT}" || return 1

	cat >"${COWORKER_MCP_CONFIG}" <<'JSON'
{
  "mcpServers": {
    "gandalf": {"command": "true"},
    "coworker": {"type": "http", "url": "https://odin.coworker.ai/mcp"}
  }
}
JSON

	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	bats_source_libs "${SCRIPT}"

	return 0
}

@test "check_coworker_dependencies:: fails when jq is not installed" {
	command() {
		if [[ "$1" == "-v" && "$2" == "jq" ]]; then
			return 1
		fi
		command "$@"
	}

	run check_coworker_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "jq is required"

	unset -f command
}

@test "check_coworker_mcp:: succeeds when coworker server is present" {
	run check_coworker_mcp "${COWORKER_MCP_CONFIG}"
	[[ "$status" -eq 0 ]]
}

@test "check_coworker_mcp:: fails when coworker server is missing" {
	cat >"${COWORKER_MCP_CONFIG}" <<'JSON'
{"mcpServers": {"gandalf": {"command": "true"}}}
JSON

	run check_coworker_mcp "${COWORKER_MCP_CONFIG}"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "not configured"
}

@test "check_coworker_mcp:: fails when config file is missing" {
	run check_coworker_mcp "${TEST_DIR}/missing.json"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Missing file"
}

@test "resolve_mcp_config:: uses COWORKER_MCP_CONFIG when set" {
	run resolve_mcp_config
	[[ "$status" -eq 0 ]]
	[[ "$output" == "${COWORKER_MCP_CONFIG}" ]]
}

@test "write_meetings_stub:: creates directory and prints skill paths" {
	local meetings_dir="${TEST_DIR}/meetings"

	run write_meetings_stub "${meetings_dir}" "2026-08-01" "2026-08-07"
	[[ "$status" -eq 0 ]]
	[[ -d "${meetings_dir}" ]]
	echo "$output" | grep -q "Meetings:.*${meetings_dir}"
	echo "$output" | grep -q "Window:.*2026-08-01 to 2026-08-07"
	echo "$output" | grep -q "weekly-update"
	echo "$output" | grep -q "one-one-one"
	echo "$output" | grep -q "brag-book"
	echo "$output" | grep -q "monthly-update"
}

@test "integration:: rejects direct script execution" {
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	run assert_rejects_direct_execution "${SCRIPT}"
	[[ "$status" -eq 0 ]]
}
