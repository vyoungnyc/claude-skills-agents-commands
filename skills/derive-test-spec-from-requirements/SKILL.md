---
name: derive-test-spec-from-requirements
description: "Turn requirements and architecture into a concrete test plan with unit, integration, and E2E cases."
---

# Skill: derive-test-spec-from-requirements

You create a **test playbook** for a feature.

## When to use

- After requirements and initial architecture are known.
- Before or during implementation, and again before release.

## Inputs you expect

The calling agent should provide:

- The **requirements** (must-haves, constraints).
- Optional: the **architecture proposal**.
- Optional: diff summary if focusing on incremental coverage.

## Output format

Always respond in this structure:

```markdown
## Test Strategy Summary
- Short description of what levels of tests will be used and why.

## Unit Tests
- [UT-001] Area: "backend service X"
  related_requirements: ["R-001"]
  preconditions:
  steps_or_inputs:
  expected_outcome:

## Integration Tests
- [IT-001] Area: "service X + database"
  ...

## End-to-End Tests
- [E2E-001] User flow description.
  ...

## Edge Cases & Negative Tests
- Specific scenarios that must be covered.

## Out-of-Scope / Deferred Tests
- Tests that are intentionally not part of this phase.
```

## Process

1. **Map requirements to behaviors**
   - For each must-have requirement, identify:
     - Where it lives in the system (backend, frontend, infra).
     - How a user or system would exercise it.

2. **Design unit tests**
   - For services, components, and utilities:
     - Define clear inputs and expected outputs.
     - Include happy paths and key edge cases.

3. **Design integration tests**
   - Focus on boundaries: service + DB, service + external API, backend + frontend API contracts.
   - Include failures/timeouts where relevant.

4. **Design E2E tests**
   - User-visible flows:
     - Start → action → UI results → side effects.
   - Ensure critical flows are covered (create, read, update, delete, error).

5. **Capture edge and negative tests**
   - Invalid inputs, permission issues, concurrency, rate limits, etc.

6. **Call out deferred tests**
   - Anything too expensive or out of scope for this phase, with a rationale.

This spec guides **test-spec, coder, test-runner, and reviewer** in evaluating coverage.
