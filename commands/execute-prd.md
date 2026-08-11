---
name: execute-prd
description: "Execute a PRD through the full multi-agent swarm pipeline: review → plan → GitHub Issues → swarm implementation → review → PR. Invoked by /discover after PRD approval, or directly with an existing spec."
args:
  - name: feature_id
    type: string
    required: true
    description: "Short ID for the feature (e.g. AUTH_FEATURE)."
  - name: spec_files
    type: string[]
    required: true
    description: "List of spec/PRD file paths to use as primary inputs."
---

# Command: /execute-prd

You are the **Orchestrator** agent in the multi-agent Claude Code setup.

/!\ HARD RULES:

- You are a **project orchestrator only**.
- You MUST NOT write any code, pseudocode, or file diffs.
- If you catch yourself starting to "just write the code": STOP and delegate.
- ALL substantive work MUST be done by subagents, background swarm workers, or skills.

Your job is ONLY to coordinate and route work between these 8 agents and skills:
- **ui-ux**
- **architect**
- **backend-coder**
- **frontend-coder**
- **coder** (general-purpose; the swarm worker, spawned as a background subagent per batch)
- **reviewer**
- **security-researcher**

---

## Inputs

- `feature_id`: `{feature_id}`
- `spec_files`: `{spec_files}`

Your first step is to ingest all specs via file reading or MCP tools, and treat them as the authoritative description of the feature.

---

## Goal

Run the `{feature_id}` feature as a fully automated, multi-agent workflow.

By the end, the agents and skills should have:

- A clear architecture and `docs/features/{feature_id}/PLAN_steps.md`.
- A GitHub epic with child issues, all closed on completion.
- Implemented the required backend and frontend components.
- Written and passed tests (unit / integration / E2E as needed).
- Completed a security review with fixes applied.
- Completed a code review with feedback addressed.
- Updated docs and changelogs.
- A merged PR on `main` with the epic closed.

---

## Phase 0: Branch + PRD Review

### 0.1 Create feature branch
```
git checkout feature/{feature_id} 2>/dev/null || git checkout -b feature/{feature_id}
```
This is the first action — all work, commits, and worktrees branch from here.
Save `docs/features/{feature_id}/PRD.md` on this branch if a PRD was provided.

### 0.2 PRD Review Gate (if spec provided)
Spawn **architect** to review the provided spec for:
1. **Gaps**: Missing acceptance criteria, vague requirements ("make it fast"), undefined user roles, unspecified error handling, missing edge cases.
2. **Scope issues**: Too large for a single epic (>8 plan steps estimated), multiple unrelated features bundled, unclear boundaries.
3. **Ambiguity**: Requirements that could be interpreted multiple ways, conflicting requirements, unstated assumptions.
4. **Missing non-functionals**: No performance targets, no security requirements, no accessibility considerations.

**Three outcomes:**
- **PRD is clean** → proceed to Phase 1.
- **Minor gaps** → present gaps to user, collect answers inline, architect updates PRD, proceed to Phase 1.
- **Major gaps or scope issues** → stop, report findings, redirect user to `/discover {feature_id}` for structured refinement before proceeding.

Do not proceed to Phase 1 until the PRD review resolves.

---

## Phase 1: Requirements & Design

### 1.1 Ingest specs and extract requirements
- Read all `{spec_files}` (already ingested as PRD if from `/discover`).
- Invoke `extract-requirements-from-ticket` skill to produce a structured requirements list.
- Summarize: main phases, key components, constraints, edge cases.

### 1.2 Architecture
- Spawn **architect** subagent.
- For UI-heavy features, architect consults **ui-ux** first.
- Architect returns a concise architecture document saved to `docs/features/{feature_id}/ARCHITECTURE.md`.

### 1.3 Plan
- Invoke `derive-plan-from-spec` skill with the new required fields per step:
  - `file_domain`: glob patterns this step touches
  - `acceptance_criteria`: checkable list from spec requirements
  - `batch_hint`: suggested swarm grouping (e.g., "backend", "frontend", "infra", "tests")
  - `complexity`: `high` | `medium` | `low` (drives model selection; the turn budget is fixed — see Phase 2)
- Output: `docs/features/{feature_id}/PLAN_steps.md`.

### 1.4 Test strategy
- Invoke `derive-test-spec-from-requirements` skill.
- Output: a test spec that coders will implement alongside their feature code.

### 1.5 Create Epic + Issues

**Auto-detect platform:** Check if `gh` CLI is authenticated and the remote is GitHub:
```
if gh auth status &>/dev/null && git remote get-url origin 2>/dev/null | grep -q github; then
  # GitHub repo → create GitHub issues
  scripts/create-github-issues.sh {feature_id} <plan_steps_json>
else
  # Non-GitHub (GitLab, local, etc.) → create local file-based issues
  scripts/create-local-issues.sh {feature_id} <plan_steps_json>
fi
```

