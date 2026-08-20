---
name: weekly-update
description: >-
  Child skill that writes a weekly status update from the shared
  TellMeAboutATimeWhen evidence set. Use when the user asks for a weekly update,
  status update, or answers to what shipped, what is needed, and next-week
  priorities.
---

# Weekly Update

Require parent evidence from [Tell Me About A Time When](../tell-me-about-a-time-when/SKILL.md). Invoke the parent only if commit artifacts or `meetings/` evidence for this analysis root are missing.

Using all collected evidence, create an exhaustive but direct response to these questions:

- What updates do you have?
- What do you need from me (i.e., items to review, questions to answer, items you'd like updates on)?
- What are your top priorities for next week?

Output path: write the completed weekly update to `updates/weekly-update-YYYY-MM-DD.md` using the week end date.
