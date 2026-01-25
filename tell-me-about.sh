#!/usr/bin/env bash
#
# Git commit analyzer script that extracts commit details for a specific author
# within a time range from a git repository and saves them to a file.
#

# Only enable strict mode when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
fi

# Display usage information
#
# Side Effects:
# - Outputs usage information to stdout
#
# Returns:
# - 0 always
usage() {
	cat <<EOF
Usage: $(basename "$0") -p|--path <path> -b|--branch <branch> [-a|--author <author>] [--range <date> | --range <start_date> <end_date>] [--sha <commit> ...] [--only-merges] [--github] [--jira]

Analyze git commits by author and save detailed information to commit-specific directories.

Each commit is saved to: OUTPUT_DIR/REPO_NAME/BRANCH/AUTHOR/SHORT_COMMIT/
  - pr.json  : Pull request details (if --github is used)
  - diff.txt : Commit message and changed files
  - jira.txt : JIRA ticket details (if --jira is used)

Options:
  -p, --path <path>        : Path to the repository (required)
  -b, --branch <branch>    : Branch to analyze (required)
  -a, --author <author>    : Author of commits, defaults to git global user.name or user.email
  --range <date>           : Analyze commits since date (one arg) or between two dates (two args)
  --sha <commit>           : Analyze specific commit(s) by SHA (can be used multiple times, replaces --range)
  --only-merges            : Only include merge commits with subjects matching author
  --github                 : Include GitHub details for commits, such as pull request information (requires GitHub CLI)
  --jira                   : Include JIRA ticket details for commits that reference tickets (requires JIRA CLI)
  -h, --help               : Show this help message

EOF
}

# Defaults
DEFAULT_OUTPUT_DIR="tmaatw"
DEFAULT_CHECK_JIRA="false"
DEFAULT_CHECK_GITHUB="false"

# Constants
OUTPUT_LABEL_WIDTH=8
GITHUB_SCRIPT="tools/github.sh"
JIRA_SCRIPT="tools/jira.sh"

# Color definitions
COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_COMMIT=""
COLOR_DIFF=""
COLOR_JIRA=""
COLOR_GITHUB=""
COLOR_PATH=""
COLOR_SEPARATOR=""
COLOR_LABEL=""

if [[ -t 1 ]]; then
	COLOR_RESET=$'\033[0m'
	COLOR_BOLD=$'\033[1m'
	COLOR_DIM=$'\033[2m'
	COLOR_COMMIT=$'\033[38;5;39m'
	COLOR_DIFF=$'\033[38;5;76m'
	COLOR_JIRA=$'\033[38;5;208m'
	COLOR_GITHUB=$'\033[38;5;141m'
	COLOR_PATH=$'\033[38;5;244m'
	COLOR_SEPARATOR=$'\033[38;5;240m'
	COLOR_LABEL=$'\033[1;38;5;255m'
fi

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
		usage
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
# - Sets AUTHOR global variable if not already set
#
# Returns:
# - 0 on success
# - 1 on failure
set_default_author() {
	local configured_author
	local configured_email

	if [[ -n "${AUTHOR}" ]]; then
		return 0
	fi

	if ! configured_author=$(git config --global --get user.name 2>/dev/null); then
		configured_author=""
	fi

	if [[ -n "${configured_author}" ]]; then
		AUTHOR="${configured_author}"
		return 0
	fi

	if ! configured_email=$(git config --global --get user.email 2>/dev/null); then
		configured_email=""
	fi

	if [[ -n "${configured_email}" ]]; then
		AUTHOR="${configured_email}"
		return 0
	fi

	echo "set_default_author:: AUTHOR is not set and no global git user.name or user.email is configured" >&2
	return 1
}

