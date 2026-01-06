#!/usr/bin/env bash
#
# Git commit analyzer script that extracts commit details for a specific author
# within a time range from a git repository and saves them to a file.
#

usage() {
	cat <<EOF
Usage: $(basename "$0") -p <path> -b <branch> -a <author> [--page-size <number>] [--range <date> | --range <start_date> <end_date>]

Analyze git commits by author and save detailed information to a file.

Options:
  -p <path>           : Path to the repository (required)
  -b <branch>         : Branch to analyze (required)
  -a <author>         : Author of commits (required)
  --page-size <number>: Number of commits per output file (0 for single file, default: 0)
  --range <date>      : Analyze commits since date (one arg) or between two dates (two args)
  -h, --help          : Show this help message

EOF
}

OUTPUT_DIR="$HOME/tellmeaboutatimewhen"

# Validation functions and configuration setup
# Validate that required arguments are provided
#
# Inputs:
# - $1: repo_path
# - $2: branch
# - $3: author
#
# Side Effects:
# - Exits with error message if validation fails
validate_required_args() {
	local repo_path="$1"
	local branch="$2"
	local author="$3"

	if [[ -z "$repo_path" || -z "$branch" || -z "$author" ]]; then
		echo "validate_required_args:: Missing required arguments" >&2
		usage
		return 1
	fi

	return 0
}

# Validate that the repository path exists and is a directory
#
# Inputs:
# - $1: repo_path
#
# Side Effects:
# - Exits with error message if validation fails
validate_repo_path() {
	local repo_path="$1"

	if [[ ! -d "$repo_path" ]]; then
		echo "validate_repo_path:: Invalid repository path: $repo_path" >&2
		return 1
	fi

	return 0
}

# Change to the repository directory
#
# Inputs:
# - $1: repo_path
#
# Side Effects:
# - Changes current working directory
change_to_repo() {
	local repo_path="$1"

	if ! pushd "$repo_path" >/dev/null; then
		echo "change_to_repo:: Failed to change directory to $repo_path" >&2
		return 1
	fi

	return 0
}

# Helper functions used by main functionality
# Get the repository name from git
#
# Side Effects:
# - Sets REPO_NAME global variable
get_repo_name() {
	if ! REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)"); then
		echo "get_repo_name:: Failed to get repository name" >&2
		popd >/dev/null || return 1
		return 1
	fi

	return 0
}

# Check if author exists in git history
#
# Inputs:
# - $1: author
#
# Side Effects:
# - None
validate_author_exists() {
	local author="$1"

	# Check if git log produces any output for this author
	if ! git log --author="$author" --max-count=1 --oneline >/dev/null 2>&1; then
		echo "validate_author_exists:: Author '$author' not found in the commit history" >&2
		return 1
	fi

	# Also check that we actually got output, git log succeeds even with no results
	if [[ -z $(git log --author="$author" --max-count=1 --oneline 2>/dev/null) ]]; then
		echo "validate_author_exists:: Author '$author' not found in the commit history" >&2
		return 1
	fi

	return 0
}

# Validate that date strings can be parsed as valid dates
#
# Inputs:
# - $1: date_string
#
# Side Effects:
# - None
validate_date() {
	local date_string="$1"

	# Use date command to validate the date string
	if ! date -d "$date_string" >/dev/null 2>&1; then
		echo "validate_date:: Invalid date format: $date_string" >&2
		return 1
	fi

	return 0
}

# Validate that page_size is a non-negative integer
#
# Inputs:
# - $1: page_size
#
# Side Effects:
# - None
validate_page_size() {
	local page_size="$1"

	# Check if it's a number
	if ! [[ "$page_size" =~ ^[0-9]+$ ]]; then
		echo "validate_page_size:: Page size must be a non-negative integer: $page_size" >&2
		return 1
	fi

	return 0
}

