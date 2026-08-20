---
name: brag-book
description: >-
  Child skill that creates a weekly brag document from the shared
  TellMeAboutATimeWhen evidence set. Use when the user asks for a brag book,
  brag document, weekly brag, or past-week highlights from tellme output.
---

# Brag Book

Require parent evidence from [Tell Me About A Time When](../tell-me-about-a-time-when/SKILL.md). Invoke the parent only if commit artifacts or `meetings/` evidence for this analysis root are missing.

Create a weekly brag document for the past week and the upcoming week. Use a concise, direct tone.

## Constraints

- Timebox: Last 7 days and next 7 days only.
- Format: Markdown.

## Sections

### Context

Date range and primary focus.

### Past Week

List significant outcomes, projects, and contributions.
Include "fuzzy" work like process improvements, hiring, or maintenance.
Include collaboration, mentorship, and learning.
Focus on impact and metrics.
Include relevant meeting outcomes and transcript highlights from Coworker.

### Next Week

List top goals and priorities.
Identify blockers or support needed.

### Reflection

What are you most proud of?
What went well and what did not?

Write the document in markdown format to `updates/brag-book-YYYY-MM-DD.md` using the week end date.
