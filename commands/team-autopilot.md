---
name: team-autopilot
description: "Run a feature workflow using agent teams for parallel implementation. Use when backend + frontend can be built simultaneously on non-overlapping files."
args:
  - name: feature_id
    type: string
    required: true
    description: "Short ID for the feature (e.g. PHASE1_DASHBOARD)."
  - name: spec_files
    type: string[]
    required: true
    description: "List of spec file paths or URLs to use as primary inputs."
---

# Command: /team-autopilot

You are the **Orchestrator** using agent teams for parallel implementation.

/!\ HARD RULES:

- You are a **project orchestrator only**.
- You MUST NOT write any code, pseudocode, or file diffs.
- ALL substantive work MUST be done by subagents, teammates, or commands.

> **When to use this command vs /feature-autopilot:**
> Use `/team-autopilot` when the feature has clearly separable backend and frontend work that can be built in parallel on non-overlapping file domains. Use `/feature-autopilot` for sequential work, tightly coupled changes, or when file domains overlap.

---

## Inputs

- `feature_id`: `{feature_id}`
- `spec_files`: `{spec_files}`

---

## Required workflow

### Phase 1: Design (subagents — sequential)

Design work is sequential and doesn't benefit from teams.

1. **Read specs** — Ingest all `{spec_files}` via file reads and MCP tools.
2. **Architecture** — Spawn **architect** subagent. For UI-heavy features, architect consults **ui-ux** first.
3. **Plan** — Spawn **planner** subagent to create `docs/features/{feature_id}/PLAN_steps.md`.
   - Planner must mark which steps are parallelizable and assign file domains.
   - Present plan summary to user for approval before proceeding.

### Phase 2: Implementation (agent team — parallel)

Once the plan is approved and implementation steps are identified:

1. **Identify parallel steps** — Find implementation steps whose dependencies are all satisfied and that touch non-overlapping file domains.

2. **Create agent team** with clear file domain assignments:

   ```
   Create an agent team for {feature_id} parallel implementation:
   - Teammate 1 (backend specialist, use Sonnet): owns [backend file domains from plan].
     Task: implement steps [step_ids]. Follow ARCHITECTURE.md and PLAN_steps.md.
     Context: [relevant architecture snippets, API contracts, data models].
   - Teammate 2 (frontend specialist, use Sonnet): owns [frontend file domains from plan].
     Task: implement steps [step_ids]. Follow ARCHITECTURE.md, UX_NOTES.md, and PLAN_steps.md.
     Context: [relevant UX notes, component structure, API contracts].
   - Teammate 3 (test specialist, use Sonnet): owns tests/ directory.
     Task: design and implement tests for steps [step_ids].
     Context: [test plan from test-spec, existing test patterns].

   Each teammate completes their work independently. Write tests for your own domain.
   Coordinate via SendMessage if you need to agree on shared interfaces (types, API contracts).
   Report back when done.
   ```

3. **File domain assignment rules:**
   - Backend teammate: `src/backend/`, `src/services/`, `src/models/`, `src/lib/`
   - Frontend teammate: `src/frontend/`, `src/components/`, `src/pages/`, `src/hooks/`
   - Test teammate: `tests/`, `__tests__/`, `*.test.ts`, `*.spec.ts`
   - Shared types (`src/types/`): assign to ONE teammate (usually backend), others read-only
   - Prisma schema: assign to backend teammate only
   - Config files: assign based on who needs to modify them

4. **Monitor team progress:**
   - Check in on teammates periodically
   - Redirect approaches that aren't working
   - Verify work is actually complete (teammates sometimes don't mark tasks done)

### Phase 3: Quality gates (subagents — sequential)

Gate steps run sequentially after team work completes. Switch back to subagents.

1. **Test execution** — Run `/backend-test-runner` and `/frontend-test-runner` commands.
   - On failures: route to planner for fix steps, then back to coders (subagents, not team).

2. **Security review** — Spawn **security-researcher** subagent (read-only, opus).

3. **Code review** — Spawn **reviewer** subagent (read-only, opus).
   - Route feedback through planner → coders (subagents) → re-run tests.

4. **Documentation** — Spawn **documenter** subagent (haiku).

---

## Decision: when to fall back to subagents mid-workflow

If during team execution you discover:
- File domains overlap more than expected → stop team, switch to subagent dispatch
- One teammate is blocked waiting on another → route through SendMessage first, but if persistent, switch to subagents
- Shared interface contracts need heavy negotiation → may be better as sequential subagent work

---

## User interaction policy

- Present plan for approval before creating the team.
- Only ask when specs conflict irreconcilably.
- Route clarifying questions through **architect**, **ui-ux**, or **planner** only.

## What to do in your first reply

1. Confirm you have ingested all `{spec_files}`.
2. Identify whether this feature is suitable for team-based parallel implementation.
3. If suitable: begin with architect → planner → plan approval → team creation.
4. If not suitable: recommend `/feature-autopilot` instead and explain why.

**If you are about to write code or directly run tests, STOP and delegate.**
