# PHASE 6 — Native Parallelism: Modernize Swarm Dispatch

**Status:** [✅] Decisions made 2026-08-10 → executable PRD at `docs/features/native_swarm/PRD.md`. Run via `/execute-prd native_swarm docs/features/native_swarm/PRD.md`. This document remains as background/decision record.
**Created:** 2026-08-10
**Scope:** Evaluate replacing `scripts/swarm-dispatch.sh` (parallel `claude` CLI sessions in worktrees) with native background subagents using built-in worktree isolation. Agent teams usage stays as-is (still experimental; flag now enabled globally).

## Decisions (2026-08-10)

1. **End state: full retirement** of `swarm-dispatch.sh`. The user does not need per-batch cost itemization, and headless/CI runs are covered natively: a GitHub Actions step running `claude -p` (or `anthropics/claude-code-action`) is a live session for the duration of the run, and background subagents with worktree isolation work inside it. A documented CI entry point replaces the script's headless role.
2. **Spike depth: lightweight blocker spike** — verify merge semantics, task-claim exclusivity, and SendMessage recovery only; no full A/B comparison.
3. **Cost visibility: best-effort capture** — per-worker duration/turns/model in the swarm report; no dollar figures.
4. **Cloud dispatch: research note only** (`isolation: "remote"` assessment, no implementation).

## Context

`swarm-dispatch.sh` was built when parallel implementation required launching separate `claude` CLI processes. Since then, the harness gained native equivalents for most of what the script does by hand:

| swarm-dispatch.sh (custom) | Native equivalent (today) |
|---|---|
| `git worktree add` + cleanup logic | `Agent` tool `isolation: "worktree"` (auto-managed, auto-cleaned if unchanged) |
| Background processes via `&` + `wait` | Background subagents by default; harness notifies on completion — no polling |
| Complexity-based model per batch (opus/sonnet/haiku CLI flag) | `model` parameter per `Agent` call |
| `claude --resume "$SESSION_ID"` recovery | `SendMessage` to a spawned agent continues it with context intact |
| Work-stealing via agent teams inside each session | Shared native task queue (`TaskCreate`/`TaskList`/`TaskUpdate`) across parallel subagents — `coder.md` already speaks this protocol |
| Failure classification by parsing `--output-format json` | Harness reports subagent failure directly to the orchestrator |

What the script provides that native subagents do **not**:

- **Per-session cost/token JSON reporting** (`--output-format json`) — native subagent cost is not itemized back to the orchestrator.
- **Fully independent OS processes** that survive the parent session.
- **Explicit merge control** — the script owns `git merge --no-ff` of each worktree branch with dirty-tree guards and auto-commit.

## Proposed Phases

### P6.1 — Spike (no production changes)
Run one real 3-batch feature both ways and compare:
- Wall-clock time, orchestrator context growth, cost visibility.
- Failure behavior: kill one worker mid-run; compare recovery ergonomics (native: `SendMessage` continue vs script: `claude --resume`).
- **Verify merge semantics of native worktrees**: confirm how changed worktrees are surfaced for merge after the subagent completes, and that the orchestrator can merge them with the same `--no-ff` + conflict-resolution flow.

**Exit criteria:** written comparison in `docs/features/spike-native-swarm/FINDINGS.md`; go/no-go decision.

### P6.2 — Orchestrator dispatch change (if go)
- New dispatch rule: 3+ parallelizable steps → spawn N parallel background `coder` subagents, each with `isolation: "worktree"`, `model` set by batch complexity (highest complexity in batch wins), fed by a shared `TaskCreate` queue with `file_domain` and `issue_ref` metadata.
- Keep: issue creation scripts, acceptance-criteria validation, streaming review (reviewer + security-researcher in parallel), merge phase.
- Simplify tiered failure recovery: `max_turns` → respawn with upgraded model (unchanged); `infrastructure` → `SendMessage` continue instead of `claude --resume`; `launch_failure` largely disappears (harness owns worktree creation).

### P6.3 — Demote swarm-dispatch.sh to fallback

> **Superseded** (v2.6.0, feature `native_swarm`) — this section is retained as a historical record only. The script was **fully retired and deleted**, not demoted to a fallback, which is what the Decisions section above already called for. Cross-machine/CI dispatch is covered by `docs/CI_DISPATCH.md`; per-session cost JSON was explicitly dropped; and the spike (`docs/features/native_swarm/SPIKE_FINDINGS.md`) found native worktree merge semantics sufficient. The exit criterion below remains open and lands on the next feature run through the pipeline.

- Keep the script for: cross-machine/CI dispatch, runs needing per-session cost JSON, or if native worktree merge semantics prove insufficient.
- Update: `orchestrator.md` dispatch decision, `execute-prd.md`, `AGENT_TEAMS_GUIDE.md` Pattern 5, README tables.

**Exit criteria:** one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking.

## Risks & Open Questions

- [ ] **Merge semantics** — does the native worktree persist after the agent completes with changes, and where? (Blocker for P6.2 if not controllable; resolve in spike.)
- [ ] **Cost visibility** — accept reduced per-worker cost itemization, or keep script for cost-sensitive runs?
- [ ] **Parent-session lifetime** — background subagents don't survive the orchestrator session; long swarms need the orchestrator session to stay alive (script sessions had the same practical constraint since it waits synchronously — verify).
- [ ] **Queue contention** — native task claiming across parallel subagents: confirm `TaskUpdate` claim semantics prevent double-claim the way file-locking did for teams.
- [ ] **Turn budgets** — `maxTurns` in `coder.md` frontmatter applies per subagent; confirm per-complexity overrides are possible per spawn or acceptable as fixed.

## Out of Scope

- Agent teams (peer-to-peer) — keep current usage and the experimental flag; revisit if/when the feature GAs.
- `isolation: "remote"` (cloud dispatch) — interesting later, not part of this phase.
