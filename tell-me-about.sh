#!/usr/bin/env bash
#
# Git commit analyzer that extracts commit details for a specific author
# and writes them to commit-specific directories.
#

DEFAULT_OUTPUT_DIR="tellme"

# Display usage information
#
# Side Effects:
# - Writes usage text to stdout
#
# Returns:
# - 0 always
usage() {
	cat <<EOF
Usage: $(basename "$0") [--repo <path>:<branch> ...]
       [-a|--author <author>] [--github-user <login>]
       [--range <date> | --range <start_date> <end_date>]
       [--tools <jira,linear,github,coworker>]

Analyze git commits by author and save detailed information to
commit-specific directories.

Each commit is saved to: OUTPUT_DIR/REPO_NAME/SANITIZED_BRANCH/SANITIZED_AUTHOR/SHORT_COMMIT/
  - pr.json  : Pull request details when the github tool is enabled
  - diff.txt : Commit message and changed files
  - jira.txt : JIRA ticket details when the jira tool is enabled
  - linear.txt : Linear issue details when the linear tool is enabled

When github is enabled, involvement PRs are also written to:
  OUTPUT_DIR/REPO_NAME/SANITIZED_BRANCH/SANITIZED_AUTHOR/prs/{merged,reviewed,commented}/index.json

All tools are enabled by default. Use --tools with a comma-separated
list to select a subset.

Options:
  --repo <path>:<branch>     : Repository path and branch, repeatable
  -a, --author <author>      : Git author, defaults to git global user.name or user.email
  --github-user <login>      : GitHub username when github is enabled
  --range <date>             : Analyze commits since date, or between two dates
  --tools <tools>            : Comma-separated subset of jira,linear,github,coworker
  -h, --help                 : Show this help message

--range is required. The coworker tool uses --range dates. Project
skills then call Coworker MCP calendar_search and transcript_by_id.

When github is enabled, --github-user is required unless --author is
already a GitHub username. Relative paths in --repo resolve against
TELLME_REPOS_ROOT when set.

EOF

	return 0
}

# Configures which external tools are enabled
#
# Inputs:
# - $1: comma-separated tool names, empty enables all tools
#
# Side Effects:
# - Sets CHECK_GITHUB, CHECK_JIRA, CHECK_LINEAR, and CHECK_COWORKER
#
# Returns:
# - 0 on success
# - 1 when a tool name or list format is invalid
configure_tools() {
	local tools="${1:-jira,linear,github,coworker}"

	CHECK_GITHUB="false"
	CHECK_JIRA="false"
	CHECK_LINEAR="false"
	CHECK_COWORKER="false"

	if [[ "${tools}" == ,* || "${tools}" == *, || "${tools}" == *,,* ]]; then
		echo "configure_tools:: Invalid tool list '${tools}'" >&2
		echo "configure_tools:: Use comma-separated names without empty entries" >&2
		return 1
	fi

	local tools_array
	IFS=',' read -r -a tools_array <<<"${tools}"
	local tool
	for tool in "${tools_array[@]}"; do
		case "${tool}" in
		github)
			CHECK_GITHUB="true"
			;;
		jira)
			CHECK_JIRA="true"
			;;
		linear)
			CHECK_LINEAR="true"
			;;
		coworker)
			CHECK_COWORKER="true"
			;;
		*)
			echo "configure_tools:: Unknown tool '${tool}'" >&2
			echo "configure_tools:: Allowed tools: jira,linear,github,coworker" >&2
			return 1
			;;
		esac
	done

	return 0
}

# Validates dependencies and authentication for enabled tools
#
# Side Effects:
# - Writes dependency or auth errors from tool helpers to stderr
#
# Returns:
# - 0 on success
# - 1 when an enabled tool is missing dependencies or authentication
validate_enabled_tools() {
	local failed=0

	if [[ "${CHECK_JIRA}" == "true" ]]; then
		if ! check_jira_dependencies || ! validate_jira_auth; then
			failed=1
		fi
	fi

	if [[ "${CHECK_LINEAR}" == "true" ]]; then
		if ! check_linear_dependencies || ! validate_linear_auth; then
			failed=1
		fi
	fi

	if [[ "${CHECK_GITHUB}" == "true" ]]; then
		if ! check_github_dependencies; then
			failed=1
		fi
	fi

	if [[ "${CHECK_COWORKER}" == "true" ]]; then
		if ! check_coworker_dependencies; then
			failed=1
		else
			local mcp_config
			if ! mcp_config=$(resolve_mcp_config); then
				failed=1
			elif ! check_coworker_mcp "${mcp_config}"; then
				failed=1
			fi
		fi
	fi

	[[ "${failed}" -ne 0 ]] && return 1

	return 0
}

