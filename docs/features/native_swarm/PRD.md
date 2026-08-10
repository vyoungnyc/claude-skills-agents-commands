# PRD: Native Swarm Dispatch (Retire swarm-dispatch.sh)

## Problem

`scripts/swarm-dispatch.sh` (~400 lines of bash) hand-rolls parallel implementation dispatch — worktree creation, background `claude` CLI processes, per-batch model selection, JSON parsing, failure classification, and branch merging. Claude Code now provides all of this natively (background subagents, `isolation: "worktree"`, per-spawn `model`, shared task queue, `SendMessage` recovery), leaving the script as duplicated machinery that must be maintained, debugged (see CHANGELOG 2.3.3), and kept bash-3.2-compatible for no remaining benefit.

## Users

- **Primary:** the repo owner (vyoung) running `/execute-prd` features through the orchestrator on any of their machines.
- **Secondary:** the orchestrator/coder agents themselves — simpler dispatch means fewer failure modes to recover from.

## User Stories

- US-001: As the repo owner, I want 3+ parallelizable plan steps dispatched via native background subagents in isolated worktrees, so that swarm runs need no custom bash and inherit harness-level reliability.
- US-002: As the repo owner, I want worker failures recovered through native means (`SendMessage` continuation, model-upgrade respawn), so that recovery doesn't depend on parsing CLI JSON and `claude --resume`.
- US-003: As the repo owner, I want a documented GitHub Actions entry point that runs the orchestrator headlessly, so that retiring the script doesn't cost me the ability to run swarms from CI.
- US-004: As the repo owner, I want a per-worker report (duration, turns, model, steps completed) at the end of each swarm run, so that I keep visibility into how the run went without per-session cost JSON.

## Requirements

### Must Have
- REQ-001: **Lightweight blocker spike** (gate for all later steps). Run a throwaway task with 2 parallel worktree-isolated background subagents against a scratch branch of this repo.
  - AC: Written findings in `docs/features/native_swarm/SPIKE_FINDINGS.md` answering: (a) where a changed worktree's commits end up and how the orchestrator merges them into the feature branch; (b) whether two parallel subagents can claim tasks from the shared queue without double-claim; (c) whether `SendMessage` successfully continues a completed/stalled worker.
  - AC: Findings end with an explicit **GO / NO-GO** verdict. On NO-GO, remaining steps halt and the findings are escalated to the user with options.
- REQ-002: **Native dispatch in the orchestrator.** Replace the "3+ steps → `scripts/swarm-dispatch.sh`" rule in `agents/orchestrator.md` and `commands/execute-prd.md` with: 3+ parallelizable steps → N parallel background `coder` subagents, each `isolation: "worktree"`, `model` set by batch complexity (highest in batch wins), fed by a shared native task queue whose entries carry `file_domain`, `issue_ref`, and `complexity`.
  - AC: Dispatch decision tables updated in both files; batch-config JSON replaced by task-queue entries; issue creation (1.5), streaming review (Phase 3), and merge-conflict-resolution flow are unchanged.
  - AC: Failure recovery table updated: `max_turns` → respawn with upgraded model (haiku→sonnet→opus, then escalate); stalled/incomplete worker → `SendMessage` continuation; `launch_failure` and `claude --resume` rows removed; `tool_error` escalation retained.
- REQ-003: **Best-effort swarm report.** After all workers complete, the orchestrator reports per worker: batch name, model, duration, turn count (as exposed by the harness), steps completed, issues closed.
  - AC: Report format specified in `agents/orchestrator.md`; explicitly notes that per-worker cost is not itemized.
- REQ-004: **Retire `scripts/swarm-dispatch.sh`.** Delete the script and remove/replace every live reference.
  - AC: `grep -rn "swarm-dispatch" --include="*.md" --include="*.sh"` returns only CHANGELOG history entries.
  - AC: Updated: `CLAUDE.md` (dispatch bullet), `README.md` (scripts table, platform table, key-design-principles, directory structure), `docs/AGENT_TEAMS_GUIDE.md` (Pattern 5 + decision framework), `agents/orchestrator.md`, `commands/execute-prd.md`.
- REQ-005: **CI entry point.** Document headless swarm dispatch for GitHub Actions in `docs/CI_DISPATCH.md`, including a complete example workflow using `claude -p "/execute-prd <feature_id> <spec>"` with `CLAUDE_CODE_OAUTH_TOKEN` provided via repository secret, an explanation that native background subagents run inside the headless session for the duration of the `-p` invocation, and notes on permission configuration and timeouts for unattended runs.
  - AC: Example workflow YAML is complete enough to copy into `.github/workflows/` in a target project (stored in docs, not activated in this repo).
  - AC: Mentions the official `anthropics/claude-code-action` as the alternative entry point.

### Should Have
- REQ-006: README and CHANGELOG updated as v2.6.0 with the modernization summary; script count and version references corrected throughout.
- REQ-007: `agents/coder.md` reviewed against the native queue flow (it already uses TaskList/TaskGet/TaskUpdate) and adjusted only if the spike reveals claim-semantics differences.

### Could Have
- REQ-008: Research note `docs/REMOTE_DISPATCH_NOTES.md`: one page on when `isolation: "remote"` (cloud workers) would beat local worktrees, with no implementation.

### Won't Have (this phase)
- REQ-009: Remote/cloud dispatch implementation.
- REQ-010: Any change to agent teams usage or the experimental flag.
- REQ-011: Per-worker cost itemization (explicitly dropped — subscription usage makes per-session dollars notional).

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

- Does the harness expose per-subagent duration/turns in a form the orchestrator can quote in the report, or is the report limited to what the orchestrator observes (spawn/finish timestamps)? (Resolve during REQ-003; degrade gracefully.)
- Long swarm runs require the orchestrator session to stay alive; is any guidance needed in the docs about not closing the session mid-swarm? (Answer in REQ-002 docs if the spike shows it matters.)

## Risks

- Native worktree merge semantics don't fit the merge-back flow: Mitigation: REQ-001 spike is a hard gate; NO-GO halts and escalates before anything is modified.
- Self-modification hazard (the pipeline edits its own orchestrator/command files mid-run): Mitigation: workers edit files in isolated worktrees branched from the feature branch; the running session's loaded definitions don't change until merge; single batch for overlapping files.
- Reference cleanup misses a stale mention: Mitigation: REQ-004 grep acceptance criterion is checkable and binary.

## Agreement

Drafted 2026-08-10 from user-approved Phase 6 decisions (full retirement + CI entry point; lightweight spike; best-effort reporting; remote as research note only). Formal approval occurs at the `/execute-prd` PRD review gate.
This document is the contract for implementation.
All acceptance criteria will be validated before delivery.
