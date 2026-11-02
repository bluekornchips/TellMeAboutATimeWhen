#!/usr/bin/env bats
#
# Test suite for tools/lib/config.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/lib/config.sh" || return 1
	# shellcheck disable=SC1090
	source "${HELPER}"
	init_shared_fixtures || return 1

	return 0
}

setup() {
	TEST_DIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
	export TEST_DIR
	cd "${GIT_ROOT}" || return 1
	# shellcheck disable=SC1090
	source "${HELPER}"
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	bats_source_libs
	unset AUTHOR GITHUB_USER TELLME_CONFIG
	REPOS=()

	return 0
}

@test "resolve_tellme_config:: uses TELLME_CONFIG when set" {
	TELLME_CONFIG="${TEST_DIR}/custom.json"
	export TELLME_CONFIG

	run resolve_tellme_config
	[[ "${status}" -eq 0 ]]
	[[ "${output}" == "${TELLME_CONFIG}" ]]
}

@test "resolve_tellme_config:: defaults beside the project root" {
	unset TELLME_CONFIG

	run resolve_tellme_config
	[[ "${status}" -eq 0 ]]
	[[ "${output}" == "${GIT_ROOT}/tell-me-about.json" ]]
}

@test "expand_repo_path:: expands tilde and rejects unsafe values" {
	local abs_path="${TEST_DIR}/absolute repo/app"
	HOME="${TEST_DIR}/home"
	export HOME
	mkdir -p "${abs_path}" "${HOME}/repos/app"

	run expand_repo_path "${abs_path}"
	[[ "${status}" -eq 0 ]]
	[[ "${output}" == "${abs_path}" ]]

	run expand_repo_path "~/repos/app"
	[[ "${status}" -eq 0 ]]
	[[ "${output}" == "${HOME}/repos/app" ]]

	run expand_repo_path '$(pwd)/repo'
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "command substitution"

	run expand_repo_path "\$HOME/repos/app"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "path must resolve to an absolute POSIX path"

	run expand_repo_path "relative/path"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "path must resolve to an absolute POSIX path"
}

@test "load_tellme_config:: rejects missing and invalid configs" {
	run load_tellme_config "${TEST_DIR}/missing.json"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "config file is required"

	cat <<'EOF' >"${TEST_DIR}/bad.json"
{"repos": [
EOF
	run load_tellme_config "${TEST_DIR}/bad.json"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "needs repos with path and branch"

	cat <<'EOF' >"${TEST_DIR}/incomplete.json"
{
  "repos": [
    {"path": "/repo-one", "branch": "main"},
    {"path": "/repo-two"}
  ]
}
EOF
	run load_tellme_config "${TEST_DIR}/incomplete.json"
	[[ "${status}" -ne 0 ]]
	echo "${output}" | grep -q "needs repos with path and branch"
}

@test "load_tellme_config:: loads repos and optional identity fields" {
	HOME="${TEST_DIR}/home"
	export HOME
	mkdir -p "${HOME}/from-tilde" "${TEST_DIR}/absolute-repo"

	cat <<EOF >"${TEST_DIR}/good.json"
{
  "author": "Config Author",
  "github_user": "configuser",
  "repos": [
    {"path": "${TEST_DIR}/absolute-repo", "branch": "master"},
    {"path": "~/from-tilde", "branch": "main"}
  ]
}
EOF

	unset AUTHOR GITHUB_USER
	REPOS=()
	load_tellme_config "${TEST_DIR}/good.json"
	[[ "${#REPOS[@]}" -eq 2 ]]
	[[ "${REPOS[0]}" == "${TEST_DIR}/absolute-repo:master" ]]
	[[ "${REPOS[1]}" == "${HOME}/from-tilde:main" ]]
	[[ "${AUTHOR}" == "Config Author" ]]
	[[ "${GITHUB_USER}" == "configuser" ]]
}

@test "load_tellme_config:: leaves set AUTHOR and GITHUB_USER alone" {
	cat <<EOF >"${TEST_DIR}/good.json"
{
  "author": "Config Author",
  "github_user": "configuser",
  "repos": [
    {"path": "${TEST_DIR}/absolute-repo", "branch": "master"}
  ]
}
EOF
	mkdir -p "${TEST_DIR}/absolute-repo"
	AUTHOR="Existing Author"
	GITHUB_USER="existinguser"
	REPOS=()

	load_tellme_config "${TEST_DIR}/good.json"
	[[ "${AUTHOR}" == "Existing Author" ]]
	[[ "${GITHUB_USER}" == "existinguser" ]]
	[[ "${REPOS[0]}" == "${TEST_DIR}/absolute-repo:master" ]]
}
