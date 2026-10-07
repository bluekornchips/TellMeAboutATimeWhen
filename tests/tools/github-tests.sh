#!/usr/bin/env bats
#
# Test suite for tools/github.sh
#

setup_file() {
	# shellcheck disable=SC1090
	source "$(git rev-parse --show-toplevel)/tests/helpers/bats-setup.sh"
	bats_resolve_paths "tools/github.sh" || return 1
	if [[ ! -f "${HELPER}" ]]; then
		echo "setup:: Helper not found: ${HELPER}" >&2
		return 1
	fi

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
	bats_source_libs "${SCRIPT}"
	export REPO_PATH
	unset GITHUB_USER

	return 0
}

# JSON payloads the gh mocks return. Each test wires these into its own gh
# stub so the dispatch stays visible in the test body.

# gh api response linking a commit to PR 123
fixture_commit_prs() {
	printf '%s\n' '[{"number": 123}]'
}

# gh pr view response, minimal shape
fixture_pr_view() {
	printf '%s\n' '{"number":123,"title":"Test PR"}'
}

# gh pr view response, full shape for a merged PR
fixture_pr_view_merged() {
	printf '%s\n' '{"number":123,"title":"Test PR","url":"https://github.com/owner/repo/pull/123","state":"MERGED","mergedAt":"2025-01-20T10:00:00Z","createdAt":"2025-01-19T10:00:00Z","body":"Test PR body"}'
}

# gh pr list response with one PR merged by testuser and one merged by another
fixture_pr_list_mixed_mergers() {
	jq -nc '[
		{number:10,title:"Mine",url:"https://example/10",state:"MERGED",mergedAt:"2026-09-02T00:00:00Z",mergedBy:{login:"testuser"}},
		{number:11,title:"Theirs",url:"https://example/11",state:"MERGED",mergedAt:"2026-09-03T00:00:00Z",mergedBy:{login:"someone-else"}}
	]'
}

# gh pr list response with a single PR numbered $1 merged by testuser
fixture_pr_list_merged() {
	jq -nc --argjson number "$1" \
		'[{number:$number,title:"ok",url:"https://example/1",state:"MERGED",mergedAt:"2026-09-02T00:00:00Z",mergedBy:{login:"testuser"}}]'
}

# gh search prs response with a single PR numbered $1 titled $2
fixture_search_pr() {
	jq -nc --argjson number "$1" --arg title "$2" \
		'[{number:$number,title:$title,url:"https://example/1",state:"open",author:"other",createdAt:"2026-09-01T00:00:00Z",updatedAt:"2026-09-03T00:00:00Z",body:"b",closedAt:null}]'
}

# gh search prs response with $1 PRs, used to hit the result limit
fixture_search_prs_many() {
	jq -nc --argjson count "$1" \
		'[range($count) | {number:.,title:"t",url:"u",state:"open",closedAt:null}]'
}

# check_github_dependencies
@test "check_github_dependencies:: fails when jq is not installed" {
	command() {
		if [[ "$1" == "-v" ]]; then
			if [[ "$2" == "jq" ]]; then
				return 1
			elif [[ "$2" == "gh" ]]; then
				return 0
			fi
		fi
		command "$@"
	}

	gh() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "jq is required"

	unset -f command gh
}

@test "check_github_dependencies:: fails when gh is not installed" {
	command() {
		if [[ "$1" == "-v" ]]; then
			if [[ "$2" == "jq" ]]; then
				return 0
			elif [[ "$2" == "gh" ]]; then
				return 1
			fi
		fi
		command "$@"
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "GitHub CLI.*not installed"

	unset -f command jq
}

@test "check_github_dependencies:: succeeds when dependencies are available" {
	AUTHOR="testuser"

	gh() {
		return 0
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 0 ]]

	unset -f gh jq
}

@test "check_github_dependencies:: fails when not authenticated" {
	gh() {
		[[ "$1 $2" == "auth status" ]] && return 1
		return 0
	}

	jq() {
		return 0
	}

	run check_github_dependencies
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "GitHub CLI is not authenticated"

	unset -f gh jq
}

# needs_pr_refresh
@test "needs_pr_refresh:: true when missing or empty array" {
	local prs_file="${TEST_DIR}/pr.json"

	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 0 ]]

	echo '[]' >"${prs_file}"
	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 0 ]]

	echo '[{"number":1}]' >"${prs_file}"
	run needs_pr_refresh "${prs_file}"
	[[ "$status" -eq 1 ]]
}

