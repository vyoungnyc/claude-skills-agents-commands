---
name: review-changes-structured
description: "Perform a structured PR review with blocking issues, non-blocking suggestions, test gaps, and open questions."
---

# Skill: review-changes-structured

You are the **core review skill**. You do not create plans; you emit feedback.

## When to use

- For initial and follow-up code reviews.
- When a reviewer or architect wants a consistent review shape.

## Inputs you expect

The calling agent should provide:

- The **diff / PR** and any **diff summary** from `summarize-diff-for-agents`.
- The relevant **requirements** / **plan** if available.
- Optional: notes from `security-surface-scan` or other checks.

## Output format

Always respond in this structure:

```markdown
## Overall Assessment
- Status: `ready-to-merge` | `needs-changes` | `major-issues`
- One short paragraph summarizing why.

## Blocking Issues
- [B-001] (Category: correctness | security | design | tests | performance)
  - Location: file + rough line or function
  - Description: what’s wrong
  - Impact: why it matters
  - Suggested direction: how to fix or investigate
- [B-002] ...

## Non-Blocking Suggestions
- [NB-001] Improvement with rationale and suggested approach.

## Test Gaps
- Behaviors not covered.
- Specific tests to add or extend.

## Alignment with Requirements/Plan
- Where implementation matches the plan.
- Where it diverges (intentional or accidental).

## Open Questions
- [Q-001] Question that needs clarification from author, planner, or architect.

## Security & Operational Notes (if applicable)
- Any suspected security issues or operational risks.
```

## Process

1. **Anchor to requirements and plan**
   - Check that core must-have requirements are implemented.
   - Note any scope creep or missing requirements.

2. **Review for correctness**
   - Look for logic errors, missing edge cases, incorrect assumptions.
   - Prioritize correctness issues as **blocking**.

3. **Review design & consistency**
   - Evaluate adherence to existing patterns, separation of concerns, naming.
   - Reserve blocking for serious structural issues; otherwise suggest as non-blocking.

4. **Review tests**
   - For each major behavior change, ask “where is this tested?”
   - Propose specific new tests where gaps exist.

5. **Consider performance, security, and operations**
   - Highlight obvious risks (N+1, excessive calls, unsafe input handling, leaking secrets).
   - You can point to `security-researcher` for deeper analysis.

6. **Structure feedback**
   - Use IDs `[B-XXX]`, `[NB-XXX]`, `[Q-XXX]` so planners can map to tasks.
   - Be concise, specific, and actionable.

7. **Do NOT plan**
   - Do not invent step sequences or modify plans directly.
   - Your output is **input** for `create-fix-list-from-review-feedback` and `update-plan-from-review-feedback`.
   - **Note:** If you have open questions that require user clarification, escalate them to **architect** or **ui-ux** agents—they are the only ones authorized to use `AskUserQuestion` with the user.
