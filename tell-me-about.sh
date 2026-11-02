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
Usage: tell-me-about.sh --range <date> [<end_date>]
       [--tools <jira,linear,github,coworker>]
       [--github-user <login>]

Repos and optional author/github_user come from tell-me-about.json.
Override the config path with TELLME_CONFIG.

Options:
  --range <date>             : Commits since date, or between two dates
  --tools <tools>            : Subset of jira,linear,github,coworker; default all
  --github-user <login>      : GitHub username when github is enabled
  -h, --help                 : Show this help message

--range is required. Repo paths may use leading ~, then must be absolute.
Author defaults to JSON author, else git global user.name or user.email.
When github is enabled, pass --github-user or JSON github_user unless author is a username.

When a tool fails healthcheck, an interactive prompt asks whether to
continue without it. Non-interactive stdin skips failed tools after a
stderr notice and continues the run.

EOF

	return 0
}

# Parses CLI flags and loads tell-me-about.json repos
#
# Inputs:
# - $@: argv after the program name
#
# Side Effects:
# - Sets INPUT_HELP, REPOS, RANGE_DATE1, RANGE_DATE2, TOOLS, AUTHOR, GITHUB_USER
# - Writes usage to stdout when help is requested
#
# Returns:
# - 0 on success or help
# - 1 on parse, config, or validation failure
process_input() {
	REPOS=()
	INPUT_HELP=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			INPUT_HELP=1
			return 0
			;;
		--github-user)
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "process_input:: --github-user requires a GitHub username" >&2
				return 1
			fi
			GITHUB_USER="$2"
			shift 2
			;;
		--range)
			if [[ -n "${RANGE_DATE1:-}" ]]; then
				echo "process_input:: --range option can only be used once" >&2
				return 1
			fi
			if [[ -z "${2:-}" || "$2" == -* ]]; then
				echo "process_input:: --range requires a date" >&2
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
				echo "process_input:: --tools requires jira,linear,github,coworker" >&2
				return 1
			fi
			TOOLS="$2"
			shift 2
			;;
		*)
			echo "process_input:: Unknown option '$1'" >&2
			echo "process_input:: Use --help for usage information" >&2
			return 1
			;;
		esac
	done

	if [[ -z "${RANGE_DATE1:-}" ]]; then
		echo "process_input:: --range is required" >&2
		usage
		return 1
	fi

	local config_file
	config_file=$(resolve_tellme_config)
	load_tellme_config "${config_file}" || return 1

	return 0
}

# Sets one CHECK_* tool flag
#
# Inputs:
# - $1: tool name from jira, linear, github, coworker
# - $2: true or false
#
# Side Effects:
# - Sets the matching CHECK_* flag
#
# Returns:
# - 0 on success
# - 1 when the tool name is unknown
set_tool_enabled() {
	local tool="${1:-}"
	local enabled="${2:-}"

	case "${tool}" in
	jira)
		CHECK_JIRA="${enabled}"
		;;
	linear)
		CHECK_LINEAR="${enabled}"
		;;
	github)
		CHECK_GITHUB="${enabled}"
		;;
	coworker)
		CHECK_COWORKER="${enabled}"
		;;
	*)
		echo "set_tool_enabled:: Unknown tool '${tool}'" >&2
		return 1
		;;
	esac

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
		if ! set_tool_enabled "${tool}" "true"; then
			echo "configure_tools:: Unknown tool '${tool}'" >&2
			echo "configure_tools:: Allowed tools: jira,linear,github,coworker" >&2
			return 1
		fi
	done

	return 0
}