# write_pr_details
@test "write_pr_details:: fails when commit is not set" {
	local prs_file="${TEST_DIR}/test_prs.json"
	touch "$prs_file"

	run write_pr_details "" "$prs_file"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: fails when prs_file is not set" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	run write_pr_details "abc123" ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "commit or pr_file is not set"
}

@test "write_pr_details:: writes PR details to file" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local prs_file="${TEST_DIR}/test_prs.json"
	local commit
	commit=$(git rev-parse HEAD)
	touch "$prs_file"
	AUTHOR="testuser"

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"api "*) fixture_commit_prs ;;
		"pr view") fixture_pr_view ;;
		esac
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		elif [[ "$1" == "-s" ]]; then
			cat >/dev/null
			echo '[{"number":123,"title":"Test PR"}]'
		fi
		return 0
	}

	run write_pr_details "$commit" "$prs_file"
	[[ "$status" -eq 0 ]]
	[[ -f "$prs_file" ]]

	unset -f gh jq
}

@test "get_pr_details:: fails when commit hash cannot be resolved" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	git() {
		if [[ "$1" == "rev-parse" ]]; then
			return 1
		fi
		command git "$@"
	}

	run get_pr_details "test123"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to resolve commit hash"

	unset -f git
}

@test "get_pr_details:: fails when git remote URL cannot be retrieved" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote remove origin 2>/dev/null || true

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Failed to get git remote URL"
}

@test "get_pr_details:: uses REPO_PATH when set" {
	create_worktree_repo "${TEST_DIR}/repo1"
	create_worktree_repo "${TEST_DIR}/repo2"
	cd "${TEST_DIR}/repo1"
	git remote add origin "https://github.com/owner1/repo1.git" 2>/dev/null || git remote set-url origin "https://github.com/owner1/repo1.git"
	cd "${TEST_DIR}/repo2"
	git remote add origin "https://github.com/owner2/repo2.git" 2>/dev/null || git remote set-url origin "https://github.com/owner2/repo2.git"

	local commit
	commit=$(git -C "${TEST_DIR}/repo2" rev-parse HEAD)
	REPO_PATH="${TEST_DIR}/repo2"

	gh() {
		case "$1 $2" in
		"api "*) fixture_commit_prs ;;
		"pr view") fixture_pr_view ;;
		esac
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		fi
		return 0
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'

	unset -f gh jq
}

@test "get_pr_details:: fails with unsupported remote URL format" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)
	REPO_PATH=""

	git remote add origin "unsupported://example.com/repo.git" 2>/dev/null || git remote set-url origin "unsupported://example.com/repo.git"

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -qE "resolve_remote_owner_repo:: Unsupported git remote URL format"
}

@test "get_pr_details:: returns empty when no PRs found" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	gh() {
		case "$1 $2" in
		"api "*) echo "[]" ;;
		esac
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 1 ]]

	unset -f gh
}

@test "get_pr_details:: outputs PR details when PRs found" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"

	local commit
	commit=$(git rev-parse HEAD)

	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	gh() {
		case "$1 $2" in
		"api "*) fixture_commit_prs ;;
		"pr view") fixture_pr_view_merged ;;
		esac
	}

	jq() {
		if [[ "$1" == "-r" && "$2" == ".[].number" ]]; then
			echo "123"
		fi
		return 0
	}

	run get_pr_details "$commit"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q '"number":123'
	echo "$output" | grep -q '"title":"Test PR"'
	echo "$output" | grep -q '"state":"MERGED"'

	unset -f gh jq
}

# set_github_user
@test "set_github_user:: uses username-shaped AUTHOR" {
	AUTHOR="testuser"
	GITHUB_USER=""

	set_github_user
	[[ "${GITHUB_USER}" == "testuser" ]]
}

@test "set_github_user:: keeps an explicit GITHUB_USER" {
	AUTHOR="Author One"
	GITHUB_USER="octocat"

	set_github_user
	[[ "${GITHUB_USER}" == "octocat" ]]
}

@test "set_github_user:: fails for a display-name AUTHOR without --github-user" {
	AUTHOR="Author One"
	GITHUB_USER=""

	run set_github_user
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q -- "--github-user is required"
}

@test "set_github_user:: fails when GitHub username is empty" {
	AUTHOR=""
	GITHUB_USER=""

	run set_github_user
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q -- "--github-user is required"
}

