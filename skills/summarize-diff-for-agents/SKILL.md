---
name: summarize-diff-for-agents
description: "Turn raw diffs or PRs into structured summaries: modules changed, behavior, APIs, risks, and test impact."
---

# Skill: summarize-diff-for-agents

You provide a **review-ready summary** of code changes.

## When to use

- Before review, architecture review, or test-spec updates.
- When assessing impact of a branch/PR.

## Inputs you expect

The calling agent should provide:

- The **diff or PR description** (git diff, GitHub/GitLab PR summary, etc.).
- Optional: list of **changed files**, tests, or migration notes.
- Optional: relevant **requirements/plan** for context.

## Output format

Always respond in this structure:

```markdown
## High-Level Summary
- 2–4 bullets summarizing what changed.

## Changed Areas
### Backend
- `path/to/file.ts`: purpose of changes.
### Frontend
- `path/to/component.tsx`: purpose of changes.
### Shared / Infra
- `path/to/shared.ts`: purpose of changes.

## Behavioral Changes
- User-visible behavior changes.
- System behavior changes (e.g., retries, timeouts, caching).

## API & Data Model Changes
- New endpoints or fields.
- Changed request/response formats.
- Migrations and schema changes.

## Tests
- New tests added.
- Existing tests modified.
- Areas still missing coverage.

## Risks & Potential Regressions
- Hotspots, especially shared utilities and cross-cutting concerns.

## Unknowns / Things to Double-Check
- Items that need clarification or deeper review.
```

## Process

1. **Scan the diff**
   - Group changes by area: backend, frontend, shared, infra, tests.
   - Look for patterns: new modules vs modifications vs deletions.

2. **Identify behavior changes**
   - Highlight user-visible changes.
   - Note non-obvious behavior changes (error handling, retries, timeouts, data validation).

3. **Highlight API/data changes**
   - Any change to public APIs or data models is critical.
   - Call out backwards-incompatibility, migrations, and rollout risks.

4. **Assess tests**
   - Note where tests were added, updated, or removed.
   - Point out any major new paths without tests.
   - Suggest where tests should be added (type + file path).

5. **Surface risks**
   - Shared libraries, reused types, or global configuration changes.
   - Places where behavior change might affect other features.

6. **Capture unknowns**
   - Anything that seems surprising, unclear, or conflict with requirements/plan.

This summary is the **input** for `review-changes-structured`, `derive-test-spec-from-requirements` (for deltas), `sync-docs-with-implementation`, and planner updates.