# Validates dependencies and authentication for enabled tools
#
# Side Effects:
# - Resets FAILED_TOOLS and appends each tool that fails validation
# - Writes dependency or auth errors from tool helpers to stderr
#
# Returns:
# - 0 on success
# - 1 when an enabled tool is missing dependencies or authentication
validate_enabled_tools() {
	FAILED_TOOLS=()

	if [[ "${CHECK_JIRA}" == "true" ]]; then
		if ! check_jira_dependencies || ! validate_jira_auth; then
			FAILED_TOOLS+=("jira")
		fi
	fi

	if [[ "${CHECK_LINEAR}" == "true" ]]; then
		if ! check_linear_dependencies || ! validate_linear_auth; then
			FAILED_TOOLS+=("linear")
		fi
	fi

	if [[ "${CHECK_GITHUB}" == "true" ]]; then
		if ! check_github_dependencies; then
			FAILED_TOOLS+=("github")
		fi
	fi

	if [[ "${CHECK_COWORKER}" == "true" ]]; then
		if ! check_coworker_dependencies; then
			FAILED_TOOLS+=("coworker")
		else
			local mcp_config
			if ! mcp_config=$(resolve_mcp_config); then
				FAILED_TOOLS+=("coworker")
			elif ! check_coworker_mcp "${mcp_config}"; then
				FAILED_TOOLS+=("coworker")
			fi
		fi
	fi

	if [[ "${#FAILED_TOOLS[@]}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# Disables one or more external tools for the rest of the run
#
# Inputs:
# - $@: tool names from jira, linear, github, coworker
#
# Side Effects:
# - Sets matching CHECK_* flags to false
# - Writes disable notices to stderr
#
# Returns:
# - 0 on success
# - 1 when a tool name is unknown
disable_tools() {
	local tool
	for tool in "$@"; do
		set_tool_enabled "${tool}" "false" || {
			echo "disable_tools:: Unknown tool '${tool}'" >&2
			return 1
		}
		echo "disable_tools:: disabled ${tool}" >&2
	done

	return 0
}

# Runs a command and disables the tool when it fails
#
# Inputs:
# - $1: tool name
# - $@: command and arguments
#
# Side Effects:
# - May call disable_tools in the current shell
# - Writes a disable notice to stderr on failure
#
# Returns:
# - 0 when the command succeeds
# - 1 when the command fails, after disabling the tool
skip_tool_on_failure() {
	local tool="${1:-}"
	shift || true

	if [[ -z "${tool}" ]]; then
		echo "skip_tool_on_failure:: tool is required" >&2
		return 1
	fi

	if "$@"; then
		return 0
	fi

	echo "skip_tool_on_failure:: disabling ${tool}" >&2
	disable_tools "${tool}"

	return 1
}

# Asks whether to continue after one or more tools failed healthcheck
#
# Side Effects:
# - Reads FAILED_TOOLS
# - Writes prompt or auto-proceed notice to stderr
# - Reads a y/N answer from stdin when stdin is a TTY
#
# Returns:
# - 0 when the user proceeds or stdin is non-interactive
# - 1 when the user declines or FAILED_TOOLS is empty unexpectedly after a failure path
confirm_proceed_without_tools() {
	if [[ "${#FAILED_TOOLS[@]}" -eq 0 ]]; then
		echo "confirm_proceed_without_tools:: no failed tools to confirm" >&2
		return 1
	fi

	local tools_list
	tools_list=$(
		IFS=','
		echo "${FAILED_TOOLS[*]}"
	)

	cat <<EOF >&2
confirm_proceed_without_tools:: Missing or invalid access for: ${tools_list}
confirm_proceed_without_tools:: Continuing will skip these tools for this run
EOF

	if [[ ! -t 0 ]]; then
		echo "confirm_proceed_without_tools:: non-interactive stdin; proceeding without: ${tools_list}" >&2
		return 0
	fi

	local answer
	printf 'Proceed without these tools? [y/N] ' >&2
	if ! read -r answer; then
		echo "confirm_proceed_without_tools:: aborted" >&2
		return 1
	fi

	case "${answer}" in
	y | Y | yes | YES)
		return 0
		;;
	*)
		echo "confirm_proceed_without_tools:: aborted" >&2
		return 1
		;;
	esac
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
	[[ -n "${AUTHOR}" ]] && return 0

	local configured
	if configured=$(git config --global --get user.name 2>/dev/null) && [[ -n "${configured}" ]]; then
		AUTHOR="${configured}"
		return 0
	fi

	if configured=$(git config --global --get user.email 2>/dev/null) && [[ -n "${configured}" ]]; then
		AUTHOR="${configured}"
		return 0
	fi

	echo "set_default_author:: AUTHOR is not set and no global git user.name or user.email is configured" >&2
	return 1
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

# Writes one enabled ticket artifact and disables the tool on write failure
#
# Inputs:
# - $1: destination variable name for the artifact path
# - $2: enabled flag, true or false
# - $3: commit hash
# - $4: output file
# - $5: write function name
# - $6: tool name for skip_tool_on_failure
#
# Side Effects:
# - Sets the destination variable to the artifact path when non-empty, else empty
# - May call skip_tool_on_failure in the current shell
#
# Returns:
# - 0 on success or when the tool is disabled or already written
# - 1 when the destination variable name is missing
write_commit_tool_file() {
	local dest_var="${1:-}"
	local enabled="${2:-}"
	local commit="${3:-}"
	local tracker_file="${4:-}"
	local write_fn="${5:-}"
	local tool="${6:-}"

	if [[ -z "${dest_var}" ]]; then
		echo "write_commit_tool_file:: destination variable is required" >&2
		return 1
	fi

	printf -v "${dest_var}" '%s' ""

	if [[ "${enabled}" != "true" ]]; then
		return 0
	fi

	if [[ ! -s "${tracker_file}" ]]; then
		if ! skip_tool_on_failure "${tool}" "${write_fn}" "${commit}" "${tracker_file}"; then
			echo "write_commit_tool_file:: Failed to write ${tool} details for ${commit}" >&2
		fi
	fi

	if [[ -s "${tracker_file}" ]]; then
		printf -v "${dest_var}" '%s' "${tracker_file}"
	fi

	return 0
}

# Processes commits and writes details to output directories
#
# Side Effects:
# - Creates commit-specific directories and files
# - Writes commit information to stdout
# - May disable jira, linear, or github after an enrichment write fails
# - Tool enrichment failures never set the failed flag
#
# Returns:
# - 0 on success
# - 1 when a core write fails
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

		write_commit_tool_file jira_link \
			"${CHECK_JIRA}" "${commit}" "${commit_dir}/jira.txt" write_jira_details jira

		write_commit_tool_file linear_link \
			"${CHECK_LINEAR}" "${commit}" "${commit_dir}/linear.txt" write_linear_details linear

		github_link=""
		if [[ "${CHECK_GITHUB}" == "true" ]]; then
			pr_file="${commit_dir}/pr.json"
			if needs_pr_refresh "${pr_file}"; then
				if skip_tool_on_failure github write_pr_details "${commit}" "${pr_file}"; then
					github_link="${pr_file}"
				else
					echo "process_commits:: Failed to write PR details for ${commit}" >&2
				fi
			else
				github_link="${pr_file}"
			fi
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
# - May disable github or coworker after mid-run failures
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
		if ! skip_tool_on_failure github process_involvement_prs; then
			echo "process_repo:: Failed involvement PRs" >&2
		fi
	fi

	if [[ "${CHECK_COWORKER}" == "true" ]]; then
		local meetings_dir="${OUTPUT_PATH}/meetings"
		if ! mkdir -p "${meetings_dir}" 2>/dev/null; then
			echo "process_repo:: Failed to create meetings directory: ${meetings_dir}" >&2
			disable_tools coworker
		elif ! skip_tool_on_failure coworker write_meetings_stub \
			"${meetings_dir}" "${PERIOD_START}" "${PERIOD_END}"; then
			echo "process_repo:: Failed meetings stub" >&2
		fi
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

# Loads shared print, git, util, config, commits, and tool libraries relative to this script
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
		"${script_dir}/tools/lib/config.sh" \
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
	TOOLS=""
	INPUT_HELP=0

	process_input "$@" || return 1
	[[ "${INPUT_HELP}" -eq 1 ]] && return 0

	configure_tools "${TOOLS}" || return 1

	if [[ -z "${OUTPUT_DIR}" ]]; then
		OUTPUT_DIR="${HOME}/${DEFAULT_OUTPUT_DIR}"
	fi

	set_default_author || return 1
	determine_period_dates || return 1

	if ! validate_enabled_tools; then
		confirm_proceed_without_tools || return 1
		disable_tools "${FAILED_TOOLS[@]}" || return 1
	fi

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
