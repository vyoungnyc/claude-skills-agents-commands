---
name: propose-architecture-for-feature
description: "Propose backend, frontend, and data design for a feature, aligned with existing patterns."
---

# Skill: propose-architecture-for-feature

You draft a **concrete but lightweight architecture** for a feature.

## When to use

- After requirements are extracted but before major implementation.
- When a feature crosses boundaries or introduces new APIs/models.

## Inputs you expect

The calling agent should provide:

- The **requirements** (ideally from `extract-requirements-from-ticket`).
- Output from `scan-feature-context` (files, docs, prior work).
- Any known **architecture guidelines** or constraints.

## Output format

Always respond in this structure:

```markdown
## Architecture Summary
- 3–6 bullets describing the main design decisions.

## Backend Design
- Services/modules and their responsibilities.
- APIs/endpoints (paths + rough request/response shapes).
- Data models/tables/entities and relationships.

## Frontend Design
- Pages/routes.
- Components and state management approach.
- Interaction with backend APIs.

## Cross-Cutting Concerns
- Auth & authorization.
- Logging & metrics.
- Error handling and retries.
- Feature flags, configuration.

## Data & Contracts
- Key types/schemas (only at the level needed for planning).
- Versioning / backward compatibility considerations.

## Open Design Questions
- Topics that need planner/architect/product input.
```

## Process

1. **Anchor to existing patterns**
   - Reuse existing architectures and module boundaries where possible.
   - Avoid introducing new patterns unless justified.

2. **Sketch backend design**
   - Suggest which service/module owns the new behavior.
   - Propose endpoints and how they interact with existing ones.
   - Note where data should be stored or reused.

3. **Sketch frontend design**
   - Define main screens/components and how data flows between them.
   - Call out global vs local state.

4. **Capture contracts and concerns**
   - Describe the minimal contracts needed between layers (interfaces/types, validation).
   - Surface performance, security, and operational considerations.

5. **Identify open questions**
   - Point out where more information is needed.
   - These feed back to planner/architect/product.

This is the **primary artifact** for coders and reviewers to align on before deep implementation.
