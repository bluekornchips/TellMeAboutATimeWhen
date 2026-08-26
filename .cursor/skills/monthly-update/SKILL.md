---
name: monthly-update
description: >-
  Child skill that writes a monthly status update from the shared
  TellMeAboutATimeWhen evidence set. Use when the user asks for a monthly
  update, monthly review, or a report covering the past month.
---

# Monthly Update

Require parent evidence from [Tell Me About A Time When](../tell-me-about-a-time-when/SKILL.md). Invoke the parent only if commit artifacts or `meetings/` evidence for this analysis root are missing.

Generate a monthly update. Keep it short, specific, and honest about risks.

Include these sections in order:

1. What I delivered this month
2. Status of my goals. Omit this section unless the user supplied goals.
3. Where I am focused next month
4. What I need
5. Anything at risk, or a goal that has changed. Optional.
6. A moment I am proud of
7. Values. Optional. Include only if the user supplied company values.
8. Anything else. Optional.

Guidelines:

- A few bullets per section is plenty. Focus on outcomes and impact, not every task.
- Flag risks early. Nothing in a later review should be a surprise.
- Include ticket links, PR numbers, and dates when available.

Write the update in markdown format to `updates/monthly-update-YYYY-MM.md` using the reported month.
