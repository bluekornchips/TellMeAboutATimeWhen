#!/bin/bash

HISTORY_FILE="github_history.json" # File to store the history

# Function to save history
save_history() {
    local repo_name="$1"
    local username="$2"
    local data_file="$3"
    local data=$(cat "$data_file" | jq -c .)
    # Create a JSON object with the history data
    local history_json=$(
        jq -n \
            --arg repo_name "$repo_name" \
            --arg username "$username" \
            --argjson data "$data" \
            '{
            repo: $repo_name,
            user: $username,
            data: $data
        }'
    )

    # Write the JSON object to the history file
    echo "$history_json" >"$HISTORY_FILE"
}

# Function to retrieve history
retrieve_history() {
    local repo_name="$1"
    local username="$2"
    local start_time="$3"
    local end_time="$4"
    local results_file="$5"

    # Check if the history file exists
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "$HISTORY_FILE not found"
        return 1 # History file not found
    fi

    # Read the history from the file
    local history_json=$(cat "$HISTORY_FILE")

    # Check if the history matches the given parameters
    if [[ "$(echo "$history_json" | jq -r '.repo')" == "$repo_name" ]] &&
        [[ "$(echo "$history_json" | jq -r '.user')" == "$username" ]]; then
        # Return the data if the history matches
        echo "$history_json" | jq -r '.data' >"$results_file"
        return 0
    else
        return 1 # History does not match
    fi
}
