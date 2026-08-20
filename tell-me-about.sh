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
Usage: $(basename "$0") -p|--path <path> -b|--branch <branch>
       [-a|--author <author>]
       [--range <date> | --range <start_date> <end_date>]
       [--sha <commit> ...] [--only-merges]
       [--tools <jira,github,coworker>]

Analyze git commits by author and save detailed information to
commit-specific directories.

Each commit is saved to: OUTPUT_DIR/REPO_NAME/BRANCH/AUTHOR/SHORT_COMMIT/
  - pr.json  : Pull request details when the github tool is enabled
  - diff.txt : Commit message and changed files
  - jira.txt : JIRA ticket details when the jira tool is enabled

All tools are enabled by default. Use --tools with a comma-separated
list to select a subset.

Options:
  -p, --path <path>        : Path to the repository, required
  -b, --branch <branch>    : Branch to analyze, required
  -a, --author <author>    : Author of commits, defaults to git global user.name or user.email
  --range <date>           : Analyze commits since date, or between two dates
  --sha <commit>           : Analyze specific commit by SHA, can be used multiple times
  --only-merges            : Only include merge commits with subjects matching author
  --tools <tools>          : Comma-separated subset of jira,github,coworker
  -h, --help               : Show this help message

Either --range or --sha must be specified. The coworker tool uses
--range dates, or derives a window from --sha author dates. Project
skills then call Coworker MCP calendar_search and transcript_by_id.

EOF

	return 0
}

