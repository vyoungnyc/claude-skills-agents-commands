---
name: scan-feature-context
description: "Given a feature/task, assemble a concise, structured context: relevant code, docs, prior work, risks, and open questions."
---

# Skill: scan-feature-context

You help agents quickly understand **where in the repo and docs a feature lives**.

## When to use

- At feature kickoff (planner, architect, coder, reviewer).
- Before planning, architecture, implementation, or review.
- When a feature touches unknown or cross-cutting areas.

## Inputs you expect

The calling agent should provide:

- A short **feature description** (ticket link or text, task_id if available).
- Any **file lists, search/grep results, or index hits** they already have.
- Optionally: links/snippets of **related docs** (RFCs, ADRs, PLAN_docs, etc.).

## Output format

Always respond in this structure:

```markdown
## Summary
- One or two sentences about what code and docs are likely relevant.

## Relevant Code Areas
- `path/to/file.ts`: short reason it matters.
- `path/to/dir/`: what kind of code lives here.

## Related Tests
- `path/to/test.spec.ts`: what behavior it validates.
- Gaps you notice (e.g. "no tests around X yet").

## Related Docs
- Title (path or link): why it’s relevant.
- Note if doc looks stale or conflicting.

## Similar Prior Work
- PR/feature/task identifiers with a brief note on similarity.

## Risks & Unknowns
- Potential risk areas due to dependencies, shared types, or side effects.
- Explicit open questions about behavior or ownership.
```

## Process

1. **Parse the feature description**
   - Infer the domain area, main components (backend, frontend, data pipelines, etc.).
   - Note any identifiers: `task_id`, ticket IDs, feature flags, API names.

2. **Organize code context**
   - From provided file lists / search results, identify:
     - Core implementation files.
     - Supporting utilities and shared modules.
     - Cross-cutting areas (auth, logging, metrics, feature flags).
   - Group them in **“Relevant Code Areas”** with a short justification.

3. **Locate tests**
   - Highlight tests directly covering this behavior.
   - Note missing test coverage:
     - “No tests touching X” is a useful observation.
   - Suggest where new tests should go (paths / patterns).

4. **Connect docs**
   - Identify RFCs/ADRs/PLAN_docs that describe the same area.
   - Call out if multiple docs conflict or appear outdated.

5. **Find similar prior work**
   - Use any provided history (PR titles, old tasks, commit messages) to:
     - Point to earlier iterations or related features.
     - Suggest patterns to reuse instead of re-inventing.

6. **Surface risks and unknowns**
   - Mention potential regressions (shared types, shared tables, shared APIs).
   - List explicit questions a planner/architect should resolve.
   - **Note:** If these questions require user clarification, the **architect** or **ui-ux** agents will use `AskUserQuestion`—do not ask the user directly from this skill.

Stay concise but **structured**; the planner/architect should be able to use your output as the "context section" of their own work.
