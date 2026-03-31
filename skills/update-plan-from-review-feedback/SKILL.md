---
name: update-plan-from-review-feedback
description: "Turn review feedback into prioritized fix tasks, then apply them to the existing plan — adjusting steps, dependencies, and priorities."
---

# Skill: update-plan-from-review-feedback

You translate review output into **fix tasks** and then modify the existing plan to incorporate them.

## When to use

- After `review-changes-structured` produces review feedback.
- Any time review/security/test findings require plan updates.

## Inputs you expect

- The **review output** (ideally from `review-changes-structured`).
- The current **plan** (steps, dependencies, DoD).
- Optional: current statuses of steps.

## Output format

```markdown
## Fix Summary
- Short overview of how many blocking/non-blocking items and their themes.

## Fix Tasks
- `fix_id`: "FIX-B-001"
  from_issue: "B-001"
  priority: "blocker" | "high" | "medium" | "low"
  suggested_owner_role: "backend-coder" | "frontend-coder" | "architect" | ...
  description: short description of the change
  linked_requirements: ["R-001"]  # if known
  notes: any caveats or coordination needs

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

### Step 1: Create fix tasks from review feedback

1. **Ingest review items** — Parse **Blocking Issues**, **Non-Blocking Suggestions**, **Test Gaps**, and **Open Questions**.

2. **Turn each issue into a fix task** — Create a `fix_id` that references the original issue ID. Write a concise, actionable description.

3. **Assign priorities**
   - Blocking issues → `priority: "blocker"` by default.
   - Non-blocking suggestions → `priority: "low"` unless clearly impactful.

4. **Suggest owners** — Map issue type to likely owner role:
   - Backend logic → `backend-coder`
   - UI/UX → `frontend-coder` or `ui-ux`
   - Cross-cutting/architecture → `architect`
   - Docs → `documenter`

5. **Link to requirements** where possible. If inferred, label clearly.

### Step 2: Apply fix tasks to the plan

6. **Map fixes to existing steps** — For each `fix_id`, see if it naturally belongs under an existing step. If yes, update that step's **DoD** to include the fix.

7. **Create new steps when needed** — For large or cross-cutting fixes, add explicit steps with clear `step_id`s, dependencies, and `related_fix_ids`.

8. **Preserve canonical flow** — Keep the high-level sequence (implementation → tests → security review → review → docs). If fixes affect tests or docs, adjust those steps.

9. **Update statuses carefully** — Do not auto-mark steps complete unless explicitly indicated. Mark steps as "blocked" if they cannot proceed until certain fixes are done.

10. **Separate backlog** — Identify tasks that can be safely postponed and list them in **Deferred / Backlog Items**.

11. **Summarize changes** — Clearly list: new steps added, steps whose DoD changed, steps whose dependencies changed, fixes moved to backlog.

Escalate user-facing questions to architect or ui-ux.

Planner uses you to keep the plan as the **source of truth** after review rounds.
