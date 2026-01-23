# TellMeAboutATimeWhen

Git commit analyzer that extracts commit details, GitHub pull requests, and JIRA ticket information for a specific author within a repository.

## Overview

This tool analyzes git commits and saves detailed information to commit-specific directories. Each commit gets its own directory containing:

- `diff.txt`: Commit message and changed files
- `pr.json`: Pull request details from GitHub
- `jira.txt`: JIRA ticket details extracted from commit messages

## Requirements

- Bash 4.0 or higher
- Git
- GitHub CLI (`gh`) for `--github` option
- jq for `--github` option
- Atlassian CLI (`acli`) for `--jira` option

## Install

```bash
git clone https://github.com/bluekornchips/TellMeAboutATimeWhen.git
cd TellMeAboutATimeWhen
make install
```

## Usage

```bash
./tell-me-about.sh -p <path> -b <branch> -a <author> [options]
```

Required Arguments:

- `-p <path>`: Path to the git repository
- `-b <branch>`: Branch to analyze
- `-a <author>`: Author of the commits

Optional Arguments:

- `--range <date>`: Analyze commits since date, or between two dates when two arguments provided
- `--sha <commit>`: Analyze specific commit by SHA, can be used multiple times, replaces `--range`
- `--include-merges`: Include merge commits with subjects matching the author
- `--github`: Include GitHub pull request details for commits
- `--jira`: Include JIRA ticket details for commits that reference tickets
- `-h, --help`: Show help message

If no range or SHA is specified, defaults to commits from the past week.

## Examples

Analyze commits by author for the past week:

```bash
./tell-me-about.sh -p /path/to/repo -b main -a "Author Name" --range "1 week ago"
```

Analyze commits between two specific dates:

```bash
./tell-me-about.sh -p /path/to/repo -b main -a "Author Name" --range "2025-01-01" "2025-01-31"
```

Analyze specific commits by SHA:

```bash
./tell-me-about.sh -p /path/to/repo -b main -a "Author Name" --sha abc1234 --sha def5678
```

Analyze commits with GitHub and JIRA details:

```bash
./tell-me-about.sh -p /path/to/repo -b main -a "Author Name" --github --jira
```

Include merge commits in analysis:

```bash
./tell-me-about.sh -p /path/to/repo -b main -a "Author Name" --include-merges
```

## Output Structure

The script creates directories at:

```
$HOME/tmaatw/{repo_name}/{branch}/{author}/{short_commit}/
```

Each commit directory contains:

- `diff.txt`: Full commit diff, message, and list of changed files
- `pr.json`: GitHub pull request details as JSON, created when `--github` is used
- `jira.txt`: JIRA ticket details and comments, created when `--jira` is used

## GitHub Authentication

When using the `--github` option, the script requires GitHub CLI to be installed and authenticated.

Setup:

```bash
gh auth login --web --hostname github.com
```

Verify authentication:

```bash
gh auth status
```

## JIRA Authentication

When using the `--jira` option, the script requires Atlassian CLI to be installed and authenticated.

Required Permissions:

- Browse Projects: Read access to projects containing referenced tickets
- Read Issues: Permission to view issue details
- Read Comments: Permission to view issue comments

Setup:

Install Atlassian CLI following the [installation guide](https://developer.atlassian.com/cloud/acli/guides/install-acli/).

Authenticate with OAuth:

```bash
acli jira auth login --web
```

Or authenticate with API token:

```bash
acli jira auth login --site "your-site.atlassian.net" --email "your-email@example.com" --token
```

Verify authentication:

```bash
acli jira auth status
```

## Testing

Run all tests:

```bash
make test
```

Run linting:

```bash
make lint
```

## Standalone Tool Usage

The GitHub and JIRA tools can be used independently.

Get PR details for a commit:

```bash
./tools/github.sh <commit_hash>
```

Get JIRA ticket details:

```bash
./tools/jira.sh <ticket_id>
```

## Environment Variables

- `HOME`: Used to determine the output directory base path, must be set
- `OUTPUT_DIR`: Override the default output directory, defaults to `$HOME/tmaatw`
