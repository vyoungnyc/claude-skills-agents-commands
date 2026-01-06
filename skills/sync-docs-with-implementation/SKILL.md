---
name: sync-docs-with-implementation
description: "Identify documentation impacted by code changes and propose concrete updates."
---

# Skill: sync-docs-with-implementation

You keep documentation aligned with the implementation.

## When to use

- After a feature is implemented or significantly changed.
- Before merging, and during release preparation.

## Inputs you expect

The calling agent should provide:

- The **diff summary** (from `summarize-diff-for-agents`).
- The relevant **docs content or excerpts** (API docs, guides, ADRs, PLAN docs).
- Optional: requirements and release notes templates.

## Output format

Always respond in this structure:

```markdown
## Doc Impact Summary
- Short overview of which docs are affected and how.

## Docs to Update
- Doc: "path/to/doc.md" (type: API | user-guide | internal-playbook | ADR)
  impact:
    - What changed in behavior/API.
  proposed_changes:
    - Bullet points or short suggested patches.
  status: "update-needed"

## New Docs to Create
- Title / path suggestion.
- What it should cover and why.

## Confirmed No-Change Areas
- Docs reviewed where no update is needed.

## Open Questions for Product/Docs
- Items that need clarification before updating docs.
```

## Process

1. **Map changes to docs**
   - From the diff summary, infer which docs are likely impacted:
     - API behavior changes → API docs, integration guides.
     - User-visible changes → user guides, screenshots.
     - Architecture changes → ADRs, internal design docs.

2. **Assess each doc**
   - For each provided doc:
     - Does it describe behavior that changed?
     - Are examples / screenshots still accurate?
   - Decide: update needed vs. nothing to change.

3. **Propose focused updates**
   - Suggest concrete update bullets (or short patch-style suggestions).
   - Keep suggestions small and specific.

4. **Identify new docs**
   - If the feature introduces something entirely new, propose a doc:
     - Name, location, audience, and scope.

5. **Flag unresolved questions**
   - Any ambiguity about how something should be documented.
   - These go back to product/owner or documenter.

This skill helps **documenter and orchestrator** ensure docs and code move together.
