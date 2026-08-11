# TEST_SPEC — native_swarm

## Test Strategy Summary

This feature edits markdown agent/command definitions and deletes bash; no code test suite applies. Verification runs at three levels: (1) **structural checks** — grep-based, binary, runnable by any coder or the reviewer against a single file; (2) **behavioral validation** — the REQ-001 spike, which empirically answers the five dispatch-mechanics questions before any file is modified; (3) **acceptance verification** — the step_08 checklist run against the merged branch. Full 3+-batch end-to-end validation is explicitly deferred (REQ-012).

## Unit Tests (structural, per-file grep checks)

- [UT-001] Area: reference cleanup (REQ-004)
  related_requirements: ["R-004"]
  steps_or_inputs: `grep -rn "swarm-dispatch" --include="*.md" --include="*.sh"` at repo root
  expected_outcome: Hits only in CHANGELOG.md, README.md release-history bullets, `docs/features/native_swarm/**`, and `docs/PHASE_6_NATIVE_PARALLELISM.md` (2026-08-10 review round 1 amendment — allow-list restated to include README's own historical "What Changed" entries, which reference the script by name as changelog-class history, and to scope the `native_swarm` feature-doc exception to the whole `docs/features/native_swarm/` tree rather than just PRD.md). Zero hits in CLAUDE.md, AGENT_TEAMS_GUIDE.md, agents/, commands/, scripts/.

- [UT-002] Area: script deletion (REQ-004)
  steps_or_inputs: `test -f scripts/swarm-dispatch.sh; ls scripts/ | wc -l`
  expected_outcome: File absent; README `### Scripts (4)` heading matches actual script count.

- [UT-003] Area: orchestrator tool grants (REQ-002)
  steps_or_inputs: grep orchestrator.md frontmatter for `TaskCreate`, `TaskList`, `TaskUpdate`, `SendMessage`
  expected_outcome: All four present in the tools grant.

- [UT-004] Area: recovery table rows (REQ-002)
  steps_or_inputs: grep orchestrator.md + execute-prd.md for `launch_failure`, `claude --resume`, `max_turns`, `tool_error`, `SendMessage`
  expected_outcome: `launch_failure` and `claude --resume` absent; `max_turns` (model-upgrade respawn), `tool_error` (escalate), stalled→`SendMessage` present in both files.

- [UT-005] Area: merge sequence (REQ-002)
  steps_or_inputs: read orchestrator.md merge-back section against ARCHITECTURE §3.4
  expected_outcome: All 7 ordered steps present: clean-tree guard, explicit checkout, skip-failed-workers, uncommitted-changes handling (per spike (e)), no-new-commits skip, --no-ff merge, conflict→abort+record+single-resolution-session.

- [UT-006] Area: swarm report format (REQ-003)
  steps_or_inputs: read orchestrator.md report section
  expected_outcome: Per-worker fields (batch, model, duration, turns, steps, issues); failed/incomplete workers with recovery action; timestamp fallback named; "cost not itemized" note present.

- [UT-007] Area: P6.3 supersession (REQ-004)
  steps_or_inputs: grep PHASE_6_NATIVE_PARALLELISM.md for a superseded marker at §P6.3
  expected_outcome: Explicit marker present; rest of document unchanged (`git diff` shows only the marker hunk).

- [UT-008] Area: CI doc completeness (REQ-005)
  steps_or_inputs: read docs/CI_DISPATCH.md against the six REQ-005 ACs
  expected_outcome: Phase-2-only boundary + rationale; preconditions; complete YAML with `CLAUDE_CODE_OAUTH_TOKEN` via secret; maxTurns 50 note; claude-code-action mention; no workflow file added to this repo, no inline tokens anywhere (`grep -ri "sk-ant\|oauth" docs/CI_DISPATCH.md` shows only the secret reference pattern).

- [UT-009] Area: version discipline (REQ-006)
  steps_or_inputs: grep CHANGELOG.md v2.6.0 entry; grep for "~400"
  expected_outcome: v2.6.0 present in 2.5.0 style; "~400" absent; "533" used for the line count.

## Integration Tests (spike — behavioral, REQ-001)

- [IT-001] Worktree commit reachability (spike (a)) — **NO-GO gate**
  steps_or_inputs: 2 background coder subagents with isolation "worktree" off spike/native-swarm; each commits a trivial change; orchestrator locates branches and merges both
  expected_outcome: Both worker branches reachable from the main checkout; --no-ff merges succeed; commits land on spike/native-swarm.

- [IT-002] Queue double-claim safety (spike (b))
  steps_or_inputs: 2 tasks in shared queue; both workers claim concurrently
  expected_outcome: Each task claimed exactly once (owner set atomically); no task worked twice, none orphaned.

- [IT-003] SendMessage continuation (spike (c))
  steps_or_inputs: SendMessage to a completed/idle worker with a follow-up instruction
  expected_outcome: Worker resumes and acts; determines whether coder.md needs the SendMessage grant (REQ-007).

- [IT-004] Per-spawn maxTurns override (spike (d))
  steps_or_inputs: spawn coder with an explicit turn budget differing from frontmatter maxTurns: 30
  expected_outcome: Documented either way — override honored (keep 40/30/20) or not (fixed 30, docs state it).

- [IT-005] Uncommitted worktree changes (spike (e))
  steps_or_inputs: worker finishes leaving an uncommitted tracked-file edit in its worktree
  expected_outcome: Documented fate (preserved / surfaced / discarded); merge-sequence step 4 written to match; nothing silently lost.

## End-to-End Tests

- [E2E-001] Deferred (REQ-012): one full /execute-prd feature shipped through 3+-batch native dispatch with no regression in review gates or issue tracking. Lands on the **next** feature; stays open until then.

## Edge Cases & Negative Tests

- Grep AC false-pass: AGENT_TEAMS_GUIDE decision framework says "swarm dispatch (Pattern 5)" without the script name — must be verified by reading, not grep (UT-tier but manual).
- README v2.5.0 history bullet must remain untouched (negative check: `git diff README.md` contains no hunk at ~line 172).
- Issue-creation scripts, review gates, PLAN_steps format: `git diff --stat` shows no changes to create-github-issues.sh / create-local-issues.sh.
- CI doc must not cause a `.github/workflows/` directory to exist in this repo.
- Spike teardown: `git worktree list` shows one entry; `git branch --list 'spike/*'` empty.

## Out-of-Scope / Deferred Tests

- 3+-batch e2e swarm validation (REQ-012 — next feature).
- Per-worker cost assertions (REQ-011 — dropped).
- Remote dispatch behavior (REQ-009 — research note only).
- `.test.sh` siblings — no bash added.

## Responsibility

Coders run their step's UT checks before closing the issue. step_08 re-runs all UT checks on the merged branch. Reviewer (Phase 3) verifies UT-005/006/008 by reading, not grep alone.