# Configures which external tools are enabled
#
# Inputs:
# - $1: comma-separated tool names, empty enables all tools
#
# Side Effects:
# - Sets CHECK_GITHUB, CHECK_JIRA, and CHECK_COWORKER
#
# Returns:
# - 0 on success
# - 1 when a tool name or list format is invalid
configure_tools() {
	local tools="${1:-jira,github,coworker}"
	local tool
	local tools_array
	local IFS=','

	CHECK_GITHUB="false"
	CHECK_JIRA="false"
	CHECK_COWORKER="false"

	if [[ "${tools}" == ,* || "${tools}" == *, || "${tools}" == *,,* ]]; then
		echo "configure_tools:: Invalid tool list '${tools}'" >&2
		echo "configure_tools:: Use comma-separated names without empty entries" >&2
		return 1
	fi

	read -r -a tools_array <<<"${tools}"
	for tool in "${tools_array[@]}"; do
		case "${tool}" in
		github)
			CHECK_GITHUB="true"
			;;
		jira)
			CHECK_JIRA="true"
			;;
		coworker)
			CHECK_COWORKER="true"
			;;
		*)
			echo "configure_tools:: Unknown tool '${tool}'" >&2
			echo "configure_tools:: Allowed tools: jira,github,coworker" >&2
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
	local mcp_config
	local failed=0

	if [[ "${CHECK_JIRA}" == "true" ]]; then
		if ! check_jira_dependencies || ! validate_jira_auth; then
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
		elif ! mcp_config=$(resolve_mcp_config); then
			failed=1
		elif ! check_coworker_mcp "${mcp_config}"; then
			failed=1
		fi
	fi

	if [[ "${failed}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# Validates required script arguments
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_args() {
	if [[ -z "${REPO_PATH}" ]]; then
		echo "validate_args:: REPO_PATH is not set" >&2
		return 1
	fi

	if [[ -z "${BRANCH}" ]]; then
		echo "validate_args:: BRANCH is not set" >&2
		return 1
	fi

	if [[ -z "${AUTHOR}" ]]; then
		echo "validate_args:: Missing required arguments" >&2
		usage >&2
		return 1
	fi

	if [[ ! -d "${REPO_PATH}" ]]; then
		echo "validate_args:: Invalid repository path: ${REPO_PATH}" >&2
		return 1
	fi

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
	local configured_author
	local configured_email

	if [[ -z "${AUTHOR}" ]]; then
		if ! configured_author=$(git config --global --get user.name 2>/dev/null); then
			configured_author=""
		fi

		if [[ -n "${configured_author}" ]]; then
			AUTHOR="${configured_author}"
		else
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

# Validates git repository, author, and optional explicit SHAs
#
# Side Effects:
# - Sets REPO_NAME
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_repo() {
	local toplevel
	local author_output
	local sha

	if [[ -z "${REPO_PATH}" || -z "${AUTHOR}" ]]; then
		echo "validate_repo:: REPO_PATH or AUTHOR is not set" >&2
		return 1
	fi

	if ! toplevel=$(git_cmd rev-parse --show-toplevel 2>/dev/null); then
		echo "validate_repo:: Failed to get repository name" >&2
		return 1
	fi
	REPO_NAME=$(basename "${toplevel}")

	if ! author_output=$(git_cmd log --regexp-ignore-case --author="${AUTHOR}" --max-count=1 --oneline 2>/dev/null); then
		author_output=""
	fi
	if [[ -z "${author_output}" ]]; then
		echo "validate_repo:: Author '${AUTHOR}' not found in the commit history" >&2
		return 1
	fi

	if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
		for sha in "${COMMIT_SHAS[@]}"; do
			if ! git_cmd rev-parse "${sha}" >/dev/null 2>&1; then
				echo "validate_repo:: Commit '${sha}' not found in git history" >&2
				return 1
			fi
		done
	fi

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
	local total_commits="${#COMMITS[@]}"
	local commit
	local short_commit
	local commit_dir
	local diff_file
	local jira_link
	local jira_file
	local github_link
	local pr_file

	if [[ -z "${REPO_PATH}" || -z "${OUTPUT_PATH}" ]]; then
		echo "process_commits:: REPO_PATH or OUTPUT_PATH is not set" >&2
		return 1
	fi

	if [[ ${total_commits} -eq 0 ]]; then
		echo "No commits found"
	fi

	for commit in "${COMMITS[@]}"; do
		if ! short_commit=$(git_cmd rev-parse --short "${commit}" 2>/dev/null); then
			echo "process_commits:: Failed to get short commit hash for ${commit}" >&2
			continue
		fi

		commit_dir="${OUTPUT_PATH}/${short_commit}"
		if ! mkdir -p "${commit_dir}" 2>/dev/null; then
			echo "process_commits:: Failed to create commit directory: ${commit_dir}" >&2
			continue
		fi

		diff_file="${commit_dir}/diff.txt"
		if [[ ! -f "${diff_file}" ]]; then
			if ! write_commit_details "${commit}" "${diff_file}"; then
				echo "process_commits:: Failed to write commit details for ${commit}" >&2
			fi
		fi

		jira_link=""
		if [[ "${CHECK_JIRA}" == "true" ]]; then
			jira_file="${commit_dir}/jira.txt"
			if needs_jira_refresh "${jira_file}"; then
				if ! write_jira_details "${commit}" "${jira_file}"; then
					echo "process_commits:: Failed to write JIRA details for ${commit}" >&2
				fi
			fi
			if [[ -s "${jira_file}" ]]; then
				jira_link="${jira_file}"
			fi
		fi

		github_link=""
		if [[ "${CHECK_GITHUB}" == "true" ]]; then
			pr_file="${commit_dir}/pr.json"
			if needs_pr_refresh "${pr_file}"; then
				if ! write_pr_details "${commit}" "${pr_file}"; then
					echo "process_commits:: Failed to write PR details for ${commit}" >&2
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
		if [[ -n "${github_link}" ]]; then
			print_field "GitHub" "${github_link}" "github"
		fi
	done

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

# Loads shared print, git, util, commits, and tool libraries relative to this script
#
# Side Effects:
# - Sources tools/lib/*.sh and tools/{github,jira,coworker}.sh into the current shell
#
# Returns:
# - 0 on success
# - 1 when a required library file is missing
_setup() {
	local script_dir=""
	local lib_file=""
	local tool_lib=""

	script_dir=$(dirname "${BASH_SOURCE[0]}")
	if [[ "${script_dir}" != /* ]]; then
		script_dir="$(cd "${script_dir}" && pwd)"
	fi

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

	for tool_lib in \
		"${script_dir}/tools/github.sh" \
		"${script_dir}/tools/jira.sh" \
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
	local tools=""

	_setup || return 1

	COMMIT_SHAS=()
	COMMITS=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			return 0
			;;
		-p | --path)
			REPO_PATH="$2"
			shift 2
			;;
		-b | --branch)
			BRANCH="$2"
			shift 2
			;;
		-a | --author)
			AUTHOR="$2"
			shift 2
			;;
		--range)
			if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
				echo "main:: --range cannot be used with --sha" >&2
				return 1
			fi
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
		--sha)
			if [[ -n "${RANGE_DATE1}" ]]; then
				echo "main:: --sha cannot be used with --range" >&2
				return 1
			fi
			if [[ -z "$2" ]]; then
				echo "main:: --sha requires a commit hash" >&2
				return 1
			fi
			COMMIT_SHAS+=("$2")
			shift 2
			;;
		--only-merges)
			ONLY_MERGES=true
			shift
			;;
		--tools)
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "main:: --tools requires a comma-separated list of jira,github,coworker" >&2
				return 1
			fi
			tools="$2"
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

	if [[ ${#COMMIT_SHAS[@]} -eq 0 && -z "${RANGE_DATE1}" ]]; then
		echo "main:: --range or --sha is required" >&2
		usage
		return 1
	fi

	set_default_author || return 1
	validate_args || return 1
	validate_repo || return 1
	validate_enabled_tools || return 1

	if [[ ${#COMMIT_SHAS[@]} -eq 0 ]]; then
		determine_period_dates || return 1
	else
		determine_period_from_shas || return 1
	fi

	get_commits || return 1

	if ! sanitize_names "${AUTHOR}" "${BRANCH}"; then
		echo "main:: Failed to sanitize names" >&2
		return 1
	fi

	OUTPUT_PATH="${OUTPUT_DIR}/${REPO_NAME}/${SANITIZED_BRANCH}/${SANITIZED_AUTHOR}"

	if ! mkdir -p "${OUTPUT_PATH}" 2>/dev/null; then
		echo "main:: Failed to create output directory: ${OUTPUT_PATH}" >&2
		return 1
	fi

	process_commits || return 1

	if [[ "${CHECK_COWORKER}" == "true" ]]; then
		process_meetings || return 1
	fi

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
