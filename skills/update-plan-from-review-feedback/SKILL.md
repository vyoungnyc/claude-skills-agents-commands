---
name: update-plan-from-review-feedback
description: "Apply fix tasks to an existing plan, adjusting steps, dependencies, and priorities."
---

# Skill: update-plan-from-review-feedback

You modify an existing plan to incorporate review-driven fixes.

## When to use

- After `create-fix-list-from-review-feedback`.
- Any time review/security/test findings require plan updates.

## Inputs you expect

The calling agent should provide:

- The current **plan** (steps, dependencies, DoD).
- The **fix tasks** produced by `create-fix-list-from-review-feedback`.
- Optional: current statuses of steps.

## Output format

Always respond in this structure:

```markdown
## Plan Update Summary
- Short description of what changed in the plan.

## Updated Steps
- Existing steps, with:
  - status updated where appropriate.
  - definition_of_done amended if needed.
  - dependencies adjusted if needed.

## New Steps
- New step definitions for major fix groups.
  - `step_id`: "<task_id>.step_fix_B_001"
    title: "Fix blocking issue B-001"
    primary_agent: "backend-coder"
    dependencies: [...]
    related_fix_ids: ["FIX-B-001"]
    definition_of_done: |
      - Checks/tests that must pass to consider this fix complete.

## Deferred / Backlog Items
- Fix tasks intentionally left out of the current plan.
```

## Process

1. **Map fixes to existing steps**
   - For each `fix_id`, see if it naturally belongs under an existing step.
   - If yes, update that step’s **DoD** to include the fix.

2. **Create new steps when needed**
   - For large or cross-cutting fixes, add explicit steps:
     - Give them clear `step_id`s and dependencies.
     - Link them to `related_fix_ids`.

3. **Preserve canonical flow**
   - Keep the high-level sequence (implementation → tests → security review → review → docs).
   - If fixes affect tests or docs, adjust those steps appropriately.

4. **Update statuses carefully**
   - Do not auto-mark steps complete unless explicitly indicated.
   - Mark steps as “blocked” if they cannot proceed until certain fixes are done.

5. **Summarize changes**
   - Clearly list:
     - New steps added.
     - Steps whose DoD changed.
     - Steps whose dependencies changed.
     - Fixes moved to backlog.
   - **Note:** If plan changes require user clarification on scope or priority, the **planner** agent may coordinate with **architect** or **ui-ux** to use `AskUserQuestion`.

Planner uses you to keep the plan as the **source of truth** after review rounds.
