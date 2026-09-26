# TellMeAboutATimeWhen

Git commit analyzer that writes commit details, GitHub pull requests, and JIRA tickets for an author, then prepares a Coworker meeting window for Cursor project skills.

## Overview

`tell-me-about.sh` analyzes commits and writes one directory per commit. GitHub, JIRA, and Coworker are enabled by default. Pass `--tools` with a comma-separated subset to narrow that set.

Each commit directory can contain:

- `diff.txt`: Commit message, patch, and changed files
- `pr.json`: Pull request details when `github` is enabled
- `jira.txt`: Ticket details extracted from the commit message when `jira` is enabled

When `github` is enabled, the analyzer also writes involvement PRs under `prs/`:

- `prs/merged/index.json`: PRs the author merged in the date window
- `prs/reviewed/index.json`: PRs the author reviewed, any `reviewed-by` activity
- `prs/commented/index.json`: PRs the author commented on

Involvement collection uses `-g`/`--github-login` as the GitHub login, falling back to `-a`/`--author` when `-g` is not given. Pass `-g` separately when the git commit author (name or email) differs from the GitHub username, such as when a personal GitHub noreply email is not the git identity used for commits. These indexes are written even when no local commits are found in the range.

Two properties matter when reading these indexes:

- GitHub PR search has no `merged-by` qualifier, so the merged role lists merged PRs in the window and filters on `mergedBy` locally. Merged entries carry a true `mergedAt`.
- The reviewed and commented roles are windowed by last update, not by when the review or comment happened, because GitHub search offers no event-time qualifier for them. A PR reviewed earlier but updated inside the window still appears. The same PR can appear under more than one role, so dedupe by `number` before counting.

The `coworker` tool does not download meetings from bash. It verifies Coworker MCP in `~/.cursor/mcp.json`, creates `meetings/`, and prints the date window plus project skill paths. The parent skill then calls Coworker `calendar_search` and `transcript_by_id` and writes:

- `meetings/YYYY-MM-DD_slug/details.txt`: Title, time, attendees, URL, summary, decisions, action items
- `meetings/YYYY-MM-DD_slug/transcript.txt`: Transcript when Coworker returned one

## Layout

```text
tell-me-about.sh          Orchestrator CLI, argv and pipeline
tools/
  github.sh               Sourced GitHub helpers, not run directly
  jira.sh                 Sourced JIRA helpers, not run directly
  coworker.sh             Sourced Coworker MCP helpers, not run directly
  lib/
    git.sh                Shared git helpers
    util.sh               Shared micro-helpers
    commits.sh            Commit selection and period helpers
    print.sh              Summary card helpers only
.cursor/skills/
  tell-me-about-a-time-when/   Parent evidence skill
  weekly-update/               Child report skill
  one-one-one/                 Child report skill
  brag-book/                   Child report skill
  monthly-update/              Child report skill
tests/
  helpers/
    repo.sh               Shared git fixtures
    bats-setup.sh         Shared Bats bootstrap
  tell-me-about-tests.sh  Orchestrator suite
  tools/                  Mirrored tool and lib suites
```

## Requirements

- Bash 3.2 or higher
- Git
- GitHub CLI (`gh`) when `github` is enabled
- jq when `github` or `coworker` is enabled
- Atlassian CLI (`acli`) when `jira` is enabled
- Coworker MCP in `~/.cursor/mcp.json` when `coworker` is enabled

## Install

```bash
git clone https://github.com/bluekornchips/TellMeAboutATimeWhen.git
cd TellMeAboutATimeWhen
make install
```

## Usage

```bash
./tell-me-about.sh [--repo <path>:<branch> ...] [-a <author>] [-g <github-login>] --range <date> [<end>] [options]
```

Required:

- `--repo <path>:<branch>`: Repository path and branch, repeatable
- `--range`: Commit date window

Optional:

- `-a, --author <author>`: Commit author (name or email), matched against `git log --author`; defaults to git global `user.name` or `user.email`
- `-g, --github-login <login>`: GitHub username for PR search and merge-commit matching, when it differs from `-a`; defaults to the value of `-a`
- `--range <date>`: Commits since `YYYY-MM-DD`, or between two dates when a second date is given
- `--tools <tools>`: Comma-separated subset of `jira`, `github`, `coworker`; default is all three
- `-h, --help`: Show help

Period dates always come from `--range`. The `coworker` tool uses that window for meetings.

## Examples

