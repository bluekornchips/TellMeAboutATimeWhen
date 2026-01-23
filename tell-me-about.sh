#!/usr/bin/env bash
#
# Git commit analyzer script that extracts commit details for a specific author
# within a time range from a git repository and saves them to a file.
#

set -eo pipefail

usage() {
	cat <<EOF
Usage: $(basename "$0") -p <path> -b <branch> -a <author> [--range <date> | --range <start_date> <end_date>] [--sha <commit> ...] [--include-merges] [--github] [--jira]

Analyze git commits by author and save detailed information to commit-specific directories.

Each commit is saved to: OUTPUT_DIR/REPO_NAME/BRANCH/AUTHOR/SHORT_COMMIT/
  - pr.json  : Pull request details (if --github is used)
  - diff.txt : Commit message and changed files
  - jira.txt : JIRA ticket details (if --jira is used)

Options:
  -p <path>      : Path to the repository (required)
  -b <branch>    : Branch to analyze (required)
  -a <author>    : Author of commits (required)
  --range <date> : Analyze commits since date (one arg) or between two dates (two args)
  --sha <commit> : Analyze specific commit(s) by SHA (can be used multiple times, replaces --range)
  --include-merges : Include merge commits with subjects matching author
  --github         : Include GitHub details for commits, such as pull request information (requires GitHub CLI)
  --jira         : Include JIRA ticket details for commits that reference tickets (requires JIRA CLI)
  -h, --help     : Show this help message

EOF
}

########################################
# Constants
########################################
DEFAULT_OUTPUT_DIR="tmaatw"
DEFAULT_GITHUB_SCRIPT="tools/github.sh"
DEFAULT_JIRA_SCRIPT="tools/jira.sh"

########################################
# Input Defaults
########################################
OUTPUT_DIR="${OUTPUT_DIR:-}"
REPO_PATH="${REPO_PATH:-}"
BRANCH="${BRANCH:-}"
AUTHOR="${AUTHOR:-}"
RANGE_DATE1="${RANGE_DATE1:-}"
RANGE_DATE2="${RANGE_DATE2:-}"
COMMIT_SHAS=()
INCLUDE_MERGES="${INCLUDE_MERGES:-false}"
CHECK_GITHUB="${CHECK_GITHUB:-false}"
CHECK_JIRA="${CHECK_JIRA:-false}"

########################################
# Helper Functions
########################################

cleanup() {
	popd >/dev/null 2>&1 || true
	return 0
}