# Sets AUTHOR from git global config when missing
#
# Side Effects:
# - Sets AUTHOR when it is empty
#
# Returns:
# - 0 on success
# - 1 on failure
set_default_author() {
	if [[ -z "${AUTHOR}" ]]; then
		local configured_author
		if ! configured_author=$(git config --global --get user.name 2>/dev/null); then
			configured_author=""
		fi

		if [[ -n "${configured_author}" ]]; then
			AUTHOR="${configured_author}"
		else
			local configured_email
			if ! configured_email=$(git config --global --get user.email 2>/dev/null); then
				configured_email=""
			fi

			if [[ -n "${configured_email}" ]]; then
				AUTHOR="${configured_email}"
			else
				echo "set_default_author:: AUTHOR is not set and no global git user.name or user.email is configured" >&2
				return 1
			fi
		fi
	fi

	return 0
}

# Validates git repository and author
#
# Side Effects:
# - Sets REPO_NAME
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_repo() {
	if [[ -z "${REPO_PATH}" || -z "${AUTHOR}" ]]; then
		echo "validate_repo:: REPO_PATH or AUTHOR is not set" >&2
		return 1
	fi

	if [[ ! -d "${REPO_PATH}" ]]; then
		echo "validate_repo:: Invalid repository path: ${REPO_PATH}" >&2
		return 1
	fi

	local toplevel
	if ! toplevel=$(git_cmd rev-parse --show-toplevel 2>/dev/null); then
		echo "validate_repo:: Failed to get repository name" >&2
		return 1
	fi
	REPO_NAME=$(basename "${toplevel}")

	local author_output
	if ! author_output=$(git_cmd log --regexp-ignore-case --author="${AUTHOR}" --max-count=1 --oneline 2>/dev/null); then
		author_output=""
	fi
	if [[ -z "${author_output}" ]]; then
		echo "validate_repo:: Author '${AUTHOR}' not found in the commit history" >&2
		return 1
	fi

	return 0
}

# Writes a per-commit tracker artifact when that tool is enabled
#
# Inputs:
# - $1: enabled flag, true or false
# - $2: commit hash
# - $3: output file
# - $4: write function name
# - $5: tracker label for error text
#
# Outputs:
# - Artifact path to stdout when the file is non-empty
#
# Returns:
# - 0 on success or when disabled
# - 1 when the write function fails
write_commit_tracker_file() {
	local enabled="${1:-}"
	local commit="${2:-}"
	local tracker_file="${3:-}"
	local write_fn="${4:-}"
	local tracker_label="${5:-}"

	if [[ "${enabled}" != "true" ]]; then
		return 0
	fi

	local failed=0
	if needs_text_refresh "${tracker_file}"; then
		if ! "${write_fn}" "${commit}" "${tracker_file}"; then
			echo "process_commits:: Failed to write ${tracker_label} details for ${commit}" >&2
			failed=1
		fi
	fi

	if [[ -s "${tracker_file}" ]]; then
		echo "${tracker_file}"
	fi

	[[ "${failed}" -ne 0 ]] && return 1

	return 0
}

# Processes commits and writes details to output directories
#
# Side Effects:
# - Creates commit-specific directories and files
# - Writes commit information to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
process_commits() {
	if [[ -z "${REPO_PATH}" || -z "${OUTPUT_PATH}" ]]; then
		echo "process_commits:: REPO_PATH or OUTPUT_PATH is not set" >&2
		return 1
	fi

	local failed=0
	local commit
	local short_commit
	local commit_dir
	local diff_file
	local jira_link
	local linear_link
	local github_link
	local pr_file
	for commit in "${COMMITS[@]}"; do
		if ! short_commit=$(git_cmd rev-parse --short "${commit}" 2>/dev/null); then
			echo "process_commits:: Failed to get short commit hash for ${commit}" >&2
			failed=1
			continue
		fi

		commit_dir="${OUTPUT_PATH}/${short_commit}"
		if ! mkdir -p "${commit_dir}" 2>/dev/null; then
			echo "process_commits:: Failed to create commit directory: ${commit_dir}" >&2
			failed=1
			continue
		fi

		diff_file="${commit_dir}/diff.txt"
		if [[ ! -f "${diff_file}" ]]; then
			if ! write_commit_details "${commit}" "${diff_file}"; then
				echo "process_commits:: Failed to write commit details for ${commit}" >&2
				failed=1
			fi
		fi

		jira_link=""
		if ! jira_link=$(write_commit_tracker_file \
			"${CHECK_JIRA}" "${commit}" "${commit_dir}/jira.txt" write_jira_details "JIRA"); then
			failed=1
		fi

		linear_link=""
		if ! linear_link=$(write_commit_tracker_file \
			"${CHECK_LINEAR}" "${commit}" "${commit_dir}/linear.txt" write_linear_details "Linear"); then
			failed=1
		fi

		github_link=""
		if [[ "${CHECK_GITHUB}" == "true" ]]; then
			pr_file="${commit_dir}/pr.json"
			if needs_pr_refresh "${pr_file}"; then
				if ! write_pr_details "${commit}" "${pr_file}"; then
					echo "process_commits:: Failed to write PR details for ${commit}" >&2
					failed=1
				fi
			fi
			github_link="${pr_file}"
		fi

		print_section
		print_field "Commit" "${short_commit}" "commit"
		print_field "Diff" "${diff_file}" "path"
		if [[ -n "${jira_link}" ]]; then
			print_field "Jira" "${jira_link}" "jira"
		fi
		if [[ -n "${linear_link}" ]]; then
			print_field "Linear" "${linear_link}" "linear"
		fi
		if [[ -n "${github_link}" ]]; then
			print_field "GitHub" "${github_link}" "github"
		fi
	done

	[[ "${failed}" -ne 0 ]] && return 1

	return 0
}

