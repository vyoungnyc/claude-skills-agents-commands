# PLAN_steps — native_swarm

**Source of truth for progress.** Contract: `PRD.md` (20c668b). Design: `ARCHITECTURE.md` (eb51f0a).

## Plan Summary

Retire `scripts/swarm-dispatch.sh` and re-express its dispatch stage as native background subagents. The plan runs in three dispatch rounds: (1) the REQ-001 spike alone — a hard gate whose NO-GO halts everything; (2) two parallel workers — one owning the overlapping core-docs sequence (`orchestrator.md`, `execute-prd.md`, `README.md`, cleanup, version bump), one owning the independent new-file docs (`CI_DISPATCH.md`, `REMOTE_DISPATCH_NOTES.md`, `coder.md` review); (3) final grep verification. Key risks: worktree merge semantics (spike-gated), self-modification of the running pipeline's own definitions (mitigated by worktree isolation + single batch for overlapping files), and silent loss of the script's merge guards (mitigated by delete-last ordering — the script survives until §3.4 lands in `orchestrator.md`).

## Phases

1. Spike gate — validate native dispatch mechanics (REQ-001)
2. Core rewrite — dispatch/recovery/merge/report in agent + command definitions (REQ-002, REQ-003)
3. Retirement — reference cleanup, script deletion, version bump (REQ-004, REQ-006)
4. Independent docs — CI entry point, remote-dispatch note, coder review (REQ-005, REQ-007, REQ-008)
5. Verification — binary grep AC + PRD acceptance checklist

## Steps (Canonical Flow)