# Initialize script paths and output directory
#
# Side Effects:
# - Sets OUTPUT_DIR, GITHUB_SCRIPT, JIRA_SCRIPT globals
initialize_script_context() {
	local script_path=""
	local script_dir=""

	if [[ -z "${OUTPUT_DIR}" ]]; then
		OUTPUT_DIR="${HOME}/${DEFAULT_OUTPUT_DIR}"
	fi

	if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
		echo "initialize_script_context:: BASH_SOURCE is not set" >&2
		return 1
	fi

	script_path="${BASH_SOURCE[0]}"
	if [[ -z "$script_path" ]]; then
		echo "initialize_script_context:: Script path is empty" >&2
		return 1
	fi

	if [[ -L "$script_path" ]]; then
		if command -v readlink >/dev/null 2>&1; then
			if [[ $(uname) == "Darwin" ]]; then
				script_path=$(readlink "$script_path" 2>/dev/null || echo "$script_path")
			else
				script_path=$(readlink -f "$script_path" 2>/dev/null || echo "$script_path")
			fi
		fi
	fi

	if [[ "$script_path" != /* ]]; then
		script_path="$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")"
	fi

	script_dir=$(dirname "$script_path")
	if [[ -z "$script_dir" ]]; then
		echo "initialize_script_context:: SCRIPT_DIR resolution failed" >&2
		return 1
	fi

	GITHUB_SCRIPT="${script_dir}/${DEFAULT_GITHUB_SCRIPT}"
	JIRA_SCRIPT="${script_dir}/${DEFAULT_JIRA_SCRIPT}"

	return 0
}

validate_required_args() {
	if [[ -z "$REPO_PATH" || -z "$BRANCH" || -z "$AUTHOR" ]]; then
		echo "validate_required_args:: Missing required arguments" >&2
		usage
		return 1
	fi

	return 0
}

validate_repo_path() {
	if [[ ! -d "$REPO_PATH" ]]; then
		echo "validate_repo_path:: Invalid repository path: $REPO_PATH" >&2
		return 1
	fi

	return 0
}

change_to_repo() {
	if ! pushd "$REPO_PATH" >/dev/null; then
		echo "change_to_repo:: Failed to change directory to $REPO_PATH" >&2
		return 1
	fi

	return 0
}

get_repo_name() {
	if ! REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)"); then
		echo "get_repo_name:: Failed to get repository name" >&2
		popd >/dev/null || return 1
		return 1
	fi

	return 0
}

validate_author_exists() {
	if ! git log --author="$AUTHOR" --max-count=1 --oneline >/dev/null 2>&1; then
		echo "validate_author_exists:: Author '$AUTHOR' not found in the commit history" >&2
		return 1
	fi

	local author_output
	author_output=$(git log --author="$AUTHOR" --max-count=1 --oneline 2>/dev/null)
	if [[ -z "$author_output" ]]; then
		echo "validate_author_exists:: Author '$AUTHOR' not found in the commit history" >&2
		return 1
	fi

	return 0
}

validate_commit_shas() {
	local sha

	if [[ ${#COMMIT_SHAS[@]} -eq 0 ]]; then
		return 0
	fi

	for sha in "${COMMIT_SHAS[@]}"; do
		if ! git rev-parse "$sha" >/dev/null 2>&1; then
			echo "validate_commit_shas:: Commit '$sha' not found in git history" >&2
			return 1
		fi
	done

	return 0
}

parse_date() {
	local date_string="$1"
	local result=""

	if [[ -z "$date_string" ]]; then
		echo "parse_date:: date_string is required" >&2
		return 1
	fi

	if [[ "$date_string" != "1 week ago" ]] && [[ ! "$date_string" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		echo "parse_date:: Unsupported date format: $date_string" >&2
		return 1
	fi

	if [[ $(uname) == "Darwin" ]]; then
		if [[ "$date_string" == "1 week ago" ]]; then
			if ! result=$(date -v-1w +%Y-%m-%d 2>/dev/null); then
				return 1
			fi
		else
			if ! result=$(date -j -f "%Y-%m-%d" "$date_string" +%Y-%m-%d 2>/dev/null); then
				return 1
			fi
		fi
	else
		if ! result=$(date -d "$date_string" +%Y-%m-%d 2>/dev/null); then
			return 1
		fi
	fi

	echo "$result"

	return 0
}

check_dependencies() {
	local missing=0

	for cmd in git sed tr wc date; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "check_dependencies:: Missing required command: $cmd" >&2
			missing=1
		fi
	done

	if [[ "$missing" -ne 0 ]]; then
		return 1
	fi

	return 0
}

determine_period_dates() {
	if [[ -n "$RANGE_DATE1" && -n "$RANGE_DATE2" ]]; then
		if ! PERIOD_START=$(parse_date "$RANGE_DATE1"); then
			echo "determine_period_dates:: Failed to parse date: $RANGE_DATE1" >&2
			return 1
		fi
		if ! PERIOD_END=$(parse_date "$RANGE_DATE2"); then
			echo "determine_period_dates:: Failed to parse date: $RANGE_DATE2" >&2
			return 1
		fi
	elif [[ -n "$RANGE_DATE1" ]]; then
		if ! PERIOD_START=$(parse_date "$RANGE_DATE1"); then
			echo "determine_period_dates:: Failed to parse date: $RANGE_DATE1" >&2
			return 1
		fi
		if ! PERIOD_END=$(date +%Y-%m-%d 2>/dev/null); then
			echo "determine_period_dates:: Failed to get current date" >&2
			return 1
		fi
	else
		if ! PERIOD_START=$(parse_date "1 week ago"); then
			echo "determine_period_dates:: Failed to calculate date one week ago" >&2
			return 1
		fi
		if ! PERIOD_END=$(date +%Y-%m-%d 2>/dev/null); then
			echo "determine_period_dates:: Failed to get current date" >&2
			return 1
		fi
	fi

	return 0
}

get_commits() {
	local sha
	local short_hash
	local log_output
	local author_lower
	local since_date=""
	local until_date=""

	if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
		COMMITS=""
		for sha in "${COMMIT_SHAS[@]}"; do
			if ! short_hash=$(git rev-parse --short "$sha" 2>/dev/null); then
				echo "get_commits:: Failed to get short hash for commit: $sha" >&2
				continue
			fi
			if [[ -z "$COMMITS" ]]; then
				COMMITS="$short_hash"
			else
				COMMITS="${COMMITS}"$'\n'"${short_hash}"
			fi
		done
		return 0
	fi

	if [[ -n "$PERIOD_START" && -n "$PERIOD_END" ]]; then
		since_date="${PERIOD_START} 00:00:00"
		until_date="${PERIOD_END} 23:59:59"
	elif [[ -n "$PERIOD_START" ]]; then
		since_date="${PERIOD_START} 00:00:00"
	else
		since_date="1 week ago"
	fi

	local git_log_cmd=(git log --pretty=format:"%h%x1f%an%x1f%ae%x1f%s%x1f%P")
	if [[ -n "$since_date" ]]; then
		git_log_cmd+=(--since="$since_date")
	fi
	if [[ -n "$until_date" ]]; then
		git_log_cmd+=(--until="$until_date")
	fi

	git_log_cmd+=("$BRANCH")

	if ! log_output=$("${git_log_cmd[@]}" 2>/dev/null); then
		echo "get_commits:: Failed to get commit list" >&2
		return 1
	fi

	if ! author_lower=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
		author_lower="$AUTHOR"
	fi

	COMMITS=""
	local hash
	local name
	local email
	local subject
	local parents
	while IFS=$'\x1f' read -r hash name email subject parents; do
		if [[ -z "$hash" ]]; then
			continue
		fi

		local name_lower
		local email_lower
		local subject_lower
		if ! name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			name_lower="$name"
		fi
		if ! email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			email_lower="$email"
		fi
		if ! subject_lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]' 2>/dev/null); then
			subject_lower="$subject"
		fi

		local include_commit="false"
		if [[ "$name_lower" == *"$author_lower"* ]] || [[ "$email_lower" == *"$author_lower"* ]]; then
			include_commit="true"
		elif [[ "$INCLUDE_MERGES" == "true" ]]; then
			local parent_count=0
			local parent
			for parent in $parents; do
				((++parent_count))
			done

			if ((parent_count > 1)) && [[ "$subject_lower" == *"${author_lower}"* ]]; then
				include_commit="true"
			fi
		fi

		if [[ "$include_commit" == "true" ]]; then
			if [[ -z "$COMMITS" ]]; then
				COMMITS="$hash"
			else
				COMMITS="${COMMITS}"$'\n'"$hash"
			fi
		fi
	done <<<"$log_output"

	return 0
}

write_commit_details() {
	local commit="$1"
	local output_file="$2"

	if [[ -z "$commit" || -z "$output_file" ]]; then
		echo "write_commit_details:: commit or output_file is not set" >&2
		return 1
	fi

	if [[ -f "$output_file" ]]; then
		return 0
	fi

	if ! git log -p --format="%B" -n 1 "$commit" >>"$output_file" 2>/dev/null; then
		echo "write_commit_details:: Failed to get commit details for $commit" >&2
	fi

	if ! git diff-tree --no-commit-id --name-only -r "$commit" >>"$output_file" 2>/dev/null; then
		echo "write_commit_details:: Failed to get changed files for $commit" >&2
	fi

	return 0
}

sanitize_names() {
	local author="$1"
	local branch="$2"

	if [[ -z "$author" || -z "$branch" ]]; then
		echo "sanitize_names:: author or branch is not set" >&2
		return 1
	fi

	local sanitized_author
	if ! sanitized_author=$(echo "$author" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'); then
		echo "sanitize_names:: Failed to sanitize author name" >&2
		sanitized_author=$(echo "$author" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' || echo "unknown_author")
	fi

	local sanitized_branch
	if ! sanitized_branch=$(tr -c 'a-zA-Z0-9_-' '_' <<<"$branch" | sed 's/_$//'); then
		echo "sanitize_names:: Failed to sanitize branch name" >&2
		sanitized_branch=$(tr -c 'a-zA-Z0-9_-' '_' <<<"$branch" | sed 's/_$//' || echo "unknown_branch")
	fi

	echo "${sanitized_author}"
	echo "${sanitized_branch}"

	return 0
}

process_commits() {
	local commit_count=0
	COMMIT_DIRS=()

	local commit_array=()
	while read -r commit; do
		if [[ -n "$commit" ]]; then
			commit_array+=("$commit")
		fi
	done <<<"$COMMITS"

	local total_commits=${#commit_array[@]}

	if [[ $total_commits -eq 0 ]]; then
		echo "No commits found"
		return 0
	fi

	for commit in "${commit_array[@]}"; do
		((++commit_count))
		COMMIT="$commit"

		local short_commit
		if ! short_commit=$(git rev-parse --short "$commit" 2>/dev/null); then
			echo "process_commits:: Failed to get short commit hash for $commit" >&2
			continue
		fi

		local commit_dir="${OUTPUT_PATH}/${short_commit}"
		if ! mkdir -p "$commit_dir" 2>/dev/null; then
			echo "process_commits:: Failed to create commit directory: $commit_dir" >&2
			continue
		fi
		COMMIT_DIRS+=("$commit_dir")

		echo "$short_commit"
		echo "========"

		local diff_file="${commit_dir}/diff.txt"
		if [[ ! -f "$diff_file" ]]; then
			if ! write_commit_details "$commit" "$diff_file"; then
				echo "process_commits:: Failed to write commit details for $commit" >&2
			fi
		fi

		if [[ "$CHECK_JIRA" == "true" ]]; then
			local jira_file="${commit_dir}/jira.txt"
			local jira_status=""
			JIRA_FILE="$jira_file"
			if write_jira_details_to_file; then
				if [[ -s "$jira_file" ]]; then
					jira_status="Wrote to $jira_file"
				else
					jira_status="No tickets $jira_file"
				fi
			else
				jira_status="Failed | $jira_file"
			fi
			echo "jira: $jira_status"
		fi

		if [[ "$CHECK_GITHUB" == "true" ]]; then
			local pr_file="${commit_dir}/pr.json"
			local github_status=""
			if [[ -f "$pr_file" ]]; then
				github_status="$pr_file"
			else
				PR_FILE="$pr_file"
				if write_pr_details_to_file; then
					if [[ -f "$pr_file" ]]; then
						github_status="Wrote to $pr_file"
					else
						github_status="No PRs | $pr_file"
					fi
				else
					github_status="Failed | $pr_file"
				fi
			fi
			echo "github: $github_status"
		fi
	done
	return 0
}

main() {
	trap cleanup EXIT
	trap 'popd >/dev/null 2>&1 || true' ERR

	while [[ $# -gt 0 ]]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		-p)
			REPO_PATH="$2"
			shift 2
			;;
		-b)
			BRANCH="$2"
			shift 2
			;;
		-a)
			AUTHOR="$2"
			shift 2
			;;
		--range)
			if [[ ${#COMMIT_SHAS[@]} -gt 0 ]]; then
				echo "main:: --range cannot be used with --sha" >&2
				return 1
			fi
			if [[ -n "$RANGE_DATE1" ]]; then
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
			if [[ -n "$RANGE_DATE1" ]]; then
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
		--include-merges)
			INCLUDE_MERGES=true
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

	if ! initialize_script_context; then
		return 1
	fi

	if ! check_dependencies; then
		return 1
	fi

	if ! validate_required_args; then
		return 1
	fi

	if ! validate_repo_path; then
		return 1
	fi

	if ! change_to_repo; then
		return 1
	fi

	if ! get_repo_name; then
		popd >/dev/null || return 1
		return 1
	fi

	if ! validate_author_exists; then
		popd >/dev/null || return 1
		return 1
	fi

	if [[ ${#COMMIT_SHAS[@]} -eq 0 ]]; then
		if ! determine_period_dates; then
			popd >/dev/null || return 1
			return 1
		fi
	else
		if ! validate_commit_shas; then
			popd >/dev/null || return 1
			return 1
		fi
	fi

	if ! get_commits; then
		popd >/dev/null || return 1
		return 1
	fi

	local sanitized_names_output
	if ! sanitized_names_output=$(sanitize_names "$AUTHOR" "$BRANCH"); then
		echo "main:: Failed to sanitize names" >&2
		popd >/dev/null || return 1
		return 1
	fi

	local sanitized_author
	sanitized_author=$(echo "$sanitized_names_output" | head -n 1)
	local sanitized_branch
	sanitized_branch=$(echo "$sanitized_names_output" | tail -n 1)

	OUTPUT_PATH="$OUTPUT_DIR/${REPO_NAME}/${sanitized_branch}/${sanitized_author}"

	if ! mkdir -p "$OUTPUT_PATH" 2>/dev/null; then
		echo "main:: Failed to create output directory: $OUTPUT_PATH" >&2
		popd >/dev/null || return 1
		return 1
	fi

	if [[ "$CHECK_GITHUB" == "true" ]]; then
		if [[ -f "$GITHUB_SCRIPT" ]]; then
			if ! source "$GITHUB_SCRIPT"; then
				echo "main:: Failed to source GitHub script: $GITHUB_SCRIPT" >&2
				popd >/dev/null || return 1
				return 1
			fi
		fi
	fi

	if [[ "$CHECK_JIRA" == "true" ]]; then
		if [[ -f "$JIRA_SCRIPT" ]]; then
			if ! source "$JIRA_SCRIPT"; then
				echo "main:: Failed to source JIRA script: $JIRA_SCRIPT" >&2
				popd >/dev/null || return 1
				return 1
			fi
		fi
	fi

	process_commits

	popd >/dev/null || true

	if (( ${#COMMIT_DIRS[@]} > 0 )); then
		cat <<EOF
Commit directories
===============================

EOF
		local commit_dir
		for commit_dir in "${COMMIT_DIRS[@]}"; do
			echo "$commit_dir"
		done
	fi
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