# Verifies Coworker MCP and prints the meetings output path plus skill instructions
#
# Side Effects:
# - Creates OUTPUT_PATH/meetings when missing
# - Writes meetings path, window, and skill paths to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
process_meetings() {
	if [[ -z "${OUTPUT_PATH}" ]]; then
		echo "process_meetings:: OUTPUT_PATH is not set" >&2
		return 1
	fi

	if [[ -z "${PERIOD_START}" || -z "${PERIOD_END}" ]]; then
		echo "process_meetings:: PERIOD_START and PERIOD_END are required for the coworker tool" >&2
		return 1
	fi

	write_meetings_stub "${OUTPUT_PATH}/meetings" "${PERIOD_START}" "${PERIOD_END}" || return 1

	return 0
}

# Sets REPO_PATH and BRANCH from a path:branch repo value
#
# Inputs:
# - $1: repo value in path:branch form
#
# Side Effects:
# - Sets REPO_PATH and BRANCH
#
# Returns:
# - 0 on success
# - 1 on validation failure
apply_repo() {
	local spec="${1:-}"

	REPO_PATH=""
	BRANCH=""

	if [[ -z "${spec}" ]]; then
		echo "apply_repo:: repo is required" >&2
		return 1
	fi

	if [[ "${spec}" != *:* ]]; then
		echo "apply_repo:: Invalid repo '${spec}', expected path:branch" >&2
		return 1
	fi

	REPO_PATH="${spec%:*}"
	BRANCH="${spec##*:}"

	if [[ -z "${REPO_PATH}" || -z "${BRANCH}" ]]; then
		echo "apply_repo:: Invalid repo '${spec}', expected path:branch" >&2
		return 1
	fi

	local repos_root="${TELLME_REPOS_ROOT:-}"
	if [[ "${REPO_PATH}" != /* && -n "${repos_root}" ]]; then
		REPO_PATH="${repos_root%/}/${REPO_PATH}"
	fi

	return 0
}

# Processes one repository through validation, commit export, and meetings stub
#
# Inputs:
# - $1: repo value in path:branch form
#
# Side Effects:
# - Sets REPO_PATH, BRANCH, REPO_NAME, COMMITS, OUTPUT_PATH, and sanitized names
# - Prints === spec (N commit|commits) === after commits are collected
# - Creates commit and meeting output directories
#
# Returns:
# - 0 on success
# - 1 on failure
process_repo() {
	local spec="${1:-}"

	COMMITS=()

	apply_repo "${spec}" || return 1
	validate_repo || return 1
	get_commits || return 1

	local commit_noun="commits"
	if ((${#COMMITS[@]} == 1)); then
		commit_noun="commit"
	fi
	echo "=== ${spec} (${#COMMITS[@]} ${commit_noun}) ==="

	if ! sanitize_names "${AUTHOR}" "${BRANCH}"; then
		echo "process_repo:: Failed to sanitize names" >&2
		return 1
	fi

	OUTPUT_PATH="${OUTPUT_DIR}/${REPO_NAME}/${SANITIZED_BRANCH}/${SANITIZED_AUTHOR}"

	if ! mkdir -p "${OUTPUT_PATH}" 2>/dev/null; then
		echo "process_repo:: Failed to create output directory: ${OUTPUT_PATH}" >&2
		return 1
	fi

	process_commits || return 1

	if [[ "${CHECK_GITHUB}" == "true" ]]; then
		process_involvement_prs || return 1
	fi

	if [[ "${CHECK_COWORKER}" == "true" ]]; then
		process_meetings || return 1
	fi

	return 0
}

# Collects PRs the GitHub user merged, reviewed, or commented on in the period
#
# Side Effects:
# - Creates OUTPUT_PATH/prs/{merged,reviewed,commented}/ when missing
# - Writes index.json files via write_involvement_prs
# - Prints a summary card with per-role counts and the three index paths
#
# Returns:
# - 0 on success
# - 1 on failure
process_involvement_prs() {
	if [[ -z "${OUTPUT_PATH}" ]]; then
		echo "process_involvement_prs:: OUTPUT_PATH is not set" >&2
		return 1
	fi

	write_involvement_prs "${OUTPUT_PATH}" || return 1

	local prs_root="${OUTPUT_PATH}/prs"
	local counts=""
	local role
	local count
	for role in merged reviewed commented; do
		count=$(jq 'length' "${prs_root}/${role}/index.json" 2>/dev/null) || count="unknown"
		counts="${counts}${counts:+, }${role} ${count}"
	done

	print_section
	print_field "PRs" "${counts}" "github"
	print_paths \
		"${prs_root}/merged/index.json" \
		"${prs_root}/reviewed/index.json" \
		"${prs_root}/commented/index.json"

	return 0
}

# Loads shared print, git, util, commits, and tool libraries relative to this script
#
# Side Effects:
# - Sources tools/lib/*.sh and tools/{github,jira,linear,coworker}.sh into the current shell
#
# Returns:
# - 0 on success
# - 1 when a required library file is missing
_setup() {
	local script_dir
	script_dir=$(dirname "${BASH_SOURCE[0]}")
	if [[ "${script_dir}" != /* ]]; then
		script_dir="$(cd "${script_dir}" && pwd)"
	fi

	local lib_file
	for lib_file in \
		"${script_dir}/tools/lib/print.sh" \
		"${script_dir}/tools/lib/util.sh" \
		"${script_dir}/tools/lib/git.sh" \
		"${script_dir}/tools/lib/commits.sh"; do
		if [[ ! -f "${lib_file}" ]]; then
			echo "_setup:: shared library not found: ${lib_file}" >&2
			return 1
		fi
		# shellcheck disable=SC1090
		source "${lib_file}"
	done

	local tool_lib
	for tool_lib in \
		"${script_dir}/tools/github.sh" \
		"${script_dir}/tools/jira.sh" \
		"${script_dir}/tools/linear.sh" \
		"${script_dir}/tools/coworker.sh"; do
		if [[ ! -f "${tool_lib}" ]]; then
			echo "_setup:: tool library not found: ${tool_lib}" >&2
			return 1
		fi
		# shellcheck disable=SC1090
		source "${tool_lib}"
	done

	return 0
}

main() {
	_setup || return 1

	COMMITS=()
	REPOS=()

	local tools=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			return 0
			;;
		-a | --author)
			AUTHOR="$2"
			shift 2
			;;
		--github-user)
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "main:: --github-user requires a GitHub username" >&2
				return 1
			fi
			GITHUB_USER="$2"
			shift 2
			;;
		--range)
			if [[ -n "${RANGE_DATE1}" ]]; then
				echo "main:: --range option can only be used once" >&2
				return 1
			fi
			RANGE_DATE1="$2"
			shift 2
			if [[ $# -gt 0 && "$1" != -* ]]; then
				RANGE_DATE2="$1"
				shift 1
			fi
			;;
		--tools)
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "main:: --tools requires a comma-separated list of jira,linear,github,coworker" >&2
				return 1
			fi
			tools="$2"
			shift 2
			;;
		--repo)
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "main:: --repo requires path:branch" >&2
				return 1
			fi
			REPOS+=("$2")
			shift 2
			;;
		*)
			echo "main:: Unknown option '$1'" >&2
			echo "main:: Use '$(basename "$0") --help' for usage information" >&2
			return 1
			;;
		esac
	done

	configure_tools "${tools}" || return 1

	if [[ -z "${OUTPUT_DIR}" ]]; then
		OUTPUT_DIR="${HOME}/${DEFAULT_OUTPUT_DIR}"
	fi

	if [[ -z "${RANGE_DATE1}" ]]; then
		echo "main:: --range is required" >&2
		usage
		return 1
	fi

	if [[ "${#REPOS[@]}" -eq 0 ]]; then
		echo "main:: at least one --repo is required" >&2
		return 1
	fi

	set_default_author || return 1
	determine_period_dates || return 1
	validate_enabled_tools || return 1

	local spec
	local failed=0
	for spec in "${REPOS[@]}"; do
		if ! process_repo "${spec}"; then
			failed=1
		fi
	done

	[[ "${failed}" -ne 0 ]] && return 1
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