# search_prs_by_involvement
@test "search_prs_by_involvement:: lists merged PRs and keeps only those the login merged" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	local captured="${TEST_DIR}/captured-merged.txt"

	gh() {
		case "$1 $2" in
		"pr list")
			printf '%s\n' "$*" >"${captured}"
			fixture_pr_list_mixed_mergers
			;;
		*) return 1 ;;
		esac
	}

	run search_prs_by_involvement "merged" "testuser" "owner/repo"
	[[ "$status" -eq 0 ]]
	grep -q -- "--state merged" "${captured}"
	grep -q -- "--search merged:2026-09-01..2026-09-14" "${captured}"
	grep -q "mergedBy" "${captured}"
	echo "$output" | grep -qE '"involvement"[[:space:]]*:[[:space:]]*"merged"'
	echo "$output" | grep -qE '"number"[[:space:]]*:[[:space:]]*10'
	echo "$output" | grep -qvE '"number"[[:space:]]*:[[:space:]]*11'

	unset -f gh
}

@test "search_prs_by_involvement:: warns when the result limit is hit" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"

	gh() {
		case "$1 $2" in
		"search prs") fixture_search_prs_many 100 ;;
		*) return 1 ;;
		esac
	}

	run search_prs_by_involvement "reviewed" "testuser" "owner/repo"
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q "hit the 100 result limit"

	unset -f gh
}

@test "search_prs_by_involvement:: reports the underlying failure reason" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"

	gh() {
		echo "HTTP 403: You have exceeded a secondary rate limit" >&2
		return 1
	}

	run search_prs_by_involvement "reviewed" "testuser" "owner/repo"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Failed to fetch reviewed PRs"
	echo "$output" | grep -q "secondary rate limit"

	unset -f gh
}

@test "search_prs_by_involvement:: builds reviewed search flags" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	local captured="${TEST_DIR}/captured-reviewed.txt"

	gh() {
		case "$1 $2" in
		"search prs")
			printf '%s\n' "$*" >"${captured}"
			fixture_search_pr 11 "Reviewed"
			;;
		*) return 1 ;;
		esac
	}

	run search_prs_by_involvement "reviewed" "testuser" "owner/repo"
	[[ "$status" -eq 0 ]]
	grep -q -- "--reviewed-by" "${captured}"
	grep -q -- "--updated" "${captured}"
	echo "$output" | grep -qE '"involvement"[[:space:]]*:[[:space:]]*"reviewed"'

	unset -f gh
}

@test "search_prs_by_involvement:: builds commented search flags" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	local captured="${TEST_DIR}/captured-commented.txt"

	gh() {
		case "$1 $2" in
		"search prs")
			printf '%s\n' "$*" >"${captured}"
			fixture_search_pr 12 "Commented"
			;;
		*) return 1 ;;
		esac
	}

	run search_prs_by_involvement "commented" "testuser" "owner/repo"
	[[ "$status" -eq 0 ]]
	grep -q -- "--commenter" "${captured}"
	echo "$output" | grep -qE '"involvement"[[:space:]]*:[[:space:]]*"commented"'

	unset -f gh
}

@test "search_prs_by_involvement:: rejects unknown role" {
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"

	run search_prs_by_involvement "owned" "testuser" "owner/repo"
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "Unknown role"
}

# write_involvement_prs
@test "write_involvement_prs:: writes three indexes" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list") fixture_pr_list_merged 1 ;;
		"search prs")
			if [[ "$*" == *"--commenter"* ]]; then
				fixture_search_pr 1 "commented"
			else
				fixture_search_pr 1 "reviewed"
			fi
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	[[ -f "${out_root}/prs/merged/index.json" ]]
	[[ -f "${out_root}/prs/reviewed/index.json" ]]
	[[ -f "${out_root}/prs/commented/index.json" ]]
	[[ -f "${out_root}/prs/.signature" ]]
	grep -qE '"involvement"[[:space:]]*:[[:space:]]*"merged"' "${out_root}/prs/merged/index.json"
	grep -qE '"involvement"[[:space:]]*:[[:space:]]*"reviewed"' "${out_root}/prs/reviewed/index.json"
	grep -qE '"involvement"[[:space:]]*:[[:space:]]*"commented"' "${out_root}/prs/commented/index.json"

	unset -f gh
}

