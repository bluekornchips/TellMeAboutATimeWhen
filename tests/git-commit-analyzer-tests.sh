#!/usr/bin/env bats
#
# Test suite for git-commit-analyzer.sh
#

setup_file() {
	GIT_ROOT="$(git rev-parse --show-toplevel || echo "")"
	if [[ -z "$GIT_ROOT" ]]; then
		echo "Failed to get git root" >&2
		exit 1
	fi

	SCRIPT="$GIT_ROOT/git-commit-analyzer.sh"
	if [[ ! -f "$SCRIPT" ]]; then
		echo "Script not found: $SCRIPT" >&2
		exit 1
	fi

	export GIT_ROOT
	export SCRIPT

	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	export TEST_DIR

	return 0
}

teardown() {
	[[ -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	return 0
}

# Creates a test git repository with multiple commits and authors for testing
create_test_repo() {
	local repo_dir="$1"

	cd "$repo_dir" || return 1

	git init >/dev/null 2>&1
	git config user.name "Test User"
	git config user.email "test@example.com"

	echo "test file" >test.txt
	git add test.txt
	git commit -m "Initial commit" >/dev/null 2>&1

	# Create commits with different authors to test author filtering
	echo "change by author1" >>test.txt
	git add test.txt
	GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
		git commit --author="Author One <author1@example.com>" -m "Commit by author1" >/dev/null 2>&1

	echo "change by author2" >>test.txt
	git add test.txt
	GIT_COMMITTER_NAME="Author Two" GIT_COMMITTER_EMAIL="author2@example.com" \
		git commit --author="Author Two <author2@example.com>" -m "Commit by author2" >/dev/null 2>&1

	# Create test-branch for branch testing
	git checkout -b test-branch >/dev/null 2>&1
	echo "branch change" >>test.txt
	git add test.txt
	git commit -m "Branch commit" >/dev/null 2>&1

	git checkout master >/dev/null 2>&1

	return 0
}

########################################################
# Unit Tests
########################################################

@test "unit:: shows help correctly" {
	run "$SCRIPT" --help
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Usage:"
	echo "$output" | grep -q "Options:"
	echo "$output" | grep -q "\\-\\-range"
}

@test "unit:: fails with unknown option" {
	run "$SCRIPT" --unknown-option
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Unknown option"
}

@test "unit:: fails with missing required arguments" {
	run "$SCRIPT"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Missing required arguments"
}

@test "unit:: fails with invalid repository path" {
	run "$SCRIPT" -p "/nonexistent/path" -b "master" -a "test@example.com"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Invalid repository path"
}

@test "unit:: fails when using --range option twice" {
	run "$SCRIPT" -p "/tmp" -b "master" -a "test@example.com" --range "2025-01-01" --range "2025-06-01"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "\\-\\-range option can only be used once"
}

@test "unit:: fails with invalid date format in --range" {
	run "$SCRIPT" -p "/tmp" -b "master" -a "test@example.com" --range "invalid-date"
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "Invalid date format"
}

########################################################
# Integration Tests
########################################################

@test "integration:: basic commit analysis works" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count:"
	echo "$output" | grep -q "Output written to directory:"

	# Verify output directory and page file created
	local repo_name=$(basename "$TEST_DIR")
	local base_dir="$HOME/tellmeaboutatimewhen/${repo_name}_master_author_one"
	[[ -d "$base_dir" ]]

	# Find timestamp directory
	mapfile -t timestamp_dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	[[ ${#timestamp_dirs[@]} -eq 1 ]]
	local output_dir="${timestamp_dirs[0]}"
	[[ -d "$output_dir" ]]

	# Find page file with pattern page_N_hash_hash.txt
	mapfile -t page_files < <(find "$output_dir" -name "page_*.txt" -type f 2>/dev/null)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]
	grep -q "Commit by author1" "${page_files[0]}"

	rm -rf "$base_dir"
}

@test "integration:: handles time range parameter" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "1 week ago"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count:"
	echo "$output" | grep -q "Output written to directory:"
}

@test "integration:: handles different branch" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "test-branch" -a "Test User"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count:"
	echo "$output" | grep -q "Output written to directory:"
}

@test "integration:: handles author not found" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "NonExistent Author"

	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q "not found in the commit history"
}

