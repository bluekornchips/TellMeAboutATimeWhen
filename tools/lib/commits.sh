#!/usr/bin/env bash
#
# Commit selection, period, and diff helpers for tell-me-about.sh.
#

declare -F get_commits >/dev/null 2>&1 && return 0

# Parses and validates a date string in YYYY-MM-DD format
#
# Inputs:
# - $1: date_string
#
# Outputs:
# - Validated date string to stdout
#
# Returns:
# - 0 on success
# - 1 on parse failure
parse_date() {
	local date_string="$1"

	if [[ -z "${date_string}" ]]; then
		echo "parse_date:: date_string is required" >&2
		return 1
	fi

	if [[ ! "${date_string}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		echo "parse_date:: Invalid date format: ${date_string}. Expected YYYY-MM-DD" >&2
		return 1
	fi

	local result
	if [[ "$(uname)" == "Darwin" ]]; then
		if ! result=$(date -j -f "%Y-%m-%d" "${date_string}" +%Y-%m-%d 2>/dev/null); then
			echo "parse_date:: Failed to parse date: ${date_string}" >&2
			return 1
		fi
	else
		if ! result=$(date -d "${date_string}" +%Y-%m-%d 2>/dev/null); then
			echo "parse_date:: Failed to parse date: ${date_string}" >&2
			return 1
		fi
	fi

	echo "${result}"

	return 0
}

# Determines start and end dates for commit analysis
#
# Side Effects:
# - Sets PERIOD_START and PERIOD_END
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

	if [[ "${PERIOD_START}" > "${PERIOD_END}" ]]; then
		echo "determine_period_dates:: start date ${PERIOD_START} is after end date ${PERIOD_END}" >&2
		return 1
	fi

	return 0
}

# Sanitizes author and branch names for directory names
#
# Inputs:
# - $1: author
# - $2: branch
#
# Side Effects:
# - Sets SANITIZED_AUTHOR and SANITIZED_BRANCH
#
# Returns:
# - 0 on success
# - 1 on failure
sanitize_names() {
	local author="$1"
	local branch="$2"

	SANITIZED_AUTHOR=""
	SANITIZED_BRANCH=""

	if [[ -z "${author}" || -z "${branch}" ]]; then
		echo "sanitize_names:: author or branch is not set" >&2
		return 1
	fi

	if ! SANITIZED_AUTHOR=$(printf '%s' "${author}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'); then
		SANITIZED_AUTHOR="unknown_author"
	fi

	if ! SANITIZED_BRANCH=$(tr -c 'a-zA-Z0-9_-' '_' <<<"${branch}" | sed 's/^_//;s/_$//'); then
		SANITIZED_BRANCH="unknown_branch"
	fi

	return 0
}

# Appends a commit hash to COMMITS when it is not already present
#
# Inputs:
# - $1: commit hash
#
# Side Effects:
# - Appends to COMMITS
#
# Returns:
# - 0 always
append_unique_commit() {
	local hash="$1"

	if [[ -n "${hash}" ]] && ! array_contains "${hash}" "${COMMITS[@]}"; then
		COMMITS+=("${hash}")
	fi

	return 0
}

# Adds merge commits whose subject contains AUTHOR
#
# Inputs:
# - $1: since_date
# - $2: until_date
#
# Side Effects:
# - Appends matching hashes to COMMITS
#
# Returns:
# - 0 on success
# - 1 on failure
collect_merge_commits_for_author() {
	local since_date="$1"
	local until_date="$2"

	local author_lower
	if ! author_lower=$(printf '%s' "${AUTHOR}" | tr '[:upper:]' '[:lower:]'); then
		author_lower="${AUTHOR}"
	fi

	local log_output
	if ! log_output=$(git_cmd log --merges --pretty=format:"%h%x1f%s" --since="${since_date}" --until="${until_date}" "${BRANCH}" 2>/dev/null); then
		echo "collect_merge_commits_for_author:: Failed to get merge commit list" >&2
		return 1
	fi

	local hash
	local subject
	local subject_lower
	while IFS=$'\x1f' read -r hash subject; do
		if [[ -z "${hash}" ]]; then
			continue
		fi
		if ! subject_lower=$(printf '%s' "${subject}" | tr '[:upper:]' '[:lower:]'); then
			subject_lower="${subject}"
		fi
		if [[ "${subject_lower}" == *"${author_lower}"* ]]; then
			append_unique_commit "${hash}"
		fi
	done <<<"${log_output}"

	return 0
}

# Retrieves commits matching author criteria
#
# Side Effects:
# - Sets COMMITS to an array of commit hashes
#
# Returns:
# - 0 on success
# - 1 on failure
get_commits() {
	COMMITS=()

	if [[ -z "${REPO_PATH}" || -z "${BRANCH}" || -z "${AUTHOR}" ]]; then
		echo "get_commits:: REPO_PATH, BRANCH, or AUTHOR is not set" >&2
		return 1
	fi

	local since_date="${PERIOD_START} 00:00:00"
	local until_date="${PERIOD_END} 23:59:59"

	local log_output
	if ! log_output=$(git_cmd log --pretty=format:"%h" --regexp-ignore-case --author="${AUTHOR}" --since="${since_date}" --until="${until_date}" "${BRANCH}" 2>/dev/null); then
		echo "get_commits:: Failed to get commit list" >&2
		return 1
	fi

	local hash
	while IFS= read -r hash; do
		append_unique_commit "${hash}"
	done <<<"${log_output}"

	collect_merge_commits_for_author "${since_date}" "${until_date}" || return 1

	return 0
}

# Writes commit message and changed files to an output file
#
# Returns 0 without writing when output_file already exists.
#
# Inputs:
# - $1: commit hash
# - $2: output file path
#
# Returns:
# - 0 on success or when output_file already exists
# - 1 on failure
write_commit_details() {
	local commit="$1"
	local output_file="$2"

	if [[ -z "${commit}" || -z "${output_file}" ]]; then
		echo "write_commit_details:: commit or output_file is not set" >&2
		return 1
	fi

	if [[ -z "${REPO_PATH}" ]]; then
		echo "write_commit_details:: REPO_PATH is not set" >&2
		return 1
	fi

	if [[ ! -f "${output_file}" ]]; then
		local failed=0
		if ! git_cmd log -p --format="%B" -n 1 "${commit}" >>"${output_file}" 2>/dev/null; then
			echo "write_commit_details:: Failed to get commit details for ${commit}" >&2
			failed=1
		fi

		if ! git_cmd diff-tree --no-commit-id --name-only -r "${commit}" >>"${output_file}" 2>/dev/null; then
			echo "write_commit_details:: Failed to get changed files for ${commit}" >&2
			failed=1
		fi

		[[ "${failed}" -ne 0 ]] && return 1
	fi

	return 0
}