# Determine period start and end dates for filename
#
# Inputs:
# - $1: range_date1
# - $2: range_date2
#
# Side Effects:
# - Sets PERIOD_START and PERIOD_END global variables
determine_period_dates() {
	local range_date1="$1"
	local range_date2="$2"

	if [[ -n "$range_date1" && -n "$range_date2" ]]; then
		# Two dates provided: between range_date1 and range_date2
		PERIOD_START=$(date -d "$range_date1" +%Y-%m-%d)
		PERIOD_END=$(date -d "$range_date2" +%Y-%m-%d)
	elif [[ -n "$range_date1" ]]; then
		# One date provided: since range_date1 to now
		PERIOD_START=$(date -d "$range_date1" +%Y-%m-%d)
		PERIOD_END=$(date +%Y-%m-%d)
	else
		# No dates provided: 1 week ago to now
		PERIOD_START=$(date -d "1 week ago" +%Y-%m-%d)
		PERIOD_END=$(date +%Y-%m-%d)
	fi

	return 0
}

# Core logic functions
# Get list of commits for the specified author and time range
#
# Inputs:
# - $1: author
# - $2: range_date1 (optional, start date or single date)
# - $3: range_date2 (optional, end date)
# - $4: branch
#
# Side Effects:
# - Sets COMMITS global variable
get_commits() {
	local author="$1"
	local range_date1="$2"
	local range_date2="$3"
	local branch="$4"

	local git_log_cmd=(git log --author="$author" --pretty=format:"%h")

	# Add date range arguments
	if [[ -n "$range_date1" && -n "$range_date2" ]]; then
		# Two dates provided: between range_date1 and range_date2
		git_log_cmd+=(--since="$range_date1" --until="$range_date2")
	elif [[ -n "$range_date1" ]]; then
		# One date provided: since range_date1
		git_log_cmd+=(--since="$range_date1")
	else
		# No dates provided: use default of 1 week ago
		git_log_cmd+=(--since="1 week ago")
	fi

	git_log_cmd+=("$branch")

	if ! COMMITS=$("${git_log_cmd[@]}" 2>/dev/null); then
		echo "get_commits:: Failed to get commit list" >&2
		return 1
	fi

	return 0
}

# Write commit details to output file
#
# Inputs:
# - $1: commit_hash
# - $2: output_file
#
# Side Effects:
# - Appends to the output file
write_commit_details() {
	local commit="$1"
	local output_file="$2"

	if ! git log -p --format="%B" -n 1 "$commit" >>"$output_file" 2>/dev/null; then
		echo "write_commit_details:: Warning: Failed to get commit details for $commit" >&2
	fi

	if ! git diff-tree --no-commit-id --name-only -r "$commit" >>"$output_file" 2>/dev/null; then
		echo "write_commit_details:: Warning: Failed to get changed files for $commit" >&2
	fi

	return 0
}

