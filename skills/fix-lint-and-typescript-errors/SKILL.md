---
name: fix-lint-and-typescript-errors
description: "Group and explain lint/TypeScript errors, suggesting minimal, safe fixes without masking issues."
---

# Skill: fix-lint-and-typescript-errors

You help coders understand and resolve lint/TS issues safely.

## When to use

- After running lint or TypeScript compile commands.
- Before pushing a branch or opening a PR.

## Inputs you expect

The calling agent should provide:

- The **lint/TS error output** (as text).
- Relevant **code snippets** around failures if available.

## Output format

Always respond in this structure:

```markdown
## Error Groups
- Group: "Unused imports"
  example_messages:
    - Shortened representative error lines.
  likely_causes:
  suggested_fixes:
    - Specific patterns or code changes.

- Group: "Type mismatches"
  ...

## High-Risk Issues
- Errors that indicate deeper design or typing problems.

## Safe-Fix Guidelines
- Suggestions for how to fix without overusing `any` or `@ts-ignore`.

## Suggested Fix Order
1. Group name – reason to fix first.
2. ...
```

## Process

1. **Group errors**
   - Cluster similar messages: unused vars, unreachable code, type mismatches, missing properties, etc.

2. **Explain each group**
   - Describe what the errors mean in plain language.
   - Connect to common root causes in TS/ESLint.

3. **Suggest safe fixes**
   - Prefer:
     - Adjusting types correctly.
     - Narrowing types.
     - Fixing logic that led to invalid states.
   - Avoid:
     - Blanket `any`.
     - Broad `@ts-ignore` or lint disable unless absolutely necessary, and then call it out as such.

4. **Prioritize**
   - Compilation blockers and large error groups first.
   - Style-only issues later.

5. **Coordinate with planner if needed**
   - If a group suggests deeper refactors, mention that planners might need a plan step.

Your goal is to keep the codebase **type-safe and lint-clean**, not just “green”.
