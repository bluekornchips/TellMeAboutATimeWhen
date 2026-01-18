# Git Commit Analyzer

This script analyzes Git commits within a specified repository, branch, and author, and outputs the commit details, messages, and changed files to paginated text files. It also includes a safety check to ensure the provided author has commits in the repository.

## Requirements

- **Bash**: Version 4.0 or higher (for array support)
- **Git**: Required for repository operations
- **GitHub CLI (`gh`)**: Required only if using `--github` option
- **jq**: Required only if using `--github` option

## Usage

```bash
./tell-me-about.sh -p <path> -b <branch> -a <author> [--page-size <number>] [--range <date> | --range <start_date> <end_date>] [--github]
```

**Required Arguments:**

- `-p <path>`: Path to the Git repository.
- `-b <branch>`: Branch to analyze.
- `-a <author>`: Author of the commits.

**Optional Arguments:**

- `--page-size <number>`: Number of commits per output file (0 for single file, default: 0).
- `--range <date>`: Analyze commits since the specified date (single argument).
- `--range <start_date> <end_date>`: Analyze commits between two dates (two arguments).
- `--github`: Include GitHub details for commits, such as pull request information (requires GitHub CLI and jq).
- `-h, --help`: Show help message.

If no range is specified, defaults to analyzing commits from the past week.

## Examples

Analyze commits by a specific author for the past 2 weeks:

```bash
./tell-me-about.sh -p /path/to/my/repo -b main -a "Author Name" --range "2 weeks ago"
```

Analyze commits by a specific author between two specific dates:

```bash
./tell-me-about.sh -p /path/to/my/repo -b main -a "Author Name" --range "2025-01-01" "2025-12-31"
```

Analyze commits by a specific author from the past week (default behavior):

```bash
./tell-me-about.sh -p /path/to/my/repo -b main -a "Author Name"
```

Analyze commits with pagination (5 commits per file):

```bash
./tell-me-about.sh -p /path/to/my/repo -b main -a "Author Name" --page-size 5
```

Analyze commits with GitHub pull request details:

```bash
./tell-me-about.sh -p /path/to/my/repo -b main -a "Author Name" --github
```

## Output

The script generates paginated text files in the directory `$HOME/tellmeaboutatimewhen/{repo}_{branch}_{author}/{timestamp}/`. Each page file follows the naming pattern `page_N_hash_hash.txt` where:
- `N` is the page number
- `hash_hash` are the first 7 characters of the first and last commit hashes in that page

Each page file contains:

- Commit details (diffs and messages) for all commits in that page
- List of changed files for each commit
- Pull request details (if `--github` option is used)

The script outputs the commit count and the output directory path to stdout.

## Error Handling

The script includes comprehensive error handling for:

- Invalid repository path.
- Failed directory changes.
- Failed Git commands (e.g., getting repository name, commit list, commit details, changed files).
- Missing required arguments.
- Invalid date formats for the `--range` argument.
- Multiple usage of the `--range` or `--page-size` flags.
- **Author existence check:** Ensures the provided author has commits within the repository's history, preventing unnecessary processing and empty output files.
- GitHub CLI authentication (when using `--github` option).

## Environment Variables

- `HOME`: Used to determine the output directory base path (`$HOME/tellmeaboutatimewhen`). Must be set.

## Dependencies

- `bash`
- `git`
- `jq`
- `gh`

## Installation

1.  Clone or download the script.
2.  Make the script executable:

```bash
chmod +x tell-me-about.sh
```

3.  Run the script from your terminal, providing the required arguments.

```bash
./tell-me-about.sh -p /path/to/your/repo -b yourBranch -a AuthorName
```

Or with date range filtering:

```bash
./tell-me-about.sh -p /path/to/your/repo -b yourBranch -a AuthorName --range "1 month ago"
```
