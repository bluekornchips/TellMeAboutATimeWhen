# Git Commit Analyzer

This script analyzes Git commits within a specified repository, branch, and author, and outputs the commit details, messages, and changed files to a text file. It also includes a safety check to ensure the provided author has commits in the repository.

## Usage

```bash
./git-commit-analyzer.sh -p <path> -b <branch> -a <author> [-s <since>]
```

**Required Arguments:**

- `-p <path>`: Path to the Git repository.
- `-b <branch>`: Branch to analyze.
- `-a <author>`: Author of the commits.

**Optional Argument:**

- `-s <since>`: Time range for commits (default: 1 week ago).

## Example

To analyze commits by a specific author on a branch in a repository for the past 2 weeks:

```bash
./git-commit-analyzer.sh -p /path/to/my/repo -b main -a "Author Name" -s "2 weeks ago"
```

## Output

The script generates a text file named `<repository_name>.txt` in the user's home directory (`$HOME`). This file contains:

- Commit hashes.
- Commit details (diffs).
- Commit messages.
- List of changed files for each commit.
- Commit count.

## Error Handling

The script includes comprehensive error handling for:

- Invalid repository path.
- Failed directory changes.
- Failed Git commands (e.g., getting repository name, commit list, commit details, changed files).
- Missing required arguments.
- **Author existence check:** Ensures the provided author has commits within the repository's history, preventing unnecessary processing and empty output files.

Warnings will be displayed if there are issues retrieving commit details or changed files for a specific commit.

## Dependencies

- `bash`
- `git`

## Installation

1.  Clone or download the script.
2.  Make the script executable:

```bash
chmod +x git-commit-analyzer.sh
```

3.  Run the script from your terminal, providing the required arguments.

```bash
./git-commit-analyzer.sh -p /path/to/your/repo -b yourBranch -a AuthorName
```
