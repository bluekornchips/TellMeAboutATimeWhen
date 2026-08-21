---
name: tell-me-about-a-time-when
description: >-
  Builds the shared TellMeAboutATimeWhen evidence set from commit files,
  GitHub, JIRA, and Coworker meetings. Use before creating a weekly update,
  one-on-one review, brag book, or other report from tellme output.
---

# Tell Me About A Time When

Use this parent workflow before applying a child reporting skill.

## MCP efficiency

Always use `auto` when an MCP operation exposes a model selector. If `auto` is unavailable, use the cheapest model offered by that operation. Do not upgrade models for retrieval or summarization unless the user explicitly requests it.

Call MCP tools directly instead of starting an additional model-powered agent. Coworker `calendar_search` and `transcript_by_id` do not currently expose a model selector, so invoke them without one.

## Shared workflow

1. Identify the analysis root from the supplied tellme paths:
   `$HOME/tellme/{repo_name}/{branch}/{author}/`.
2. Read every relevant commit directory under that root.
3. Use `diff.txt`, `pr.json`, and `jira.txt` when present.
4. Reuse existing commit artifacts and `meetings/` files when present. Only fill gaps; do not re-fetch calendar or transcripts for meetings that already have `details.txt` or `transcript.txt`.
5. Use the commit analysis `--range`, or the dates derived from `--sha`, as the meeting window.
6. Resolve timezone from `COWORKER_TIMEZONE`, the local system timezone, or the user's stated timezone.
7. Call Coworker `calendar_search` with `start_date`, `end_date`, `timezone`, and `limit` 100 when meeting evidence is missing.
8. For each meeting with a `transcript_id` and no `transcript.txt` yet, call Coworker `transcript_by_id` with that id, the same timezone, and `max_chars` 100000. Page with `offset_chars` until the transcript is complete.
9. Persist meeting artifacts to disk in the same turn you retrieve them. Do not keep transcripts only in context and then write a short `details.txt`.
10. Apply the requested child skill to the complete commit and meeting evidence set.

Do not invent missing commits, tickets, pull requests, meetings, or transcripts. If Coworker MCP is unavailable, state that limitation and continue from commit evidence.

## Required meeting structure

```text
$HOME/tellme/{repo_name}/{branch}/{author}/
|-- {short_commit}/
|   |-- diff.txt
|   |-- pr.json
|   `-- jira.txt
`-- meetings/
    `-- YYYY-MM-DD_slug/
        |-- details.txt
        `-- transcript.txt
```

Write `details.txt` for every meeting with its title, time, attendees, source URL, summary, decisions, and action items when available. The Summary, Decisions, and Action items sections must be the full meeting record from the transcript, every topic, decision, and action, not a three-line gloss. If Coworker returns a native AI summary, copy that text into Summary verbatim. If it does not, write the complete summary from the full `transcript.txt` after it is on disk.

Write `transcript.txt` immediately whenever Coworker returns a transcript. The file must contain the full speaker text, not a paraphrase.

## Child skills

- [Weekly update](../weekly-update/SKILL.md)
- [One on one](../one-one-one/SKILL.md)
- [Brag book](../brag-book/SKILL.md)