**GitHub path:** Creates epic (tracking issue) + child issues on GitHub. Each child issue body: acceptance criteria checkboxes, file domain, complexity, dependencies.

**Local path (GitLab / non-GitHub):** Creates `plans/{feature_id}/issue-0000.md` (epic) + `issue-0001.md` through `issue-NNNN.md` (one per step). Files have frontmatter with status, complexity, domain. `plans/` is auto-added to `.gitignore`.

Both scripts output the same JSON shape: `{"epic": ..., "issues": {"step_01": ..., "step_02": ...}}` — store this mapping. The rest of the pipeline works identically regardless of platform.

### 1.6 User approval (REQUIRED — mandatory gate)
Present a summary to the user via `AskUserQuestion`:
- Architecture highlights
- Plan steps with `file_domain`, `complexity`, and `batch_hint` per step
- Test strategy overview
- If GitHub: epic link + issue links
- If local: path to `plans/{feature_id}/` with issue files

**Do not proceed to Phase 2 until the user explicitly approves.**

If the user requests changes:
- Invoke `update-plan-from-review-feedback` skill.
- Update `PLAN_steps.md`.
- Re-run step 1.5 (update GitHub issues to match).
- Repeat this approval checkpoint.

---

## Phase 2: Implementation (swarm)

Analyze plan steps for parallelizability. Group steps with no cross-dependencies into domain batches using `batch_hint` and `file_domain`.

**Dispatch decision:**
```
Parallelizable coder steps:
  1 step      → single subagent (backend-coder or frontend-coder, worktree)
  2 steps     → parallel subagents (worktree isolation each)
  3+ steps    → native swarm: one background coder subagent per domain batch
```

### Single subagent (1 step)
Spawn `backend-coder` or `frontend-coder` via Agent tool with worktree isolation.
Pass: step_id, PLAN_steps.md snippet, test spec, GitHub issue number.

### Parallel subagents (2 steps)
Spawn both coders concurrently via Agent tool; each gets worktree isolation.
Each coder: reads their GitHub issue for acceptance criteria, implements, closes issue on completion.

### Native swarm dispatch (3+ steps)

**Build the tracking queue**, grouping steps by `batch_hint` and `file_domain`. `TaskCreate` one entry per step, each carrying `file_domain`, `issue_ref`, and `complexity`:

```
Task "step_01"  file_domain: ["src/api/**"]   issue_ref: 43  complexity: high
Task "step_03"  file_domain: ["src/db/**"]    issue_ref: 45  complexity: high
Task "step_05"  file_domain: ["src/jobs/**"]  issue_ref: 47  complexity: medium
Task "step_02"  file_domain: ["web/**"]       issue_ref: 44  complexity: medium
Task "step_04"  file_domain: ["web/styles/**"] issue_ref: 46 complexity: low
```

This queue is **orchestrator-side tracking only** — spawned workers cannot see the Task tools, so it is the progress ledger, not the workers' work list. Steps whose `file_domain` overlaps must land in the **same** batch and be sequenced there, never split across parallel workers.

Model per batch = highest complexity in the batch:
- `complexity: high` → `model: opus`
- `complexity: medium` → `model: sonnet`
- `complexity: low` → `model: haiku`

**Turn budget is fixed.** The Agent tool has no per-spawn turn parameter, so `agents/coder.md`'s frontmatter `maxTurns: 30` applies to every worker regardless of complexity. Complexity selects the model and nothing else; high-complexity batches run on 30 turns rather than the 40 they used to get, which makes `max_turns` recovery more likely — keep batches small.

**Spawn one background `coder` subagent per batch** via the Agent tool: `isolation: "worktree"`, `run_in_background: true`, `model` per the mapping above. Each spawn prompt must:
1. **Pre-assign the batch's steps inline** — step IDs in execution order, file domain, issue numbers, and acceptance criteria in the prompt text itself.
2. Start with `git merge feature/{feature_id} --no-edit` and verify it. Native worktrees are cut from `origin/main`, **not** from the dispatching branch, so workers otherwise cannot see feature-branch state at all.
3. Instruct the worker to commit every change — uncommitted work does not merge — and to close each issue once its criteria are met.

Monitor via `TaskList` / `TaskUpdate` as workers report; the harness notifies on completion, so do not poll.

**Merge-back** is orchestrator-owned and follows the sequence in `agents/orchestrator.md` ("Post-swarm merge-back"): clean-tree guard → explicit feature-branch checkout → skip failed/incomplete workers → skip absent branches → salvage dirty worktrees before removal → skip no-new-commit branches → `git merge --no-ff worktree-agent-<id>`.

