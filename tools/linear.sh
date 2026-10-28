#!/usr/bin/env bash
#
# Linear helpers for tell-me-about.sh. Sourced by the orchestrator, not run directly.
# Uses the Linear GraphQL API: https://linear.app/developers/graphql
#

LINEAR_GRAPHQL_DEFAULT_URL="https://api.linear.app/graphql"
LINEAR_VIEWER_QUERY='query { viewer { id } }'
LINEAR_ISSUE_QUERY=$(
	cat <<'EOF'
query Issue($id: String!) {
  issue(id: $id) {
    identifier
    title
    description
    url
    state { name }
    assignee { name }
    comments(first: 50) {
      nodes { body createdAt user { name } }
    }
  }
}
EOF
)

# Validates curl and jq availability for Linear GraphQL calls
#
# Returns:
# - 0 on success
# - 1 on failure
check_linear_dependencies() {
	require_cmd curl check_linear_dependencies || return 1
	require_cmd jq check_linear_dependencies || return 1

	return 0
}

# Posts a GraphQL query to the Linear API
#
# Inputs:
# - $1: GraphQL query string
# - $2: JSON object for GraphQL variables, defaults to {}
#
# Outputs:
# - Response JSON to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
linear_graphql_request() {
	local query="${1:-}"
	local variables_json="${2:-{}}"

	if [[ -z "${query}" ]]; then
		echo "linear_graphql_request:: query is not set" >&2
		return 1
	fi

	if [[ -z "${LINEAR_API_KEY:-}" ]]; then
		echo "linear_graphql_request:: LINEAR_API_KEY is not set" >&2
		return 1
	fi

	if ! echo "${variables_json}" | jq -e . >/dev/null 2>&1; then
		echo "linear_graphql_request:: variables_json is not valid JSON" >&2
		return 1
	fi

	local payload
	if ! payload=$(jq -n --arg query "${query}" --argjson variables "${variables_json}" \
		'{query: $query, variables: $variables}'); then
		echo "linear_graphql_request:: Failed to build GraphQL payload" >&2
		return 1
	fi

	local graphql_url
	graphql_url="${LINEAR_GRAPHQL_URL:-${LINEAR_GRAPHQL_DEFAULT_URL}}"

	local response
	if ! response=$(curl -sS \
		-X POST \
		-H "Authorization: ${LINEAR_API_KEY}" \
		-H "Content-Type: application/json" \
		--data "${payload}" \
		"${graphql_url}" 2>/dev/null); then
		echo "linear_graphql_request:: GraphQL request failed" >&2
		return 1
	fi

	if [[ -z "${response}" ]]; then
		echo "linear_graphql_request:: GraphQL response is empty" >&2
		return 1
	fi

	if ! echo "${response}" | jq -e . >/dev/null 2>&1; then
		echo "linear_graphql_request:: GraphQL response is not valid JSON" >&2
		return 1
	fi

	echo "${response}"

	return 0
}

# Validates Linear API authentication via the viewer query
#
# Returns:
# - 0 on success
# - 1 on failure
validate_linear_auth() {
	if [[ -z "${LINEAR_API_KEY:-}" ]]; then
		cat <<EOF >&2
validate_linear_auth:: LINEAR_API_KEY is not set
validate_linear_auth:: Create a personal API key at https://linear.app/settings/account/security
validate_linear_auth:: Then export LINEAR_API_KEY
EOF
		return 1
	fi

	local response
	if ! response=$(linear_graphql_request "${LINEAR_VIEWER_QUERY}" '{}'); then
		cat <<EOF >&2
validate_linear_auth:: Linear GraphQL authentication failed
validate_linear_auth:: Create a personal API key at https://linear.app/settings/account/security
validate_linear_auth:: Then export LINEAR_API_KEY
EOF
		return 1
	fi

	local viewer_id
	viewer_id=$(echo "${response}" | jq -r '.data.viewer.id // empty')
	if [[ -z "${viewer_id}" ]]; then
		cat <<EOF >&2
validate_linear_auth:: Linear GraphQL authentication failed
validate_linear_auth:: Create a personal API key at https://linear.app/settings/account/security
validate_linear_auth:: Then export LINEAR_API_KEY
EOF
		return 1
	fi

	return 0
}