@test "integration:: output includes commit details and diffs" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One"

	[[ "$status" -eq 0 ]]

	local repo_name=$(basename "$TEST_DIR")
	local base_dir="$HOME/tellmeaboutatimewhen/${repo_name}_master_author_one"
	[[ -d "$base_dir" ]]

	# Find timestamp directory
	mapfile -t timestamp_dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	[[ ${#timestamp_dirs[@]} -eq 1 ]]
	local output_dir="${timestamp_dirs[0]}"
	[[ -d "$output_dir" ]]

	mapfile -t page_files < <(find "$output_dir" -name "page_*.txt" -type f 2>/dev/null)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]

	grep -q "Commit by author1" "${page_files[0]}"
	grep -q "Commit by author1" "${page_files[0]}"

	rm -rf "$base_dir"
}

@test "integration:: --range flag works with date range" {
	create_test_repo "$TEST_DIR"

	# Wide date range should include all commits
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "2020-01-01" "2030-12-31"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count:"
	echo "$output" | grep -q "Output written to directory:"

	local repo_name=$(basename "$TEST_DIR")
	local base_dir="$HOME/tellmeaboutatimewhen/${repo_name}_master_author_one"
	[[ -d "$base_dir" ]]

	# Find timestamp directory
	mapfile -t timestamp_dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	[[ ${#timestamp_dirs[@]} -eq 1 ]]
	local output_dir="${timestamp_dirs[0]}"
	[[ -d "$output_dir" ]]

	mapfile -t page_files < <(find "$output_dir" -name "page_*.txt" -type f 2>/dev/null)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]
	grep -q "Commit by author1" "${page_files[0]}"

	rm -rf "$base_dir"
}

@test "integration:: --range flag works with single date" {
	create_test_repo "$TEST_DIR"

	# Single date should be treated as --since, from that date to now
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "1 week ago"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count:"
	echo "$output" | grep -q "Output written to directory:"
}

@test "integration:: --range flag filters commits correctly" {
	create_test_repo "$TEST_DIR"

	# Narrow date range from 2000-2001 should exclude all test commits
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --range "2000-01-01" "2001-12-31"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Commit count: 0"
	echo "$output" | grep -q "Output written to directory:"
}

@test "integration:: --page-size defaults to 0 (unlimited page)" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One"

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Output written to directory:"

	# When page_size defaults to 0, all commits go to one page file
	local repo_name=$(basename "$TEST_DIR")
	local base_dir="$HOME/tellmeaboutatimewhen/${repo_name}_master_author_one"
	[[ -d "$base_dir" ]]

	# Find timestamp directory
	mapfile -t timestamp_dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	[[ ${#timestamp_dirs[@]} -eq 1 ]]
	local output_dir="${timestamp_dirs[0]}"
	[[ -d "$output_dir" ]]

	mapfile -t page_files < <(find "$output_dir" -name "page_*.txt" -type f 2>/dev/null)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]
	rm -rf "$base_dir"
}

@test "integration:: --page-size 0 creates unlimited page (all commits in single file)" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --page-size 0

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Output written to directory:"

	# Explicit page_size=0 should write all commits to one page file
	local repo_name=$(basename "$TEST_DIR")
	local base_dir="$HOME/tellmeaboutatimewhen/${repo_name}_master_author_one"
	[[ -d "$base_dir" ]]

	# Find timestamp directory
	mapfile -t timestamp_dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	[[ ${#timestamp_dirs[@]} -eq 1 ]]
	local output_dir="${timestamp_dirs[0]}"
	[[ -d "$output_dir" ]]

	mapfile -t page_files < <(find "$output_dir" -name "page_*.txt" -type f 2>/dev/null)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]
	rm -rf "$base_dir"
}

@test "integration:: --page-size creates paginated output" {
	create_test_repo "$TEST_DIR"

	# Author One has 1 commit, page_size=2 should create only one page file
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --page-size 2

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Output written to directory:"

	local output_dir
	output_dir=$(echo "$output" | grep "Output written to directory:" | sed 's/.*directory: //')
	[[ -d "$output_dir" ]]

	# Check that page file exists with new naming pattern page_N_hash_hash.txt
	local page_files=("$output_dir"/page_1_*.txt)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]

	# Verify no second page file exists
	[[ $(find "$output_dir" -name "page_2_*.txt" -type f 2>/dev/null | wc -l) -eq 0 ]]

	local commit_count_p1=$(grep -c "Commit by author1" "${page_files[0]}")
	[[ $commit_count_p1 -eq 1 ]]

	rm -rf "$output_dir"
}

@test "integration:: branch name sanitization" {
	create_test_repo "$TEST_DIR"

	# Create branch with special characters to test sanitization
	(
		cd "$TEST_DIR"
		git checkout -b "feature/my-feature" >/dev/null 2>&1
		echo "feature commit" >>test.txt
		git add test.txt
		GIT_COMMITTER_NAME="Author One" GIT_COMMITTER_EMAIL="author1@example.com" \
			git commit --author="Author One <author1@example.com>" -m "Feature commit" >/dev/null 2>&1
	)

	run "$SCRIPT" -p "$TEST_DIR" -b "feature/my-feature" -a "Author One" --page-size 1

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Output written to directory:"

	# Verify slashes in branch name are sanitized to underscores in directory name
	local output_dir
	output_dir=$(echo "$output" | grep "Output written to directory:" | sed 's/.*directory: //')
	echo "$output_dir" | grep -q "feature_my-feature"

	rm -rf "$output_dir"
}

@test "integration:: paginated output directory naming" {
	create_test_repo "$TEST_DIR"

	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Author One" --page-size 3

	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "Output written to directory:"

	# Verify directory follows format: {repo}_{branch}_{author}/{timestamp}
	local output_dir
	output_dir=$(echo "$output" | grep "Output written to directory:" | sed 's/.*directory: //')
	local dirname=$(basename "$(dirname "$output_dir")")

	echo "$dirname" | grep -q "_master_"
	echo "$dirname" | grep -q "_author_one$"

	rm -rf "$output_dir"
}

@test "integration:: page file naming and content" {
	create_test_repo "$TEST_DIR"

	# Test User has 1 commit, page_size=1 should create exactly one page file
	run "$SCRIPT" -p "$TEST_DIR" -b "master" -a "Test User" --page-size 1

	[[ "$status" -eq 0 ]]

	local output_dir
	output_dir=$(echo "$output" | grep "Output written to directory:" | sed 's/.*directory: //')
	[[ -d "$output_dir" ]]

	# Check that page file exists with new naming pattern page_N_hash_hash.txt
	local page_files=("$output_dir"/page_1_*.txt)
	[[ ${#page_files[@]} -eq 1 ]]
	[[ -f "${page_files[0]}" ]]

	# Verify no second page file exists
	[[ $(find "$output_dir" -name "page_2_*.txt" -type f 2>/dev/null | wc -l) -eq 0 ]]

	local commit_count=$(grep -c "Initial commit" "${page_files[0]}")
	[[ $commit_count -eq 1 ]]

	rm -rf "$output_dir"
}
