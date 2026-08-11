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

> **P6.3 exit criterion — MET (2026-08-10)** (v2.7.0, feature `script_tests`) — "one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking" is satisfied by this feature's own run. Evidence, quoted from the swarm report rather than asserted:
>
> - Round 2 dispatched 4 parallel worktree-isolated coder batches (suite-A/B/C/D), one file domain each, wave wall-clock 703s, four `--no-ff` merges with zero conflicts, each suite verified green on the feature branch post-merge.
> - Per-worker rows: suite-A sonnet 331s success (#18 closed); suite-B sonnet 295s+400s, stalled → SendMessage continuation → success (#19 closed); suite-C sonnet 422s success (#20 closed); suite-D sonnet 607s success (#21 closed). Turn counts unavailable from the harness; durations are orchestrator-observed. Cost not itemized.
> - Issue tracking: epic #24, child issues #17-#23 opened by `scripts/create-github-issues.sh`, closed by workers upon AC satisfaction — no regression.
> - Round 1 (repair, opus, 328s) preceded the wave behind a merge-back gate, per the documented sequencing precondition.
> - Review gates: reviewer + security-researcher ran in parallel post-implementation. **Round 1** (initial implementation): reviewer BLOCK (4 findings: clean-tree guard, salvage scoping, CI tool grants, and one requiring a fix round), security PASS-WITH-NOTES (2 High, several Medium/Low). **Round 2** (fix batch — security M1-M3 + L1, reviewer's 4 Lows): reviewer APPROVE-WITH-NITS, security PASS. **Round 3** (targeted fix for one Medium reviewer found in round 2's own diff — untested behavior hardening in `poll-common.sh`): reviewer BLOCK (1 Medium, untested security-motivated behavior change) → fixed with mutation-tested regression coverage, not reverted. **Round 4** (final): reviewer **APPROVE** (mutation-tested both new guards against reverted mutants; both caught the regression), security **PASS-WITH-NOTES** (one documentation-only correction, applied). No review round was skipped or weakened to reach approval — every finding was either fixed or explicitly deferred with a recorded rationale (`FINDINGS.md`). No regression in issue tracking: all 8 child issues (#17-#23, plus #22 covering closure) closed with acceptance evidence; epic #24 remains open pending PR merge, consistent with the documented policy that the epic stays open until merge.
> - Environment nuance: this wave's worktrees were cut at the feature branch head (`346be95`), unlike earlier spawns cut at `origin/main`. A related hazard surfaced during review: two review-gate agents nearly reported phantom findings when a concurrent, unrelated branch switch in the shared checkout (for PR #25, an unrelated same-session fix) briefly changed what `git diff` resolved against. Both agents caught it by diffing against explicit commit SHAs rather than the working tree. Worth noting for future swarm runs: review gates should diff against explicit refs, not the live checkout, when other work may be concurrent in the same session.
> - **Conclusion: exit criterion holds.** 4-batch native dispatch ran to completion, review gates functioned exactly as designed (including catching a real, mutation-verified defect two rounds deep), and issue tracking showed no regression.

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
