# Agent Teams Guide

A practical guide for using Claude Code's agent teams feature with this orchestration system.

## When to Use Agent Teams vs Subagents

Your system supports **two** multi-agent patterns. Choose based on the task:

### Use Subagents (Default — Hub-and-Spoke)

Best for the standard gated workflow: plan → implement → test → review → docs.

- Orchestrator spawns agents one at a time (or in parallel via background agents)
- Results flow back to orchestrator for routing
- Lower token cost
- Worktree isolation available for coders
- Full control over execution order and gating

**Use when:** Following PLAN_steps.md sequentially, running gated approvals, or when the orchestrator needs to enforce strict ordering.

### Use Agent Teams (Peer-to-Peer)

Best for exploratory, parallel, or collaborative work where agents benefit from direct communication.

- Team lead spawns teammates that work concurrently
- Teammates communicate directly via SendMessage
- Higher token cost (~7x standard sessions)
- Shared task list for coordination
- No worktree isolation (assign file domains instead)

**Use when:** Multiple agents need to discuss findings, challenge assumptions, or work on truly independent modules in parallel.

## Enabling Agent Teams

Add to your `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Requires Claude Code v2.1.32+ and Claude Opus 4.6 access.

## Team Patterns for This System

### Pattern 1: Parallel Module Development

When PLAN_steps.md has 2+ implementation steps with no dependencies between them and they touch different file domains.

```
Create an agent team for parallel implementation of step_id X, Y, and Z:
- Teammate 1 (backend specialist): owns src/backend/ — implements step X
- Teammate 2 (frontend specialist): owns src/frontend/ — implements step Y
- Teammate 3 (test specialist): owns tests/ — implements step Z

Each teammate completes their module with tests. Report back when done.
```

**File domain rules (critical — no worktree isolation in teams):**
- Backend teammate: `src/backend/`, `src/services/`, `src/models/`
- Frontend teammate: `src/frontend/`, `src/components/`, `src/pages/`
- Test teammate: `tests/`, `__tests__/`
- Shared files (e.g., `src/types/`, `prisma/schema.prisma`): assign to ONE teammate only

### Pattern 2: Multi-Perspective Review

When a feature touches security-sensitive code and needs deep review from multiple angles simultaneously.

```
Create a review team for the completed authentication feature:
- Security reviewer: focus on token handling, session management, OWASP Top 10
- Performance reviewer: focus on query efficiency, caching, response times
- Architecture reviewer: focus on pattern consistency, API contracts, separation of concerns

Review independently, then share findings with each other. Challenge each other's
assumptions. Produce a unified findings document.
```

**Why this is better than sequential subagent reviews:** Reviewers can challenge each other's findings in real time, reducing false positives and catching issues that emerge from cross-domain analysis.

### Pattern 3: Competing Hypotheses (Bug Investigation)

When a bug is complex and the root cause is unclear.

```
Create a team to investigate the intermittent 500 errors on /api/auth/refresh:
- Teammate 1: investigate database connection pool exhaustion
- Teammate 2: investigate race conditions in token refresh logic
- Teammate 3: investigate upstream service timeouts

Each teammate: gather evidence, form a hypothesis, share findings.
Try to disprove each other's theories. Converge on the most likely root cause.
```

### Pattern 4: Architecture Exploration

When exploring design options for a complex feature before committing to one approach.

```
Create a team to explore architectures for the real-time notification system:
- Teammate 1: design a WebSocket-based approach
- Teammate 2: design an SSE (Server-Sent Events) approach
- Teammate 3: design a polling-based approach with optimizations

Each teammate: produce a mini architecture doc with tradeoffs.
Compare approaches and recommend the best fit for our stack.
```

## How the Orchestrator Decides

The orchestrator uses this decision framework:

```
Is work sequential with strict gating?
  → YES → Use standard subagent dispatch (default)

Are there 2+ independent modules that can be built in parallel?
  → YES → Are the file domains clearly separable?
    → YES → Consider agent team (Pattern 1)
    → NO  → Use subagents with worktree isolation

Does the task benefit from agents challenging each other?
  → YES → Use agent team (Pattern 2 or 3)

Is this exploratory/design work with multiple valid approaches?
  → YES → Use agent team (Pattern 4)

Default → Use subagents
```

## Limitations and Risks

- **No worktree isolation**: teammates share the same repo. You MUST assign non-overlapping file domains.
- **No session resumption**: if a team session dies, teammates are lost. For critical work, prefer subagents.
- **Higher token cost**: ~7x standard sessions. Use teams judiciously.
- **Team size**: 3-5 teammates max for most workflows. Diminishing returns beyond 5.
- **Teammates can't spawn teams**: no nesting. Only the lead manages the team.
- **Task status can lag**: teammates sometimes don't mark tasks as complete. The lead should verify.
- **Experimental feature**: API surface may change between Claude Code versions.

## Cost Optimization

- Use **Sonnet** for most teammates (specify in the spawn prompt)
- Keep spawn prompts focused — don't dump entire context
- Clean up teams when done
- For routine gated workflows, always prefer subagents (much cheaper)
- Reserve teams for high-value scenarios: complex bugs, parallel module development, multi-perspective review

## Integration with Existing Workflow

Agent teams are an **additional pattern**, not a replacement for the orchestrator's subagent dispatch. The standard workflow remains:

1. Orchestrator receives task
2. Architect designs → Planner creates PLAN_steps.md
3. **Decision point**: orchestrator evaluates whether team or subagents are better
4. Execute via chosen pattern
5. Gate checks (tests, security, review, docs) still run regardless of pattern used

Teams integrate at step 3-4. All other workflow stages (planning, gating, documentation) continue unchanged.

### Pattern 5: Swarm Implementation (Parallel Worktree Sessions)

**When to use:** 3+ parallelizable implementation steps, want maximum throughput with automatic load balancing.

**How it works:** The orchestrator groups plan steps into domain batches (backend, frontend, infra, tests). `swarm-dispatch.sh` launches N parallel claude sessions, each in its own git worktree. Each session can use agent teams for work-stealing within its batch. Sessions run as background processes (`&` + `wait`) with `--output-format json` for structured results.

**Model selection:** Complexity-based per batch:
- `high` (novel architecture, security-critical, complex integrations) → opus, 40 turns
- `medium` (standard features, known patterns, moderate integration) → sonnet, 30 turns
- `low` (boilerplate, config, simple CRUD, well-understood patterns) → haiku, 20 turns

Model per session = max complexity in the batch (highest wins).

**GitHub integration:** Each session receives its GitHub issue numbers. Coders read acceptance criteria via `gh issue view`, validate each criterion before completing, and close issues with a commit reference: `gh issue close N -c "Fixed in abc123. All criteria met."` The orchestrator tracks progress via `gh issue list --label "feature:{id}"`.

**Merge:** `git merge --no-ff` each worktree branch back into the feature branch after all sessions complete. If conflicts occur, the orchestrator spawns a conflict-resolution session.

**Recovery:** If a session exhausts `maxTurns`, the orchestrator reads the `session_id` from JSON output and resumes via `claude --resume "session-id" -p "Continue where you left off"`. In-progress work is preserved in the worktree's commits.

**When NOT to use:**
- Fewer than 3 steps — subagents are cheaper and simpler
- Tight interdependencies between steps (one step's output is another's input)
- Heavy file overlap across batches (worktrees can't share files without conflicts)
- Steps that require human approval gates between them
