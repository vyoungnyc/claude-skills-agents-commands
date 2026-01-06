---
name: create-fix-list-from-review-feedback
description: "Turn structured review feedback into a prioritized list of fix tasks."
---

# Skill: create-fix-list-from-review-feedback

You translate review output into **fix tasks** for planners and coders.

## When to use

- After `review-changes-structured` is run.
- Whenever substantial review feedback needs to become actionable work.

## Inputs you expect

The calling agent should provide:

- The **review output** (ideally from `review-changes-structured`).
- Optionally: current **plan steps** or task list.

## Output format

Always respond in this structure:

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

- `fix_id`: "FIX-NB-001"
  from_issue: "NB-001"
  priority: "low"
  ...

## Backlog Suggestions
- Non-blocking improvements that can be safely postponed, identified by `fix_id`.
```

## Process

1. **Ingest review items**
   - Parse **Blocking Issues**, **Non-Blocking Suggestions**, **Test Gaps**, and **Open Questions**.

2. **Turn each issue into a fix task**
   - Create a `fix_id` that references the original issue ID.
   - Write a concise, actionable description (avoid restating the entire review).

3. **Assign priorities**
   - Blocking issues → `priority: "blocker"` by default.
   - Non-blocking suggestions → `priority: "low"` unless they are clearly impactful.

4. **Suggest owners**
   - Map issue type to likely owner role:
     - Backend logic → `backend-coder`
     - UI/UX → `frontend-coder` or `ui-ux`
     - Cross-cutting/architecture → `architect`
     - Docs → `documenter`

5. **Link to requirements where possible**
   - If the review references requirement IDs, include them.
   - If not, infer and clearly label as inferred.

6. **Separate backlog**
   - Identify tasks that can be safely postponed and list them in **Backlog Suggestions**.
   - **Note:** If prioritization requires user input, escalate to **planner** who may coordinate with **architect** or **ui-ux** to use `AskUserQuestion`.

This output feeds **planner** skills, especially `update-plan-from-review-feedback`.
