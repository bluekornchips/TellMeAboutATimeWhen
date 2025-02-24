#!/bin/bash

# Default values
OWNER=""
REPO=""
USERNAME=""
DAYS_AGO=6

# Usage function
usage() {
    cat <<EOF
Usage: $0 -o <owner> -r <repo> -u <username> [-d <days_ago>]
  -o <owner>    GitHub repository owner (required)
  -r <repo>     GitHub repository name (required)
  -u <username> GitHub username (required)
  -d <days_ago> Number of days to go back (optional, default: 5)
EOF
    exit 1
}

# Parse command-line arguments
while getopts "o:r:u:d:" opt; do
    case "$opt" in
    o)
        OWNER="$OPTARG"
        ;;
    r)
        REPO="$OPTARG"
        ;;
    u)
        USERNAME="$OPTARG"
        ;;
    d)
        DAYS_AGO="$OPTARG"
        ;;
    \?)
        usage
        ;; # Invalid option
    esac
done

# Check for required arguments
if [[ -z "$OWNER" || -z "$REPO" || -z "$USERNAME" ]]; then
    usage
fi

if ! [[ "$DAYS_AGO" =~ ^[0-9]+$ ]]; then
    echo "Error: Days ago must be a number."
    usage
fi

GITHUB_TOKEN="${GITHUB_TOKEN:-}"

check_read_access() {
    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo "Error: GitHub personal access token (GITHUB_TOKEN) not set."
        return 1
    fi

    local API_URL="https://api.github.com/repos/$OWNER/$REPO"
    local RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API_URL")

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to connect to GitHub API."
        return 1
    fi

    if echo "$RESPONSE" | grep -q '"message": "Not Found"' || echo "$RESPONSE" | grep -q '"message": "Requires authentication"'; then
        echo "Error: Read access to repository '$OWNER/$REPO' denied or repository not found."
        return 1
    fi

    echo "Read access to repository '$OWNER/$REPO' granted."
    return 0
}

if ! check_read_access; then
    exit 1
fi

echo "Repository: $OWNER/$REPO"
echo "Username: $USERNAME"

END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u --date="${DAYS_AGO} days ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "Time frame: $START_TIME to $END_TIME"

source history_manager.sh

CACHED_DATA_FILE=$(mktemp)
retrieve_history "$OWNER" "$USERNAME" "$START_TIME" "$END_TIME" "$CACHED_DATA_FILE"

echo "Number of existing commits: $(jq '. | length' "$CACHED_DATA_FILE")"

# Search the CACHE_DATA_FILE for commits within the specified time frame
commits_in_time_frame="[]"
for commit in $(jq -c '.[] | {date:.commit.author.date, sha:.sha}' "$CACHED_DATA_FILE"); do
    sha=$(echo "$commit" | jq -r '{date:.date, sha:.sha}' | jq -r '.sha')
    date=$(echo "$commit" | jq -r '{date:.date, sha:.sha}' | jq -r '.date')
    if [[ "$date" > "$START_TIME" && "$date" < "$END_TIME" ]]; then
        commits_in_time_frame+="$sha "
    fi
done

# If either the input START_TIME and END_TIME are outside of the cached data, or the cached data is empty, fetch the data from GitHub
fetch_commits=false

time_ranges_to_fetch="[]"
if [[ "$(jq '. | length' "$CACHED_DATA_FILE")" -lt 1 ]]; then
    time_ranges_to_fetch=$(
        jq -n \
            --arg start_time "$START_TIME" \
            --arg end_time "$END_TIME" \
            '[
            {
                start_time: $start_time,
                end_time: $end_time
            }
        ]'
    )
    fetch_commits=true
else
    MOST_RECENT_STORED_COMMIT_DATE=$(jq -r '.[-1].commit.author.date' "$CACHED_DATA_FILE")
    OLDEST_STORED_COMMIT_DATE=$(jq -r '.[0].commit.author.date' "$CACHED_DATA_FILE")

    if [[ "$START_TIME" < "$OLDEST_STORED_COMMIT_DATE" ]]; then
        cat <<EOF
Oldest cached commit date: $OLDEST_STORED_COMMIT_DATE
Requested commit start   : $START_TIME

EOF
        fetch_commits=true

        # Create a new time range to fetch and then add it to the existing time ranges
        # The range is between the new start time and the oldest stored commit date
        new_time_range=$(
            jq -n \
                --arg start_time "$START_TIME" \
                --arg end_time "$OLDEST_STORED_COMMIT_DATE" \
                '{
                    start_time: $start_time,
                    end_time: $end_time
                }'
        )

        time_ranges_to_fetch=$(jq --argjson new_time_range "$new_time_range" '. + [$new_time_range]' <<<"$time_ranges_to_fetch")
    fi

    if [[ "$END_TIME" > "$MOST_RECENT_STORED_COMMIT_DATE" ]]; then
        cat <<EOF
Newest cached commit date: $MOST_RECENT_STORED_COMMIT_DATE
Requested commit end     : $END_TIME

EOF

        # Create a new time range to fetch and then add it to the existing time ranges
        # The range is between the most recent stored commit date and the new end time
        new_time_range=$(
            jq -n \
                --arg start_time "$MOST_RECENT_STORED_COMMIT_DATE" \
                --arg end_time "$END_TIME" \
                '{
                    start_time: $start_time,
                    end_time: $end_time
                }'
        )

        time_ranges_to_fetch=$(jq --argjson new_time_range "$new_time_range" '. + [$new_time_range]' <<<"$time_ranges_to_fetch")
        fetch_commits=true
    fi
fi

if [[ "$fetch_commits" == true ]]; then

    echo "Fetching commits from GitHub..."
    cat <<EOF
Time ranges to fetch:
$(jq '.' <<<"$time_ranges_to_fetch")
EOF

    retrieved_data_file=$(mktemp)
    for fetch_ranges in $(jq -c '.[]' <<<"$time_ranges_to_fetch"); do
        start_time=$(echo "$fetch_ranges" | jq -r '.start_time')
        end_time=$(echo "$fetch_ranges" | jq -r '.end_time')

        echo "Fetching commits between $start_time and $end_time"

        API_COMMITS_URL="https://api.github.com/repos/$OWNER/$REPO/commits?author=$USERNAME&since=$start_time&until=$end_time"

        RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API_COMMITS_URL")

        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to connect to GitHub API."
            exit 1
        fi
        echo "$RESPONSE" | jq -r '.[]' >>"$retrieved_data_file"
    done

    combined_data_file=$(mktemp)

    if [[ ! -f "$CACHED_DATA_FILE" ]]; then
        echo "No cached data found. Using retrieved data."
        cp "$retrieved_data_file" "$combined_data_file"
    else
        echo "Combining cached and retrieved data."
        if [[ -s "$retrieved_data_file" ]]; then # Check if $retrieved_data_file is not empty
            jq -s '. +.' "$CACHED_DATA_FILE" "$retrieved_data_file" >"$combined_data_file"
        else
            echo "No new data retrieved. Using cached data."
            cp "$CACHED_DATA_FILE" "$combined_data_file"
        fi
    fi

    # # Save the combined data to the history file
    # save_history "$OWNER" "$USERNAME" "$combined_data_file"
fi
