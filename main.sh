#!/bin/bash

function usage() {
    cat <<EOF
usage: $(basename $0) [-p <path>] [-b <branch>] [-s <since>] [-a <author>]
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
    case $flag in
    'b') branch="$OPTARG" ;;
    'p') repo_path="$OPTARG" ;;
    's') since="$OPTARG" ;;
    'a') author="$OPTARG" ;;
    *) usage && exit 1 ;;
    esac
done

[[ -z "$repo_path" ]] && usage && exit 1
[[ ! -d "$repo_path" ]] && echo "Invalid path: $repo_path" && exit 1
pushd "$repo_path" >/dev/null || {
    echo "Failed to change directory to $repo_path"
    exit 1
}

[[ -z "$branch" ]] && usage && exit 1
[[ -z "$author" ]] && usage && exit 1

REPO_NAME=$(basename $(git rev-parse --show-toplevel))
if [[ $? -ne 0 ]]; then
    echo "Failed to get repository name"
    popd >/dev/null
    exit 1
fi

commits=$(git log --author="$author" --pretty=format:"%h" --since="$since" "$branch")
if [[ $? -ne 0 ]]; then
    echo "Failed to get commit list"
    popd >/dev/null
    exit 1
fi

echo "Commit count: $(echo "$commits" | wc -l)"

EVERYTHING_FILE="$HOME/$REPO_NAME.txt"

echo "$commits" | while read commit; do
    cat <<EOF >>"$EVERYTHING_FILE"
=================================
Commit: $commit
=================================
EOF

    git log -p --format="%B" -n 1 "$commit" >>"$EVERYTHING_FILE"
    [[ $? -ne 0 ]] && echo "Failed to get commit details for $commit" && continue

    git diff-tree --no-commit-id --name-only -r "$commit" >>"$EVERYTHING_FILE"
    [[ $? -ne 0 ]] && echo "Failed to get commit files for $commit" && continue
done

popd >/dev/null

echo "Output written to: $EVERYTHING_FILE"