Implementation → grep-based verification (this repo's md "test suite") → security review + code review (Phase 3 gates) → documentation (inherent — this feature *is* docs) → release notes (v2.6.0).

## Detailed Steps

- `step_id`: "native_swarm.step_01_spike"
  title: "Blocker spike: native dispatch mechanics on spike/native-swarm"
  primary_agent: "orchestrator" (spawns 2 worktree-isolated background coder subagents; observes; writes findings)
  dependencies: []
  related_requirements: ["R-001"]
  definition_of_done: |
    - [ ] 2 parallel worktree-isolated background subagents ran a throwaway task against scratch branch `spike/native-swarm`
    - [ ] `docs/features/native_swarm/SPIKE_FINDINGS.md` answers (a) worktree commit location + merge path, (b) queue double-claim safety, (c) SendMessage continuation, (d) per-spawn maxTurns override, (e) uncommitted worktree changes
    - [ ] Explicit GO / NO-GO verdict; on NO-GO all later steps halt and findings escalate to user
    - [ ] Teardown: `git worktree list` and `git branch --list 'spike/*'` clean
    - [ ] Rough wall-clock baseline noted for NFR comparison
  status: "pending"
  file_domain: ["docs/features/native_swarm/SPIKE_FINDINGS.md"]
  acceptance_criteria:
    - "SPIKE_FINDINGS.md exists with answers to (a)-(e), each tied to the design element it decides"
    - "GO / NO-GO verdict is explicit and final line of the doc"
    - "Spike branch and worktrees removed"
  batch_hint: "spike" (round 1, runs alone — hard gate)
  complexity: "medium"

- `step_id`: "native_swarm.step_02_core_dispatch_rewrite"
  title: "Rewrite dispatch, recovery, merge sequence, report in orchestrator.md + execute-prd.md"
  primary_agent: "backend-coder"
  dependencies: ["step_01"]
  related_requirements: ["R-002", "R-003"]
  definition_of_done: |
    - [ ] Dispatch decision tables in both files: 3+ steps → N background coder subagents, isolation "worktree", model by batch complexity (highest wins), fed by native task queue (entries carry file_domain, issue_ref, complexity)
    - [ ] Batch-config JSON replaced by task-queue entries; issue creation (1.5), Phase 3 review, merge-conflict flow untouched
    - [ ] Failure table: max_turns → model-upgrade respawn (haiku→sonnet→opus, then escalate); stalled → SendMessage continuation; launch_failure + claude --resume rows removed; tool_error escalation kept; owner/status reset before respawn documented (ARCHITECTURE §3.3)
    - [ ] Turn-budget source stated per spike answer (d)
    - [ ] orchestrator.md frontmatter gains TaskCreate, TaskList, TaskUpdate, SendMessage
    - [ ] Post-swarm merge sequence documented per ARCHITECTURE §3.4 incl. spike answer (e) handling
    - [ ] Swarm report format specified per ARCHITECTURE §3.5 (failed workers + recovery action; timestamp fallback; cost not itemized)
    - [ ] Existing table/section formatting preserved (content swap, not restructure)
  status: "pending"
  file_domain: ["agents/orchestrator.md", "commands/execute-prd.md"]
  acceptance_criteria:
    - "All REQ-002 ACs met verbatim (PRD lines 32-36)"
    - "All REQ-003 ACs met verbatim (PRD lines 38-40)"
    - "No reference to swarm-dispatch.sh remains in either file"
  batch_hint: "core-docs" (round 2, worker A — sequenced within batch)
  complexity: "high"

- `step_id`: "native_swarm.step_03_retire_script"
  title: "Delete swarm-dispatch.sh; clean all live references; mark P6.3 superseded"
  primary_agent: "backend-coder"
  dependencies: ["step_02"]  # delete-last: script is the only record of merge guards until step_02 lands
  related_requirements: ["R-004"]
  definition_of_done: |
    - [ ] `scripts/swarm-dispatch.sh` deleted
    - [ ] CLAUDE.md dispatch bullet rewritten to native dispatch
    - [ ] README.md updated: scripts table, platform table, key-design-principles, directory structure
    - [ ] AGENT_TEAMS_GUIDE.md: Pattern 5 rewritten; decision framework updated (grep won't catch it — listed explicitly)
    - [ ] PHASE_6_NATIVE_PARALLELISM.md §P6.3 marked superseded; doc otherwise untouched
    - [ ] README v2.5.0 history bullet (~line 172) left as written
  status: "pending"
  file_domain: ["scripts/swarm-dispatch.sh", "CLAUDE.md", "README.md", "docs/AGENT_TEAMS_GUIDE.md", "docs/PHASE_6_NATIVE_PARALLELISM.md"]
  acceptance_criteria:
    - "grep -rn 'swarm-dispatch' --include='*.md' --include='*.sh' returns only CHANGELOG, PRD.md, PHASE_6_NATIVE_PARALLELISM.md"
    - "P6.3 carries an explicit superseded marker"
  batch_hint: "core-docs" (round 2, worker A — after step_02)
  complexity: "medium"

- `step_id`: "native_swarm.step_04_version_bump"
  title: "README + CHANGELOG v2.6.0 modernization entry"
  primary_agent: "backend-coder"
  dependencies: ["step_03"]  # README overlap with step_03 → same worker, sequenced
  related_requirements: ["S-001 (REQ-006)"]
  definition_of_done: |
    - [ ] CHANGELOG v2.6.0 entry in 2.5.0 style (grouped, bolded titles with rationale)
    - [ ] README `### Scripts (5)` → `### Scripts (4)`; script count/version refs corrected throughout
    - [ ] CHANGELOG states 533 lines, never "~400"
  status: "pending"
  file_domain: ["README.md", "CHANGELOG.md"]
  acceptance_criteria:
    - "Both REQ-006 ACs met (PRD lines 56-57)"
  batch_hint: "core-docs" (round 2, worker A — after step_03)
  complexity: "low"

- `step_id`: "native_swarm.step_05_ci_dispatch_doc"
  title: "docs/CI_DISPATCH.md — headless implementation-phase entry point"
  primary_agent: "backend-coder"
  dependencies: ["step_01"]
  related_requirements: ["R-005"]
  definition_of_done: |
    - [ ] Boundary stated + why: Phase-2-only; gates 0.2/1.6/5.1 stay interactive, must not be auto-answered
    - [ ] Preconditions: feature branch exists, PLAN_steps.md approved, epic + issues created
    - [ ] Complete copyable workflow YAML: `claude -p` with CLAUDE_CODE_OAUTH_TOKEN from repo secret; permission config + timeouts for unattended runs; background subagents live inside the -p invocation
    - [ ] orchestrator maxTurns: 50 ceiling noted
    - [ ] anthropics/claude-code-action mentioned as alternative
    - [ ] No workflow activated in this repo; no credentials anywhere
  status: "pending"
  file_domain: ["docs/CI_DISPATCH.md"]
  acceptance_criteria:
    - "All six REQ-005 ACs met verbatim (PRD lines 47-52)"
  batch_hint: "independent-docs" (round 2, worker B)
  complexity: "medium"

- `step_id`: "native_swarm.step_06_coder_review"
  title: "Review agents/coder.md against native queue flow; adjust per spike"
  primary_agent: "backend-coder"
  dependencies: ["step_01"]
  related_requirements: ["S-002 (REQ-007)"]
  definition_of_done: |
    - [ ] coder.md work loop verified against task-queue dispatch contract
    - [ ] SendMessage grant added iff spike answer (c) shows continuation requires it
    - [ ] maxTurns handling consistent with spike answer (d) and step_02's turn-budget statement
    - [ ] If no change needed, recorded as reviewed-no-change in the issue
  status: "pending"
  file_domain: ["agents/coder.md"]
  acceptance_criteria:
    - "coder.md consistent with spike findings (c)/(d); REQ-007 AC met (PRD line 59)"
  batch_hint: "independent-docs" (round 2, worker B)
  complexity: "low"

- `step_id`: "native_swarm.step_07_remote_notes"
  title: "docs/REMOTE_DISPATCH_NOTES.md — research note (could-have)"
  primary_agent: "backend-coder"
  dependencies: ["step_01"]
  related_requirements: ["S-003 (REQ-008)"]
  definition_of_done: |
    - [ ] One page: when isolation "remote" (cloud workers) beats local worktrees
    - [ ] No implementation, no config changes
  status: "pending"
  file_domain: ["docs/REMOTE_DISPATCH_NOTES.md"]
  acceptance_criteria:
    - "REQ-008 satisfied; explicitly marked as research note"
  batch_hint: "independent-docs" (round 2, worker B)
  complexity: "low"

- `step_id`: "native_swarm.step_08_grep_verification"
  title: "Final verification: grep AC + PRD acceptance checklist"
  primary_agent: "orchestrator" (binary check; substantive review happens in Phase 3 gates)
  dependencies: ["step_02", "step_03", "step_04", "step_05", "step_06", "step_07"]
  related_requirements: ["R-004", "all"]
  definition_of_done: |
    - [ ] `grep -rn "swarm-dispatch" --include="*.md" --include="*.sh"` → only CHANGELOG, PRD, PHASE_6 doc
    - [ ] Every PRD AC checked off against the merged feature branch
    - [ ] Wall-clock comparison vs spike baseline noted (NFR, soft target)
  status: "pending"
  file_domain: []
  acceptance_criteria:
    - "Grep AC passes exactly as restated in PRD line 42"
    - "AC checklist appended to PLAN_steps.md or issue comments"
  batch_hint: "verification" (round 3, orchestrator-run)
  complexity: "low"

## Dispatch Rounds (Phase 2 mapping)

| Round | Steps | Workers | Model |
|---|---|---|---|
| 1 | step_01 (spike) | orchestrator + 2 spike subagents | sonnet |
| 2 | worker A: step_02 → step_03 → step_04 (core-docs, sequenced) · worker B: step_05, step_06, step_07 (independent-docs) | 2 parallel subagents, worktree isolation | A: opus (highest = high) · B: sonnet (highest = medium) |
| 3 | step_08 (verification) | orchestrator | — |

Round 2 is 2 parallelizable units → per the dispatch decision table this is the **2-step parallel-subagent path**, not the 3+ swarm path (consistent with REQ-012: this feature cannot exercise the 3+ path it introduces).

## Risks & Assumptions

- **Spike NO-GO on (a)** halts rounds 2–3; escalate with findings and options (per REQ-001 AC).
- **Assumption:** spike answers (b)-(e) cost doc revisions only (ARCHITECTURE §4 fallbacks), absorbed into step_02/step_06 before round 2 dispatches.
- **Self-modification:** worker A edits the running pipeline's own definitions — isolated in its worktree; loaded definitions unchanged until merge.
- **Delete-last invariant:** step_03 depends on step_02 so the merge guards are never undocumented.
