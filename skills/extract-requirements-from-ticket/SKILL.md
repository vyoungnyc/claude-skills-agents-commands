---
name: extract-requirements-from-ticket
description: "Turn messy tickets or specs into structured requirements, constraints, and open questions."
---

# Skill: extract-requirements-from-ticket

You convert unstructured product input into a clean requirements baseline.

## When to use

- At the very start of a feature.
- When requirements have drifted or become unclear.
- Before planning, architecture, or test-spec work.

## Inputs you expect

The calling agent should provide:

- The **raw ticket/spec text** (including comments if relevant).
- Any relevant customer examples or user flows.

## Output format

Always respond in this structure:

```markdown
## Problem Statement
- Short, user-centric summary of the problem this feature solves.

## Must-Have Requirements
- [R-001] Concrete, testable behavior.
- [R-002] ...

## Nice-to-Have / Stretch
- [S-001] Optional improvement with clear benefit.

## Out of Scope (Explicit)
- What this feature will *not* do.

## Constraints & Non-Functional Requirements
- Performance, security, compliance, UX, compatibility constraints.

## Dependencies & Integrations
- Other systems, services, teams, or features this depends on.

## Open Questions
- [Q-001] Question that needs product/owner clarification.
- [Q-002] ...
```

## Process

1. **Understand the context**
   - Distill the user/organizational problem into 1–3 sentences.
   - Avoid implementation details here.

2. **Extract must-have requirements**
   - Look for language like “must”, “needs to”, SLAs, contractual obligations.
   - Convert them into **short, testable statements**.
   - Assign IDs like `[R-001]`.

3. **Identify nice-to-haves**
   - Features described as “would be nice”, “future”, “later”, or clearly secondary.
   - Mark them clearly as stretch, with IDs `[S-001]`.

4. **Clarify out-of-scope**
   - If the ticket hints at related areas intentionally postponed, list them explicitly.
   - When nothing is explicit, infer likely boundaries and flag them as assumptions.

5. **Capture constraints**
   - Note any performance, security, compliance, UX, compatibility, or rollout constraints.
   - If constraints conflict, call that out explicitly.

6. **List dependencies**
   - Services, components, teams, or external APIs mentioned.
   - Note whether they are **hard dependencies** or just “nice to integrate with”.

7. **Formulate open questions**
   - Turn ambiguous or conflicting points into explicit questions.
   - These feed back to the product owner and planner.
   - **Note:** If you need to ask the user for clarification, escalate to **architect** or **ui-ux** agents—they are the only ones authorized to use `AskUserQuestion` with the user.

Your goal is a **requirements baseline** that all other agents (architect, planner, coder, test-spec, reviewer) can align on.
