---
name: run-quality-gates-and-triage
description: "Interpret logs from baseline/test/lint commands and produce a structured triage report."
---

# Skill: run-quality-gates-and-triage

You **do not run commands**; you interpret their output.

## When to use

- After running baseline scripts (e.g., `scripts/run_baseline.sh`).
- After running test/lint/TS commands on a branch.

## Inputs you expect

The calling agent should provide:

- A description of **what commands were run** (e.g., baseline script, test suite, lint).
- The **console logs / output** from those commands (possibly truncated).
- Optional: previous baseline results for comparison.

## Output format

Always respond in this structure:

```markdown
## Overall Status
- Status: `all-pass` | `failures` | `inconclusive`
- Short explanation.

## Failure Groups
- Group: "backend unit tests"
  commands: ["npm test -- backend"]
  symptoms:
    - Failing test names and files.
  suspected_causes:
    - Hypotheses tied to recent changes.
  suggested_next_actions:
    - Concrete steps the coder should take.

- Group: "frontend lint"
  ...

## Flakiness & Instability
- Any hints that failures are flaky (intermittent, timeouts, nondeterministic).

## Suggested Fix Order
1. Group name – why it should be fixed first.
2. ...

## Notes for Planner
- Any large work items that might need explicit plan steps.
```

## Process

1. **Parse logs**
   - Identify discrete command sections and their results (pass/fail/timeout).
   - Extract failing test names, file paths, and error messages.

2. **Group failures**
   - Group by subsystem (backend unit tests, frontend unit tests, integration tests, E2E, lint, TS compile).
   - For each group, summarize failure patterns.

3. **Hypothesize causes**
   - Tie failures to likely causes based on error messages and hints about recent changes.
   - Be explicit about uncertainty (“likely”, “possible”, etc.).

4. **Suggest fixes and order**
   - Recommend a fix order that unblocks the most stuff earliest (e.g., compilation/lint issues before tests).
   - Make suggestions actionable but not overly prescriptive.

5. **Flag planner-relevant items**
   - If fixing a group of failures clearly requires new tasks or a refactor, mention that planners should add plan steps.
   - **Note:** If triage reveals ambiguous requirements that need user clarification, the **planner** should coordinate with **architect** or **ui-ux** to use `AskUserQuestion`.

This skill gives **coders and planners** a clear view of the quality state of a branch.
