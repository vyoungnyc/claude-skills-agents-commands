# PRD: Native Swarm Dispatch (Retire swarm-dispatch.sh)

## Problem

`scripts/swarm-dispatch.sh` (533 lines of bash) hand-rolls parallel implementation dispatch — worktree creation, background `claude` CLI processes, per-batch model selection, JSON parsing, failure classification, and branch merging. Claude Code now provides all of this natively (background subagents, `isolation: "worktree"`, per-spawn `model`, shared task queue, `SendMessage` recovery), leaving the script as duplicated machinery that must be maintained, debugged (see CHANGELOG 2.3.3), and kept bash-3.2-compatible for no remaining benefit.

## Users

- **Primary:** the repo owner (vyoung) running `/execute-prd` features through the orchestrator on any of their machines.
- **Secondary:** the orchestrator/coder agents themselves — simpler dispatch means fewer failure modes to recover from.

## User Stories

- US-001: As the repo owner, I want 3+ parallelizable plan steps dispatched via native background subagents in isolated worktrees, so that swarm runs need no custom bash and inherit harness-level reliability.
- US-002: As the repo owner, I want worker failures recovered through native means (`SendMessage` continuation, model-upgrade respawn), so that recovery doesn't depend on parsing CLI JSON and `claude --resume`.
- US-003: As the repo owner, I want a documented GitHub Actions entry point that runs the **implementation phase** headlessly against an already-approved plan, so that retiring the script doesn't cost me the ability to run swarms from CI while the human approval gates stay interactive.
- US-004: As the repo owner, I want a per-worker report (duration, turns, model, steps completed) at the end of each swarm run, so that I keep visibility into how the run went without per-session cost JSON.

## Requirements

### Must Have
- REQ-001: **Lightweight blocker spike** (gate for all later steps). Run a throwaway task with 2 parallel worktree-isolated background subagents against the scratch branch `spike/native-swarm` in this repo.
  - AC: Written findings in `docs/features/native_swarm/SPIKE_FINDINGS.md` answering:
    - (a) where a changed worktree's commits end up and how the orchestrator merges them into the feature branch;
    - (b) whether two parallel subagents can claim tasks from the shared queue without double-claim;
    - (c) whether `SendMessage` successfully continues a completed/stalled worker;
    - (d) whether a spawn can override the agent's frontmatter `maxTurns` (i.e. whether per-complexity turn budgets survive), or whether `coder.md`'s fixed budget applies to every worker;
    - (e) what happens to **uncommitted** changes left in a native worktree when the subagent finishes — are they preserved, surfaced, or discarded? (`swarm-dispatch.sh` auto-committed with `git add -u` specifically to stop this data loss; see CHANGELOG 2.3.2.)
  - AC: Findings end with an explicit **GO / NO-GO** verdict. On NO-GO, remaining steps halt and the findings are escalated to the user with options.
  - AC: Spike teardown — the `spike/native-swarm` branch and every worktree it created are removed before the step is marked done (`git worktree list` and `git branch --list 'spike/*'` come back clean).
- REQ-002: **Native dispatch in the orchestrator.** Replace the "3+ steps → `scripts/swarm-dispatch.sh`" rule in `agents/orchestrator.md` and `commands/execute-prd.md` with: 3+ parallelizable steps → N parallel background `coder` subagents, each `isolation: "worktree"`, `model` set by batch complexity (highest in batch wins), fed by a shared native task queue whose entries carry `file_domain`, `issue_ref`, and `complexity`.
  - AC: Dispatch decision tables updated in both files; batch-config JSON replaced by task-queue entries; issue creation (1.5), streaming review (Phase 3), and merge-conflict-resolution flow are unchanged.
  - AC: Failure recovery table updated: `max_turns` → respawn with upgraded model (haiku→sonnet→opus, then escalate); stalled/incomplete worker → `SendMessage` continuation; `launch_failure` and `claude --resume` rows removed; `tool_error` escalation retained.
  - AC: **Turn budget is stated explicitly.** Today complexity maps to both a model and a turn budget (opus/40, sonnet/30, haiku/20) in `commands/execute-prd.md`, `docs/AGENT_TEAMS_GUIDE.md`, and the script constants; the `max_turns` recovery row presumes a budget still exists. Per REQ-001(d), either document the per-spawn override that preserves the per-complexity budgets, or state plainly that `agents/coder.md`'s fixed `maxTurns: 30` now applies to every worker and that high-complexity batches drop from 40 turns to 30.
  - AC: **Tool grants match the design.** `agents/orchestrator.md` frontmatter gains `TaskCreate`, `TaskList`, `TaskUpdate` (to build and monitor the shared queue) and `SendMessage` (recovery + report gathering). It currently grants only `Read, Write, Edit, Grep, Glob, Bash, Agent, AskUserQuestion`, none of which can drive a task queue.
  - AC: **Post-swarm merge sequence is documented** in `agents/orchestrator.md`, covering what `swarm-dispatch.sh` used to own: the clean-working-tree guard before merging, checkout of the feature branch, skipping merge for failed/incomplete workers so partial work never lands, the no-new-commits skip, and the handling for uncommitted worktree changes determined by REQ-001(e).