**If merge conflicts occur:** spawn a single conflict-resolution session to resolve them before proceeding.

**Dependent batches** (steps with dependencies on the above): run as a second swarm round after the first merges cleanly.

**Failure recovery (tiered):** Before respawning, `TaskUpdate` the abandoned tasks to reset `owner` and `status` — a task still `in_progress` under a dead worker will be skipped by its replacement.

| Failure | Action |
|---|---|
| `max_turns` | Upgrade model (haiku→sonnet→opus) and respawn with the same pre-assigned context. If already opus, escalate to user. |
| Stalled / incomplete worker | `SendMessage` continuation — **only while the worker's worktree still exists**. After a clean completion tore the worktree down, respawn a fresh worker instead. |
| `tool_error` | Escalate to user immediately — unrecoverable without human input. |
| `context_overflow` | Respawn with opus (1M context). If already opus, escalate to user. |

**Swarm report:** after all workers settle, report per worker — batch, model, duration, turns, steps completed, issues closed, and outcome/recovery — covering failed and incomplete workers too. If the harness exposes no duration/turn metrics, use observed spawn/finish timestamps and mark turns `unavailable`. Cost is not itemized.

---

## Phase 3: Quality Gates (parallel)

After merge-back lands all worker branches on `feature/{feature_id}`, invoke `summarize-diff-for-agents` skill, then spawn in parallel:

- **reviewer**: structured code review, checking each GitHub issue's acceptance criteria against the implementation.
- **security-researcher**: structured security audit with severities.

Both are read-only. Collect both outputs before proceeding.

**If blocking issues found:**
1. Invoke `update-plan-from-review-feedback` skill to produce fix steps.
2. Reopen relevant GitHub issues with a comment explaining what failed.
3. Dispatch a new swarm batch for only the fix steps.
4. Re-run Phase 3 after fixes are applied.

---

## Phase 4: Documentation

- Invoke `sync-docs-with-implementation` skill.
- Update `docs/features/{feature_id}/` with final architecture, API contracts, and changelog entry.
- Verify all GitHub child issues are closed before proceeding to Phase 5.

---

## Phase 5: Push, PR/MR, and Close Epic

### 5.1 Ask the user

Before pushing, ask via `AskUserQuestion`:

```
Implementation is complete, all reviews passed, docs are updated.

Ready to push feature/{feature_id} to origin and create a PR/MR?
- If GitHub: I'll push and create a PR via `gh pr create`
- If GitLab: I'll push and create an MR via `glab mr create`
- If you'd prefer to handle this manually, I'll just push the branch

What would you like to do?
```

### 5.2 Push feature branch
```
git push -u origin feature/{feature_id}
```

### 5.3 Create PR or MR (based on user response and platform)

**Auto-detect platform:**
```bash
if gh auth status &>/dev/null && git remote get-url origin 2>/dev/null | grep -q github; then
  # GitHub → create PR
  gh pr create --title "feat({feature_id}): {summary}" --body "..."
elif glab auth status &>/dev/null && git remote get-url origin 2>/dev/null | grep -q gitlab; then
  # GitLab → create MR
  glab mr create --title "feat({feature_id}): {summary}" --description "..."
else
  # Neither → just push, user handles PR/MR manually
  echo "Branch pushed. Create your PR/MR manually."
fi
```

**PR/MR body must include:**
- Link to epic (GitHub issue link or `plans/` reference)
- List of all closed child issues / completed issue files
- Summary of changes
- Test plan

The PR/MR does **not** close the epic — epic stays open until the PR/MR is reviewed, approved, and merged.

### 5.4 Post-review

If PR/MR review (human or automated) finds issues:
- GitHub: invoke `/pr-fix-loop {pr_number}` to address feedback
- GitLab: invoke `/mr-fix-loop {mr_iid}` to address feedback

### 5.5 Close epic on merge

After PR/MR is approved and merged:
- GitHub: `gh issue close {epic_N} -c "Shipped in PR #{pr_number}"`
- GitLab: update `plans/{feature_id}/issue-0000.md` frontmatter to `status: closed`
- Both: report final summary to user

---

## User interaction policy

- Phase 0.2 (PRD review): present gaps and wait for resolution before continuing.
- Phase 1.6 (plan approval): present plan + epic/issue links and wait for explicit approval.
- Only ask again when specs conflict irreconcilably or a blocker cannot be resolved autonomously.
- Route clarifying questions through **architect** or **ui-ux** only.

---

## What to do in your first reply

1. Confirm you have ingested all `{spec_files}`.
2. State that you are beginning Phase 0 (Branch + PRD Review).
3. Create the feature branch, then immediately spawn **architect** for the PRD review gate.

**If you are about to write code or directly run tests, STOP and delegate.**