# Process all commits and write to paginated files
#
# Inputs:
# - $1: output_path (directory containing page files)
# - $2: page_size, 0 means all commits in one page
#
# Side Effects:
# - Creates page files in the output directory
process_commits() {
	local output_path="$1"
	local page_size="$2"
	local commit_count=0
	local page_number=1
	local current_file=""

	# Convert COMMITS to array for easier processing
	local commit_array=()
	while read -r commit; do
		if [[ -n "$commit" ]]; then
			commit_array+=("$commit")
		fi
	done <<<"$COMMITS"

	local total_commits=${#commit_array[@]}

	# Process commits with consistent page file structure
	local commits_in_page=0
	local page_commits=()
	local first_commit_hash=""
	local last_commit_hash=""

	for commit in "${commit_array[@]}"; do
		# Start new page if needed
		if [[ $commits_in_page -eq 0 ]]; then
			first_commit_hash="$commit"
			page_commits=()
		fi

		page_commits+=("$commit")
		last_commit_hash="$commit"
		((commit_count++))
		((commits_in_page++))

		# Check if page is complete, full or last commit
		local page_complete=0
		if [[ "$page_size" -gt 0 ]] && [[ $commits_in_page -eq "$page_size" ]]; then
			page_complete=1
		elif [[ $commit_count -eq $total_commits ]]; then
			page_complete=1
		fi

		if [[ $page_complete -eq 1 ]]; then
			# Write all commits in page to final filename
			current_file="$output_path/page_${page_number}_${first_commit_hash:0:7}_${last_commit_hash:0:7}.txt"
			for page_commit in "${page_commits[@]}"; do
				write_commit_details "$page_commit" "$current_file"
			done
			# Start new page if current page is full, but not if it's just the last commit
			if [[ "$page_size" -gt 0 ]] && [[ $commits_in_page -eq "$page_size" ]]; then
				commits_in_page=0
				((page_number++))
			fi
		fi
	done

	echo "process_commits:: Processed $commit_count commits"
	return 0
}

# Main entry point
main() {
	local repo_path=""
	local branch=""
	local author=""
	local range_date1=""
	local range_date2=""
	local page_size=0

	while [[ $# -gt 0 ]]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		-p)
			repo_path="$2"
			shift 2
			;;
		-b)
			branch="$2"
			shift 2
			;;
		-a)
			author="$2"
			shift 2
			;;
		--range)
			if [[ -n "$range_date1" ]]; then
				echo "main:: --range option can only be used once" >&2
				return 1
			fi
			range_date1="$2"
			shift 2
			# Check if there's a second date argument
			if [[ $# -gt 0 && "$1" != -* ]]; then
				range_date2="$1"
				shift 1
			fi
			;;
		--page-size)
			if [[ -n "$page_size" && "$page_size" != "0" ]]; then
				echo "main:: --page-size option can only be used once" >&2
				return 1
			fi
			page_size="$2"
			shift 2
			;;
		*)
			echo "main:: Unknown option '$1'" >&2
			echo "main:: Use '$(basename "$0") --help' for usage information" >&2
			return 1
			;;
		esac
	done

	# Validate required arguments
	if ! validate_required_args "$repo_path" "$branch" "$author"; then
		return 1
	fi

	# Validate repository path
	if ! validate_repo_path "$repo_path"; then
		return 1
	fi

	# Change to repository directory
	if ! change_to_repo "$repo_path"; then
		return 1
	fi

	# Get repository name
	if ! get_repo_name; then
		popd >/dev/null || return 1
		return 1
	fi

	# Validate page size
	if ! validate_page_size "$page_size"; then
		return 1
	fi

	# Validate dates if --range is used
	if [[ -n "$range_date1" ]]; then
		if ! validate_date "$range_date1"; then
			popd >/dev/null || return 1
			return 1
		fi
	fi
	if [[ -n "$range_date2" ]]; then
		if ! validate_date "$range_date2"; then
			popd >/dev/null || return 1
			return 1
		fi
	fi

	# Validate author exists
	if ! validate_author_exists "$author"; then
		popd >/dev/null || return 1
		return 1
	fi

	# Determine period dates for output filenames
	determine_period_dates "$range_date1" "$range_date2"

	# Get commits
	if ! get_commits "$author" "$range_date1" "$range_date2" "$branch"; then
		popd >/dev/null || return 1
		return 1
	fi

	# Display commit count
	local commit_count
	if [[ -z "$COMMITS" ]]; then
		commit_count=0
	else
		commit_count=$(echo "$COMMITS" | wc -l)
	fi
	echo "main:: Commit count: $commit_count"

	local sanitized_author
	sanitized_author=$(echo "$author" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
	local sanitized_branch
	sanitized_branch=$(tr -c 'a-zA-Z0-9_-' '_' <<<"$branch" | sed 's/_$//')

	# Generate timestamp for this run
	local timestamp
	timestamp=$(date +%Y%m%d_%H%M%S)

	local repo_params="${REPO_NAME}_${sanitized_branch}_${sanitized_author}"
	local output_path="$OUTPUT_DIR/${repo_params}/${timestamp}"

	# Create output directory
	if ! mkdir -p "$output_path" 2>/dev/null; then
		echo "main:: Failed to create output directory: $output_path" >&2
		popd >/dev/null || return 1
		return 1
	fi

	# Process commits
	process_commits "$output_path" "$page_size"

	# Restore original directory
	popd >/dev/null || return 1

	echo "main:: Output written to directory: $output_path"
	return 0
}

# Allow script to be executed directly with arguments, or sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi
