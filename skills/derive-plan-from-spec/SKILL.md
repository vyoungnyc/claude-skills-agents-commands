---
name: derive-plan-from-spec
description: "Turn structured requirements into a phased, dependency-aware implementation plan with clear Definition of Done."
---

# Skill: derive-plan-from-spec

You generate a **structured, phased plan** for implementing a feature.

## When to use

- Once requirements have been extracted/approved.
- Before significant implementation begins.
- When scope changes and the plan must be recalibrated.

## Inputs you expect

The calling agent should provide:

- The **requirements output** (ideally from `extract-requirements-from-ticket`).
- Any **feature/task_id** and owner information if available.
- Any existing **process templates** (e.g., implementation → tests → security review → review → docs).

## Output format

Always respond in this structure:

```markdown
## Plan Summary
- One-paragraph overview of phases and key risks.

## Phases
1. Phase name – one-line description
2. ...

## Steps (Canonical Flow)
- Implementation
- Tests
- Security review (if applicable)
- Review
- Documentation

## Detailed Steps
- `step_id`: "<task_id>.step_01_implementation"
  title: "Implement core behavior"
  primary_agent: "backend-coder" | "frontend-coder" | "architect" | ...
  dependencies: []
  related_requirements: ["R-001", "R-002"]
  definition_of_done: |
    - Bullet list DoD, including tests existing or planned.
  handoff_targets:
    - "test-spec"
  status: "pending"

- `step_id`: "<task_id>.step_02_tests"
  ...
```

If you don’t know `task_id`, use a generic placeholder like `"feature.step_01_implementation"`.

## Process

1. **Ingest requirements**
   - Map each must-have requirement to likely implementation areas (backend, frontend, infra).

2. **Define phases**
   - At minimum include:
     - Implementation
     - Tests
     - Security review (if the feature touches auth/PII/external exposure)
     - Review
     - Documentation
   - Add extra phases as needed (migration, UX refinements, performance, rollout).

3. **Break phases into steps**
   - For each phase, create 1–N **steps**, each with:
     - A stable `step_id`.
     - `title`.
     - `primary_agent` (architect, backend-coder, frontend-coder, test-spec, reviewer, documenter, security-researcher).
     - `dependencies` on earlier steps.
     - `related_requirements` IDs.
     - `definition_of_done` as a clear checklist.
     - `handoff_targets` (who should pick up once this step is done).
     - Initial `status: "pending"`.

4. **Ensure tests and docs are first-class**
   - Tests must be their own step(s), not a bullet in implementation.
   - Docs must be explicitly called out, with DoD referencing:
     - Updated docs
     - Release notes/changelog if relevant.

5. **Call out risks and assumptions**
   - In the summary, mention:
     - High risk areas (unknown dependencies, big refactors).
     - Assumptions that could break the plan.

This plan should be something the **planner updates**, and coders/reviewers treat as the single source of truth for work sequencing.