# Formats a Linear issue GraphQL response as readable text
#
# Inputs:
# - $1: GraphQL response JSON
#
# Outputs:
# - Issue details and comments to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
format_issue_details() {
	local response="${1:-}"

	if [[ -z "${response}" ]]; then
		echo "format_issue_details:: response is not set" >&2
		return 1
	fi

	local formatted
	if ! formatted=$(echo "${response}" | jq -r '
		.data.issue as $i
		| [
				"Issue: \($i.identifier)",
				"Title: \($i.title)",
				"Status: \($i.state.name // "unknown")",
				"Assignee: \($i.assignee.name // "unassigned")",
				"URL: \($i.url)",
				"Description:",
				($i.description // ""),
				""
			]
			+ (
				if ($i.comments.nodes | length) == 0 then
					["Comments:", "(none)"]
				else
					["Comments:"]
						+ (
							$i.comments.nodes
							| map("- \(.user.name // "unknown") (\(.createdAt)): \(.body)")
						)
				end
			)
		| .[]
	'); then
		echo "format_issue_details:: Failed to format issue details" >&2
		return 1
	fi

	echo "${formatted}"

	return 0
}

# Gets issue details for a Linear identifier such as ENG-123
#
# Inputs:
# - $1: issue_id, Linear issue identifier
#
# Outputs:
# - Issue details and comments to stdout
#
# Returns:
# - 0 on success
# - 1 on failure
get_issue_details_for_id() {
	local issue_id="$1"

	if [[ -z "${issue_id}" ]]; then
		echo "get_issue_details_for_id:: issue_id is not set" >&2
		return 1
	fi

	local variables
	if ! variables=$(jq -n --arg id "${issue_id}" '{id: $id}'); then
		echo "get_issue_details_for_id:: Failed to build GraphQL variables for: ${issue_id}" >&2
		return 1
	fi

	local response
	if ! response=$(linear_graphql_request "${LINEAR_ISSUE_QUERY}" "${variables}"); then
		echo "get_issue_details_for_id:: Failed to retrieve issue details for: ${issue_id}" >&2
		return 1
	fi

	local identifier
	identifier=$(echo "${response}" | jq -r '.data.issue.identifier // empty')
	if [[ -z "${identifier}" ]]; then
		echo "get_issue_details_for_id:: Failed to retrieve issue details for: ${issue_id}" >&2
		return 1
	fi

	format_issue_details "${response}" || return 1

	return 0
}

# Writes Linear issue details for a commit to a single file
#
# Inputs:
# - $1: commit hash
# - $2: output file
#
# Side Effects:
# - Writes issue details to the output file when issues are found
# - Does not create an empty file when no issues are found
#
# Returns:
# - 0 on success
# - 1 on failure
write_linear_details() {
	local commit="${1:-}"
	local linear_file="${2:-}"

	if [[ -z "${commit}" || -z "${linear_file}" ]]; then
		echo "write_linear_details:: commit or linear_file is not set" >&2
		return 1
	fi

	local commit_dir
	commit_dir=$(dirname "${linear_file}")
	if [[ ! -d "${commit_dir}" ]]; then
		echo "write_linear_details:: Commit directory does not exist: ${commit_dir}" >&2
		return 1
	fi

	check_linear_dependencies || return 1
	validate_linear_auth || return 1
	write_ticket_details "${commit}" "${linear_file}" get_issue_details_for_id write_linear_details || return 1

	return 0
}

# Reports that this library must be sourced, not executed
#
# Returns:
# - 1 always
main() {
	echo "linear.sh:: source this file from tell-me-about.sh; do not run it directly" >&2
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -eo pipefail
	umask 077
	main "$@"
	exit $?
fi