- REQ-003: **Best-effort swarm report.** After all workers complete, the orchestrator reports per worker: batch name, model, duration, turn count (as exposed by the harness), steps completed, issues closed.
  - AC: Report format specified in `agents/orchestrator.md`; explicitly notes that per-worker cost is not itemized.
  - AC: The report covers **failed and incomplete workers**, not just successful ones — each with its failure mode and the recovery action taken (model upgrade respawn, `SendMessage` continuation, or escalation).
  - AC: Named fallback when the harness exposes no duration/turn metrics — the orchestrator reports its own observed spawn and finish timestamps and marks turn count as unavailable, rather than omitting the row.
- REQ-004: **Retire `scripts/swarm-dispatch.sh`.** Delete the script and remove/replace every live reference.
  - AC: `grep -rn "swarm-dispatch" --include="*.md" --include="*.sh"` returns only: `CHANGELOG.md`, `README.md` release-history bullets, `docs/features/native_swarm/**` (this PRD and its sibling feature docs), and `docs/PHASE_6_NATIVE_PARALLELISM.md` (the decision record). *(Amended 2026-08-10, review round 1 — restated from the original wording, which named only "this PRD" instead of the whole feature-doc tree, and omitted README's own historical release-history bullets; the underlying grep command and pass/fail intent are unchanged.)* Any other hit is a miss to fix.
  - AC: Updated: `CLAUDE.md` (dispatch bullet), `README.md` (scripts table, platform table, key-design-principles, directory structure), `docs/AGENT_TEAMS_GUIDE.md` (Pattern 5 + decision framework — note the framework says "swarm dispatch (Pattern 5)" without the literal script name, so grep will not catch it), `agents/orchestrator.md`, `commands/execute-prd.md`.
  - AC: `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3 ("Demote swarm-dispatch.sh to fallback" / "keep the script for cross-machine/CI dispatch") is marked **superseded** — it contradicts the full-retirement decision recorded in that same document's Decisions section. The document otherwise stays as a historical record.
  - AC: Out of scope for cleanup — `README.md` line ~172, the v2.5.0 "What Changed" bullet naming the Phase 6 doc. It is changelog-class history and stays as written, like the CHANGELOG entries.
- REQ-005: **CI entry point — implementation phase only.** Document headless swarm dispatch for GitHub Actions in `docs/CI_DISPATCH.md`. The headless run covers the **implementation phase against an already-approved `PLAN_steps.md`** (the equivalent of `/execute-prd` Phase 2 onward); it does not run discovery, planning, or the approval gates.
  - AC: The doc states the boundary explicitly and says why: `/execute-prd` contains blocking `AskUserQuestion` gates at Phase 1.6 (plan approval) and Phase 5.1 (push/PR approval), plus the Phase 0.2 PRD review gate, and `agents/orchestrator.md` Rule 1 forbids starting implementation without explicit plan approval. Those gates stay interactive and are presumed already satisfied before CI is invoked. CI must not auto-answer them.
  - AC: Documented preconditions for a CI run: feature branch exists, `PLAN_steps.md` is present and user-approved, and epic/child issues already created.
  - AC: Complete example workflow using `claude -p` to dispatch the implementation phase, with `CLAUDE_CODE_OAUTH_TOKEN` provided via repository secret; explains that native background subagents run inside the headless session for the duration of the `-p` invocation, and covers permission configuration and timeouts for unattended runs.
  - AC: Notes the orchestrator's `maxTurns: 50` budget as a practical ceiling on how much of the pipeline one headless invocation can carry.
  - AC: Example workflow YAML is complete enough to copy into `.github/workflows/` in a target project (stored in docs, not activated in this repo).
  - AC: Mentions the official `anthropics/claude-code-action` as the alternative entry point.

### Should Have
- REQ-006: README and CHANGELOG updated as v2.6.0 with the modernization summary; script count and version references corrected throughout.
  - AC: Includes the `### Scripts (5)` section heading in `README.md`, which becomes `### Scripts (4)` once the script is deleted.
  - AC: CHANGELOG entry does not repeat the "~400 lines" figure — the script is 533 lines.
- REQ-007: `agents/coder.md` reviewed against the native queue flow (it already uses TaskList/TaskGet/TaskUpdate) and adjusted if the spike reveals **either** claim-semantics differences **or** tool-grant gaps.
  - AC: Specifically, `coder.md` currently grants `Read, Edit, Write, Grep, Glob, Bash, TaskList, TaskGet, TaskUpdate, mcp__context7, mcp__chunkhound` — no `SendMessage`. Confirm via REQ-001(c) whether a worker can acknowledge and act on a `SendMessage` continuation without that grant; add it if not.

### Could Have
- REQ-008: Research note `docs/REMOTE_DISPATCH_NOTES.md`: one page on when `isolation: "remote"` (cloud workers) would beat local worktrees, with no implementation.

### Won't Have (this phase)
- REQ-009: Remote/cloud dispatch implementation.
- REQ-010: Any change to agent teams usage or the experimental flag.
- REQ-011: Per-worker cost itemization (explicitly dropped — subscription usage makes per-session dollars notional).
- REQ-012: **End-to-end validation of a real 3+-batch native swarm.** This feature's own steps touch `orchestrator.md`, `execute-prd.md`, and `README.md`, which the Technical Constraints require to be batched or sequenced — leaving only two or three parallelizable batches. It therefore cannot exercise the 3+ dispatch path it introduces. The `PHASE_6 P6.3` exit criterion ("one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking") lands on the **next** feature run through the pipeline, not this one, and stays open until then.

## Technical Constraints

- Must not change: issue-creation scripts (`create-github-issues.sh`, `create-local-issues.sh`), review gates (reviewer + security-researcher in parallel), plan approval gates, PLAN_steps.md format.
- `agents/coder.md` remains the swarm worker definition; its task-queue work loop is the contract the dispatch must feed.
- All commits via conventional-commits (enforced by hook; use `git commit -F -` heredoc form — the hook cannot parse multi-line `-m`).
- Steps editing `orchestrator.md`, `execute-prd.md`, and `README.md` have overlapping file domains — they must be batched together or sequenced, not parallelized across workers.

## Existing Patterns to Follow

- Dispatch decision tables: `agents/orchestrator.md` §4 and `commands/execute-prd.md` Phase 2 — keep the same table/format style when replacing content.
- Failure recovery: tiered table format in both files.
- Docs: README component tables + `docs/AGENT_TEAMS_GUIDE.md` pattern sections.
- Version discipline: CHANGELOG entries follow the 2.5.0 style (grouped, bolded change titles with rationale).
- Testing: this repo verifies docs changes by grep (no test suite for md); shell changes carry a `.test.sh` sibling (see `hooks/enforce-git-conventions.test.sh`) — not expected to be needed here since bash is being deleted, not added.

## Non-Functional Requirements

- Performance: native dispatch should not regress wall-clock time vs the script for a 3-batch run (spike gives a rough baseline; no hard target).
- Security: no new credentials in repo; CI docs must use repository secrets, never inline tokens.
- Accessibility: n/a (docs and agent definitions only).

## Open Questions

- Does the harness expose per-subagent duration/turns in a form the orchestrator can quote in the report? (Resolve during REQ-003. Fallback is now fixed rather than open: orchestrator-observed spawn/finish timestamps, turn count marked unavailable.)
- Long swarm runs require the orchestrator session to stay alive; is any guidance needed in the docs about not closing the session mid-swarm? (Answer in REQ-002 docs if the spike shows it matters; also relevant to the REQ-005 CI timeout guidance.)

## Risks

- Native worktree merge semantics don't fit the merge-back flow: Mitigation: REQ-001 spike is a hard gate; NO-GO halts and escalates before anything is modified.
- Self-modification hazard (the pipeline edits its own orchestrator/command files mid-run): Mitigation: workers edit files in isolated worktrees branched from the feature branch; the running session's loaded definitions don't change until merge; single batch for overlapping files.
- Reference cleanup misses a stale mention: Mitigation: REQ-004 grep acceptance criterion is checkable and binary.

## Agreement

Drafted 2026-08-10 from user-approved Phase 6 decisions (full retirement + CI entry point; lightweight spike; best-effort reporting; remote as research note only).

Revised 2026-08-10 at the `/execute-prd` PRD review gate (architect review returned MINOR GAPS; user resolved all eight inline). Decisions applied: CI covers the implementation phase only against an already-approved plan — human gates stay interactive; turn-budget, tool-grant, and merge-sequence acceptance criteria made explicit; spike scope extended to turn-budget overrides and uncommitted-worktree handling with a named scratch branch and teardown; the grep criterion restated to a passable form; 3+-batch validation deferred to the next feature.
This document is the contract for implementation.
All acceptance criteria will be validated before delivery.