@test "write_involvement_prs:: soft-fails one role and still writes indexes" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out-soft"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list") fixture_pr_list_merged 2 ;;
		"search prs")
			if [[ "$*" == *"--reviewed-by"* ]]; then
				echo "HTTP 403: rate limited" >&2
				return 1
			fi
			fixture_search_pr 3 "commented"
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	[[ -f "${out_root}/prs/reviewed/index.json" ]]
	[[ ! -f "${out_root}/prs/.signature" ]]
	grep -q '\[\]' "${out_root}/prs/reviewed/index.json"
	grep -qE '"number"[[:space:]]*:[[:space:]]*2' "${out_root}/prs/merged/index.json"
	echo "$output" | grep -q "Writing empty reviewed index"

	unset -f gh
}

@test "write_involvement_prs:: fails when output_root is not set" {
	run write_involvement_prs ""
	[[ "$status" -eq 1 ]]
	echo "$output" | grep -q "output_root is not set"
}

@test "write_involvement_prs:: reuses indexes when the signature matches" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="Author One"
	GITHUB_USER="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out-cache"
	local calls="${TEST_DIR}/gh-calls"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list")
			printf 'called\n' >>"${calls}"
			fixture_pr_list_merged 1
			;;
		"search prs")
			printf 'called\n' >>"${calls}"
			if [[ "$*" == *"--commenter"* ]]; then
				fixture_search_pr 1 "commented"
			else
				fixture_search_pr 1 "reviewed"
			fi
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	[[ -f "${out_root}/prs/.signature" ]]
	local first_calls
	first_calls=$(wc -l <"${calls}")
	[[ "${first_calls}" -gt 0 ]]

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	local second_calls
	second_calls=$(wc -l <"${calls}")
	[[ "${first_calls}" -eq "${second_calls}" ]]

	unset -f gh
}

@test "write_involvement_prs:: caches empty indexes when the signature matches" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="testuser"
	GITHUB_USER="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out-empty"
	local calls="${TEST_DIR}/empty-calls"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list" | "search prs")
			printf 'called\n' >>"${calls}"
			printf '%s\n' '[]'
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	[[ -f "${out_root}/prs/.signature" ]]
	grep -q '\[\]' "${out_root}/prs/merged/index.json"

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	local call_count
	call_count=$(wc -l <"${calls}")
	[[ "${call_count}" -eq 3 ]]

	unset -f gh
}

@test "write_involvement_prs:: refreshes indexes when the range changes" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="testuser"
	GITHUB_USER="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out-refresh"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list") fixture_pr_list_merged 1 ;;
		"search prs")
			if [[ "$*" == *"--commenter"* ]]; then
				fixture_search_pr 1 "commented"
			else
				fixture_search_pr 1 "reviewed"
			fi
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	grep -q '2026-09-14' "${out_root}/prs/.signature"

	PERIOD_END="2026-09-30"
	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list") fixture_pr_list_merged 9 ;;
		"search prs")
			if [[ "$*" == *"--commenter"* ]]; then
				fixture_search_pr 9 "commented"
			else
				fixture_search_pr 8 "reviewed"
			fi
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	grep -q '2026-09-30' "${out_root}/prs/.signature"
	grep -qE '"number"[[:space:]]*:[[:space:]]*9' "${out_root}/prs/merged/index.json"

	unset -f gh
}

@test "write_involvement_prs:: does not stamp a signature when a role fetch fails" {
	create_worktree_repo "${TEST_DIR}/repo"
	cd "${TEST_DIR}/repo"
	git remote add origin "https://github.com/owner/repo.git" 2>/dev/null || git remote set-url origin "https://github.com/owner/repo.git"

	AUTHOR="testuser"
	GITHUB_USER="testuser"
	PERIOD_START="2026-09-01"
	PERIOD_END="2026-09-14"
	REPO_PATH="${TEST_DIR}/repo"
	local out_root="${TEST_DIR}/out-partial"

	gh() {
		case "$1 $2" in
		"auth status") return 0 ;;
		"pr list") fixture_pr_list_merged 2 ;;
		"search prs")
			if [[ "$*" == *"--reviewed-by"* ]]; then
				echo "HTTP 403: rate limited" >&2
				return 1
			fi
			fixture_search_pr 3 "commented"
			;;
		esac
	}

	run write_involvement_prs "${out_root}"
	[[ "$status" -eq 0 ]]
	[[ ! -f "${out_root}/prs/.signature" ]]
	grep -q '\[\]' "${out_root}/prs/reviewed/index.json"

	unset -f gh
}

@test "integration:: rejects direct script execution" {
	# shellcheck disable=SC1090
	source "${GIT_ROOT}/tests/helpers/bats-setup.sh"
	run assert_rejects_direct_execution "$SCRIPT"
	[[ "$status" -eq 0 ]]
}