```bash
# Since a date, all tools
./tell-me-about.sh --repo /path/to/repo:main -a "Author Name" --range "2026-01-01"

# Between two dates
./tell-me-about.sh --repo /path/to/repo:main -a "Author Name" --range "2026-01-01" "2026-01-31"

# Multiple repositories
TELLME_REPOS_ROOT="$HOME/repos" ./tell-me-about.sh \
  --repo repo-one:main \
  --repo repo-two:develop \
  -a "Author Name" \
  --range "2026-08-01" "2026-08-26"

# GitHub and JIRA only
./tell-me-about.sh --repo /path/to/repo:main -a "Author Name" --range "2026-01-01" "2026-01-31" --tools github,jira

# Git commit author differs from the GitHub login
./tell-me-about.sh --repo /path/to/repo:main -a "author@example.com" -g "github-login" --range "2026-01-01" "2026-01-31"
```

## Output Structure

Default root is `$HOME/tellme`. Override with `OUTPUT_DIR`.

```text
$OUTPUT_DIR/{repo_name}/{branch}/{author}/
|-- {short_commit}/
|   |-- diff.txt
|   |-- pr.json
|   `-- jira.txt
|-- prs/
|   |-- merged/index.json
|   |-- reviewed/index.json
|   `-- commented/index.json
`-- meetings/
    `-- YYYY-MM-DD_slug/
        |-- details.txt
        `-- transcript.txt
```

Branch and author path segments are lowercased and sanitized for the filesystem. The CLI creates `meetings/` and `prs/`; the parent skill fills meeting files and reads both commit-linked and involvement PR evidence.

Child skills write distinct report files under `updates/`:

- `updates/weekly-update-YYYY-MM-DD.md`
- `updates/one-one-one-YYYY-MM-DD.md`
- `updates/brag-book-YYYY-MM-DD.md`
- `updates/monthly-update-YYYY-MM.md`

## Terminal Output

[`tools/lib/print.sh`](tools/lib/print.sh) formats the commit and meetings summary cards at the end of a run. Everything else is plain bash.

- Summary stdout: `=== repo:branch, N commits ===` from `process_repo`, then `print_section` / `print_field` / `print_paths` for Commit, Diff, Jira, GitHub, PRs, Meetings, Window, Parent, Child
- Errors stderr: `echo "function:: message" >&2`
- Separators: ASCII hyphens; width from `COLUMNS`, capped at 120
- Summary cards always use color

## Authentication

### GitHub

When `github` is enabled:

```bash
gh auth login --web --hostname github.com
gh auth status
```

### JIRA

When `jira` is enabled, install Atlassian CLI from the [installation guide](https://developer.atlassian.com/cloud/acli/guides/install-acli/), then authenticate:

```bash
acli jira auth login --web
# or
acli jira auth login --site "your-site.atlassian.net" --email "your-email@example.com" --token
acli jira auth status
```

Needed permissions: browse projects, read issues, read comments.

### Coworker MCP

Add a Coworker server to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "coworker": {
      "type": "http",
      "url": "https://odin.coworker.ai/mcp"
    }
  }
}
```

After a run with `coworker` enabled, use the parent skill to build the evidence set and write meetings, then a child skill for the report:

- Parent: [`.cursor/skills/tell-me-about-a-time-when/SKILL.md`](.cursor/skills/tell-me-about-a-time-when/SKILL.md)
  - Child: [`.cursor/skills/weekly-update/SKILL.md`](.cursor/skills/weekly-update/SKILL.md)
  - Child: [`.cursor/skills/one-one-one/SKILL.md`](.cursor/skills/one-one-one/SKILL.md)
  - Child: [`.cursor/skills/brag-book/SKILL.md`](.cursor/skills/brag-book/SKILL.md)
  - Child: [`.cursor/skills/monthly-update/SKILL.md`](.cursor/skills/monthly-update/SKILL.md)

Override the MCP config path with `COWORKER_MCP_CONFIG` in tests or automation.

## Testing

```bash
make test
make lint
```

Suites:

- `tests/tell-me-about-tests.sh`: orchestrator
- `tests/tools/*-tests.sh`: tools and shared libs
- `tests/helpers/`: fixtures and Bats bootstrap

## Environment Variables

- `HOME`: Required; used for the default output root and MCP config path
- `OUTPUT_DIR`: Output root; defaults to `$HOME/tellme`
- `COWORKER_MCP_CONFIG`: Cursor MCP JSON path; defaults to `$HOME/.cursor/mcp.json`
- `COWORKER_TIMEZONE`: Optional IANA timezone for project skills
- `TELLME_REPOS_ROOT`: Base directory for relative paths in `--repo`
- `COLUMNS`: Terminal width hint for summary separators; capped at 120
