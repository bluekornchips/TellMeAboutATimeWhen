#!/bin/bash

function usage() {
    cat <<EOF
usage: $(basename $0) -p <path> -b <branch> -a <author> [-s <since>]
where:
    -p <path>   : Path to the repository (required)
    -b <branch> : Branch to analyze (required)
    -a <author> : Author of commits (required)
    -s <since>  : Time range for commits (default: 1 week ago)
EOF
}

repo_path=""
branch=""
author=""
since="1 week ago"

while getopts "b:p:s:a:" flag; do
    case "$flag" in
    b) branch="$OPTARG" ;;
    p) repo_path="$OPTARG" ;;
    s) since="$OPTARG" ;;
    a) author="$OPTARG" ;;
    *)
        usage
        exit 1
        ;;
    esac
done

if [[ -z "$repo_path" || -z "$branch" || -z "$author" ]]; then
    usage
    exit 1
fi

if [[ ! -d "$repo_path" ]]; then
    echo "Error: Invalid path: $repo_path"
    exit 1
fi

pushd "$repo_path" >/dev/null || {
    echo "Error: Failed to change directory to $repo_path"
    exit 1
}

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)") || {
    echo "Error: Failed to get repository name"
    popd >/dev/null
    exit 1
}

# Check if author exists in the git log before running the full log command.
if ! git log --author="$author" --max-count=1 >/dev/null 2>&1; then
    echo "Error: Author '$author' not found in the commit history."
    popd >/dev/null
    exit 1
fi

commits=$(git log --author="$author" --pretty=format:"%h" --since="$since" "$branch") || {
    echo "Error: Failed to get commit list"
    popd >/dev/null
    exit 1
}

echo "Commit count: $(wc -l <<<"$commits")"

EVERYTHING_FILE="$HOME/$REPO_NAME.txt"

while read -r commit; do
    cat <<EOF >>"$EVERYTHING_FILE"
=================================
Commit: $commit
=================================
EOF

    git log -p --format="%B" -n 1 "$commit" >>"$EVERYTHING_FILE" || {
        echo "Warning: Failed to get commit details for $commit"
        continue
    }

    git diff-tree --no-commit-id --name-only -r "$commit" >>"$EVERYTHING_FILE" || {
        echo "Warning: Failed to get changed files for $commit"
        continue
    }
done <<<"$commits"

popd >/dev/null

echo "Output written to: $EVERYTHING_FILE"