# Determines the directory containing the script
#
# Outputs:
# - Writes script directory path to stdout
#
# Returns:
# - 0 always
set_context() {
	local script_dir

	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		script_dir=$(dirname "${BASH_SOURCE[0]}")
		if [[ "${script_dir}" != /* ]]; then
			script_dir="$(cd "${script_dir}" && pwd)"
		fi
	fi

	echo "${script_dir}"

	return 0
}

# Validates git repository and author existence
#
# Side Effects:
# - Sets REPO_NAME global variable
#
# Returns:
# - 0 on success
# - 1 on validation failure
validate_repo() {
	local sha
	local author_output

	if [[ -z "${REPO_PATH}" || -z "${AUTHOR}" ]]; then
		echo "validate_repo:: REPO_PATH or AUTHOR is not set" >&2
		return 1
	fi

	if ! REPO_NAME=$(basename "$(git -C "${REPO_PATH}" rev-parse --show-toplevel 2>/dev/null)"); then
		echo "validate_repo:: Failed to get repository name" >&2
		return 1
	fi

	if ! git -C "${REPO_PATH}" log --author="${AUTHOR}" --max-count=1 --oneline >/dev/null 2>&1; then
		echo "validate_repo:: Author '${AUTHOR}' not found in the commit history" >&2
		return 1
	fi

	author_output=$(git -C "${REPO_PATH}" log --author="${AUTHOR}" --max-count=1 --oneline 2>/dev/null)
	if [[ -z "${author_output}" ]]; then
		echo "validate_repo:: Author '${AUTHOR}' not found in the commit history" >&2
		return 1
	fi

	if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
		for sha in "${COMMIT_SHAS[@]}"; do
			if ! git -C "${REPO_PATH}" rev-parse "${sha}" >/dev/null 2>&1; then
				echo "validate_repo:: Commit '${sha}' not found in git history" >&2
				return 1
			fi
		done
	fi

	return 0
}

# Parses and validates date string in YYYY-MM-DD format
#
# Arguments:
#   $1 - date_string: Date string to parse
#
# Outputs:
# - Writes validated date string to stdout on success
#
# Returns:
# - 0 on success
# - 1 on parse failure
parse_date() {
	local date_string="$1"
	local result

	if [[ -z "${date_string}" ]]; then
		echo "parse_date:: date_string is required" >&2
		return 1
	fi

	if [[ ! "${date_string}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		echo "parse_date:: Invalid date format: ${date_string}. Expected YYYY-MM-DD" >&2
		return 1
	fi

	if [[ $(uname) == "Darwin" ]]; then
		if ! result=$(date -j -f "%Y-%m-%d" "${date_string}" +%Y-%m-%d 2>/dev/null); then
			return 1
		fi
	else
		if ! result=$(date -d "${date_string}" +%Y-%m-%d 2>/dev/null); then
			return 1
		fi
	fi

	echo "${result}"

	return 0
}

# Determines start and end dates for commit analysis period
#
# Side Effects:
# - Sets PERIOD_START and PERIOD_END global variables
#
# Returns:
# - 0 on success
# - 1 on failure
determine_period_dates() {
	if [[ -z "${RANGE_DATE1}" ]]; then
		echo "determine_period_dates:: --range requires at least one date" >&2
		return 1
	fi

	if ! PERIOD_START=$(parse_date "${RANGE_DATE1}"); then
		echo "determine_period_dates:: Failed to parse start date: ${RANGE_DATE1}" >&2
		return 1
	fi

	if [[ -n "${RANGE_DATE2}" ]]; then
		if ! PERIOD_END=$(parse_date "${RANGE_DATE2}"); then
			echo "determine_period_dates:: Failed to parse end date: ${RANGE_DATE2}" >&2
			return 1
		fi
	else
		if ! PERIOD_END=$(date +%Y-%m-%d 2>/dev/null); then
			echo "determine_period_dates:: Failed to get current date" >&2
			return 1
		fi
	fi

	return 0
}

# Sanitizes author and branch names for filesystem-safe directory names
#
# Arguments:
#   $1 - author: Author name
#   $2 - branch: Branch name
#
# Outputs:
# - Writes sanitized author and branch names to stdout on separate lines
#
# Returns:
# - 0 on success
# - 1 on failure
sanitize_names() {
	local author="$1"
	local branch="$2"
	local sanitized_author
	local sanitized_branch

	if [[ -z "${author}" || -z "${branch}" ]]; then
		echo "sanitize_names:: author or branch is not set" >&2
		return 1
	fi

	if ! sanitized_author=$(echo "${author}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'); then
		echo "sanitize_names:: Failed to sanitize author name" >&2
		sanitized_author=$(echo "${author}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' || echo "unknown_author")
	fi

	if ! sanitized_branch=$(tr -c 'a-zA-Z0-9_-' '_' <<<"${branch}" | sed 's/_$//'); then
		echo "sanitize_names:: Failed to sanitize branch name" >&2
		sanitized_branch=$(tr -c 'a-zA-Z0-9_-' '_' <<<"${branch}" | sed 's/_$//' || echo "unknown_branch")
	fi

	echo "${sanitized_author}"
	echo "${sanitized_branch}"

	return 0
}

# Retrieves commits matching author criteria from git repository
#
# Side Effects:
# - Sets COMMITS global variable with newline-separated commit hashes
#
# Returns:
# - 0 on success
# - 1 on failure
get_commits() {
	local sha
	local short_hash
	local log_output
	local author_lower
	local since_date
	local until_date
	local git_log_cmd
	local hash
	local name
	local email
	local subject
	local parents
	local name_lower
	local email_lower
	local subject_lower
	local include_commit
	local parent_count
	local parent

	if [[ -z "${REPO_PATH}" || -z "${BRANCH}" || -z "${AUTHOR}" ]]; then
		echo "get_commits:: REPO_PATH, BRANCH, or AUTHOR is not set" >&2
		return 1
	fi

	if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
		COMMITS=""
		for sha in "${COMMIT_SHAS[@]}"; do
			if ! short_hash=$(git -C "${REPO_PATH}" rev-parse --short "${sha}" 2>/dev/null); then
				echo "get_commits:: Failed to get short hash for commit: ${sha}" >&2
				continue
			fi
			if [[ -z "${COMMITS}" ]]; then
				COMMITS="${short_hash}"
			else
				COMMITS="${COMMITS}"$'\n'"${short_hash}"
			fi
		done
		return 0
	fi

	since_date="${PERIOD_START} 00:00:00"
	until_date="${PERIOD_END} 23:59:59"

	git_log_cmd=(git -C "${REPO_PATH}" log --pretty=format:"%h%x1f%an%x1f%ae%x1f%s%x1f%P" --since="${since_date}" --until="${until_date}" "${BRANCH}")

	if ! log_output=$("${git_log_cmd[@]}" 2>/dev/null); then
		echo "get_commits:: Failed to get commit list" >&2
		return 1
	fi

	if ! author_lower=$(echo "${AUTHOR}" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
		author_lower="${AUTHOR}"
	fi

	COMMITS=""
	while IFS=$'\x1f' read -r hash name email subject parents; do
		if [[ -z "${hash}" ]]; then
			continue
		fi

		if ! name_lower=$(echo "${name}" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			name_lower="${name}"
		fi
		if ! email_lower=$(echo "${email}" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			email_lower="${email}"
		fi
		if ! subject_lower=$(echo "${subject}" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			subject_lower="${subject}"
		fi

		include_commit="false"
		parent_count=0
		if [[ -n "${parents}" ]]; then
			local parents_array
			IFS=' ' read -ra parents_array <<<"${parents}"
			for parent in "${parents_array[@]}"; do
				((++parent_count))
			done
		fi

		if [[ "${ONLY_MERGES}" == "true" ]]; then
			if ((parent_count > 1)) && [[ "${subject_lower}" == *"${author_lower}"* ]]; then
				include_commit="true"
			fi
		else
			if [[ "${name_lower}" == *"${author_lower}"* ]] || [[ "${email_lower}" == *"${author_lower}"* ]]; then
				include_commit="true"
			elif ((parent_count > 1)) && [[ "${subject_lower}" == *"${author_lower}"* ]]; then
				include_commit="true"
			fi
		fi

		if [[ "${include_commit}" == "true" ]]; then
			if [[ -z "${COMMITS}" ]]; then
				COMMITS="${hash}"
			else
				COMMITS="${COMMITS}"$'\n'"${hash}"
			fi
		fi
	done <<<"${log_output}"

	return 0
}

# Writes commit message and changed files to output file
#
# Arguments:
#   $1 - commit: Commit hash
#   $2 - output_file: Output file path
#
# Returns:
# - 0 on success
# - 1 on failure
write_commit_details() {
	local commit="$1"
	local output_file="$2"
	local failed

	if [[ -z "${commit}" || -z "${output_file}" ]]; then
		echo "write_commit_details:: commit or output_file is not set" >&2
		return 1
	fi

	if [[ -z "${REPO_PATH}" ]]; then
		echo "write_commit_details:: REPO_PATH is not set" >&2
		return 1
	fi

	if [[ -f "${output_file}" ]]; then
		return 0
	fi

	failed=0
	if ! git -C "${REPO_PATH}" log -p --format="%B" -n 1 "${commit}" >>"${output_file}" 2>/dev/null; then
		echo "write_commit_details:: Failed to get commit details for ${commit}" >&2
		failed=1
	fi

	if ! git -C "${REPO_PATH}" diff-tree --no-commit-id --name-only -r "${commit}" >>"${output_file}" 2>/dev/null; then
		echo "write_commit_details:: Failed to get changed files for ${commit}" >&2
		failed=1
	fi

	if [[ "${failed}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

# Helper function to print a separator line
#
# Inputs:
# - None, uses COLUMNS environment variable if available
#
# Outputs:
# - Writes separator line to stdout
#
# Side Effects:
# - Outputs a separator line to stdout
#
# Returns:
# - 0 always
print_separator() {
	local width
	local i
	local sep_char="━"

	width="${COLUMNS:-80}"
	if [[ "${width}" -gt 120 ]]; then
		width=120
	fi

	printf "%s" "${COLOR_SEPARATOR}"
	for ((i = 0; i < width; i++)); do
		printf "%s" "${sep_char}"
	done
	printf "%s\n" "${COLOR_RESET}"

	return 0
}

# Processes commits and writes details to output directories
#
# Side Effects:
# - Creates commit-specific directories and files
# - Sets COMMIT_DIRS global array
# - Outputs commit information to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
process_commits() {
	local commit_count
	local commit_array
	local total_commits
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

	commit_count=0
	COMMIT_DIRS=()
	commit_array=()
	while read -r commit; do
		if [[ -n "${commit}" ]]; then
			commit_array+=("${commit}")
		fi
	done <<<"${COMMITS}"

	total_commits=${#commit_array[@]}

	if [[ ${total_commits} -eq 0 ]]; then
		echo "No commits found"
		return 0
	fi

	for commit in "${commit_array[@]}"; do
		((++commit_count))
		COMMIT="${commit}"

		if ! short_commit=$(git -C "${REPO_PATH}" rev-parse --short "${commit}" 2>/dev/null); then
			echo "process_commits:: Failed to get short commit hash for ${commit}" >&2
			continue
		fi

		commit_dir="${OUTPUT_PATH}/${short_commit}"
		if ! mkdir -p "${commit_dir}" 2>/dev/null; then
			echo "process_commits:: Failed to create commit directory: ${commit_dir}" >&2
			continue
		fi
		COMMIT_DIRS+=("${commit_dir}")

		diff_file="${commit_dir}/diff.txt"
		if [[ ! -f "${diff_file}" ]]; then
			if ! write_commit_details "${commit}" "${diff_file}"; then
				echo "process_commits:: Failed to write commit details for ${commit}" >&2
			fi
		fi

		jira_link=""
		if [[ "${CHECK_JIRA}" == "true" ]]; then
			jira_file="${commit_dir}/jira.txt"
			JIRA_FILE="${jira_file}"
			export JIRA_FILE
			export COMMIT
			if ! write_jira_details_to_file 2>&1; then
				echo "process_commits:: Failed to write JIRA details for ${commit}" >&2
			fi
			jira_link="${jira_file}"
		fi

		github_link=""
		if [[ "${CHECK_GITHUB}" == "true" ]]; then
			pr_file="${commit_dir}/pr.json"
			if [[ ! -f "${pr_file}" ]]; then
				PR_FILE="${pr_file}"
				export PR_FILE
				export COMMIT
				if ! write_pr_details_to_file 2>&1; then
					echo "process_commits:: Failed to write PR details for ${commit}" >&2
				fi
			fi
			github_link="${pr_file}"
		fi

		printf "\n"
		print_separator
		printf "%sCommit:%s %s%s%s%s\n" "${COLOR_LABEL}" "${COLOR_RESET}" "${COLOR_COMMIT}" "${COLOR_BOLD}" "${short_commit}" "${COLOR_RESET}"
		printf "%sDiff:%s   %s%s%s\n" "${COLOR_LABEL}" "${COLOR_RESET}" "${COLOR_PATH}" "${diff_file}" "${COLOR_RESET}"
		if [[ -n "${jira_link}" ]]; then
			printf "%sJira:%s   %s%s%s\n" "${COLOR_LABEL}" "${COLOR_RESET}" "${COLOR_JIRA}" "${jira_link}" "${COLOR_RESET}"
		fi
		if [[ -n "${github_link}" ]]; then
			printf "%sGithub:%s %s%s%s\n" "${COLOR_LABEL}" "${COLOR_RESET}" "${COLOR_GITHUB}" "${github_link}" "${COLOR_RESET}"
		fi
	done

	return 0
}

main() {
	local sanitized_names_output
	local sanitized_author
	local sanitized_branch

	COMMIT_SHAS=()

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
		--github)
			CHECK_GITHUB=true
			shift
			;;
		--jira)
			CHECK_JIRA=true
			shift
			;;
		*)
			echo "main:: Unknown option '$1'" >&2
			echo "main:: Use '$(basename "$0") --help' for usage information" >&2
			return 1
			;;
		esac
	done

	if [[ -z "${OUTPUT_DIR}" ]]; then
		OUTPUT_DIR="${HOME}/${DEFAULT_OUTPUT_DIR}"
	fi

	if ! set_default_author; then
		return 1
	fi

	if ! validate_args; then
		return 1
	fi

	if ! validate_repo; then
		return 1
	fi

	if [[ ${#COMMIT_SHAS[@]} -eq 0 ]]; then
		if ! determine_period_dates; then
			return 1
		fi
	fi

	if ! get_commits; then
		return 1
	fi

	if ! sanitized_names_output=$(sanitize_names "${AUTHOR}" "${BRANCH}"); then
		echo "main:: Failed to sanitize names" >&2
		return 1
	fi

	sanitized_author=$(echo "${sanitized_names_output}" | head -n 1)
	sanitized_branch=$(echo "${sanitized_names_output}" | tail -n 1)

	OUTPUT_PATH="${OUTPUT_DIR}/${REPO_NAME}/${sanitized_branch}/${sanitized_author}"

	if ! mkdir -p "${OUTPUT_PATH}" 2>/dev/null; then
		echo "main:: Failed to create output directory: ${OUTPUT_PATH}" >&2
		return 1
	fi

	export REPO_PATH

	if [[ "${CHECK_GITHUB}" == "true" ]] && [[ -f "${GITHUB_SCRIPT}" ]]; then
		source "${GITHUB_SCRIPT}"
	fi

	if [[ "${CHECK_JIRA}" == "true" ]] && [[ -f "${JIRA_SCRIPT}" ]]; then
		source "${JIRA_SCRIPT}"
	fi

	process_commits

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
