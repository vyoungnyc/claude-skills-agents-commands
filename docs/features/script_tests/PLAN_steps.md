# PLAN_steps — script_tests

**Source of truth for progress.** Contract: `PRD.md` (889eb3d). Design: `ARCHITECTURE.md`.

## Plan Summary

Test suites for the four untested scripts, plus the REQ-000 repair of the live-broken `scripts/lib/poll-common.sh` (DC-04). Three dispatch rounds: (1) the repair alone, merged back and verified on the feature branch **before** anything else spawns (sequencing precondition — worker worktrees only see feature state via their opening merge); (2) **four parallel worktree-isolated batches, one per test file** — the P6.3 validation payload; (3) a sequenced closure step for every overlapping file (runner, FINDINGS, README, CHANGELOG, conditional §P6.3 closure), then orchestrator verification. Key risks: the 4-batch dispatch failing to fire (structural constraint: no shared helper library), scope creep into the scripts under test (REQ-013 boundary; DEF-4/5 report-only), and test pollution of the real repo (temp-repo sandboxes, run-unique pidfile ids).

## Detailed Steps

- `step_id`: "script_tests.step_01_repair_poll_common"
  title: "REQ-000: repair poll-common.sh (DEF-1 subshell count, DEF-2 jq pattern, DEF-3 empty-array trap)"
  primary_agent: "backend-coder"
  dependencies: []
  related_requirements: ["REQ-000"]
  status: "pending"
  file_domain: ["scripts/lib/poll-common.sh", "scripts/poll-pr-reviews.sh", "scripts/poll-mr-reviews.sh"]
  acceptance_criteria:
    - "All seven REQ-000 ACs met verbatim (PRD lines 40-47): three defects fixed, call sites updated, bash-3.2 safe, no contract change, DEF-4/5 untouched"
    - "Merged back to feature/script_tests and verified present BEFORE round 2 spawns"
  batch_hint: "prereq" (round 1, alone — sequencing precondition)
  complexity: "high"

- `step_id`: "script_tests.step_02_test_create_github"
  title: "REQ-001: scripts/create-github-issues.test.sh"
  primary_agent: "coder"
  dependencies: []
  related_requirements: ["REQ-001", "REQ-009"]
  status: "pending"
  file_domain: ["scripts/create-github-issues.test.sh"]
  acceptance_criteria:
    - "All REQ-001 ACs met verbatim (PRD lines 49-57), incl. DEF-4 documented at the assertion site"
    - "Suite prints exercised exit codes (REQ-009); self-contained, no shared helpers"
  batch_hint: "suite-A" (round 2, parallel wave)
  complexity: "medium"

- `step_id`: "script_tests.step_03_test_create_local"
  title: "REQ-002: scripts/create-local-issues.test.sh"
  primary_agent: "coder"
  dependencies: []
  related_requirements: ["REQ-002", "REQ-009"]
  status: "pending"
  file_domain: ["scripts/create-local-issues.test.sh"]
  acceptance_criteria:
    - "All REQ-002 ACs met verbatim (PRD lines 59-69), incl. temp-git-repo isolation + repo .gitignore self-check and DEF-5 documented"
    - "Suite prints exercised exit codes (REQ-009); self-contained"
  batch_hint: "suite-B" (round 2, parallel wave)
  complexity: "medium"

- `step_id`: "script_tests.step_04_test_poll_pr"
  title: "REQ-003: scripts/poll-pr-reviews.test.sh (full contract 0/1/2/3/10/11)"
  primary_agent: "coder"
  dependencies: ["step_01"]
  related_requirements: ["REQ-003", "REQ-009"]
  status: "pending"
  file_domain: ["scripts/poll-pr-reviews.test.sh"]
  acceptance_criteria:
    - "All REQ-003 ACs met verbatim (PRD lines 71-83), incl. per-call fixtures, pidfile safety, run-unique ids, exit-4 omission comment"
    - "Suite prints exercised exit codes (REQ-009); self-contained"
  batch_hint: "suite-C" (round 2, parallel wave — requires step_01 merged)
  complexity: "medium"

- `step_id`: "script_tests.step_05_test_poll_mr"
  title: "REQ-004: scripts/poll-mr-reviews.test.sh (full contract 0/1/2/3/4/10/11)"
  primary_agent: "coder"
  dependencies: ["step_01"]
  related_requirements: ["REQ-004", "REQ-009"]
  status: "pending"
  file_domain: ["scripts/poll-mr-reviews.test.sh"]
  acceptance_criteria:
    - "All REQ-004 ACs met verbatim (PRD lines 85-97), incl. temp-repo + fake origin, concurrent-safe stub, both-remote-forms slug, approval-before-discussions ordering"
    - "Suite prints exercised exit codes (REQ-009); self-contained"
  batch_hint: "suite-D" (round 2, parallel wave — requires step_01 merged)
  complexity: "medium"

- `step_id`: "script_tests.step_06_closure"
  title: "REQ-005/006/007/008/010: runner, FINDINGS, README/CHANGELOG v2.7.0, conditional §P6.3 closure, hook extension"
  primary_agent: "backend-coder"
  dependencies: ["step_02", "step_03", "step_04", "step_05"]
  related_requirements: ["REQ-005", "REQ-006", "REQ-007", "REQ-008", "REQ-009", "REQ-010"]
  status: "pending"
  file_domain: ["scripts/run-tests.sh", "docs/features/script_tests/FINDINGS.md", "README.md", "CHANGELOG.md", "docs/PHASE_6_NATIVE_PARALLELISM.md", "hooks/auto-test-runner.sh"]
  acceptance_criteria:
    - "run-tests.sh per REQ-005 (discovery without hardcoded list, bash <file> invocation, per-suite isolation, summary, green on branch)"
    - "FINDINGS.md per REQ-006 (Repaired: DEF-1/2/3 w/ REQ-000 SHA; Open: DEF-4/5 + worker findings + coverage gaps)"
    - "README/CHANGELOG per REQ-008 (v2.7.0, Testing subsection, Scripts (5), breakage stated plainly)"
    - "§P6.3 closure per REQ-007 ONLY with orchestrator-supplied evidence (4-batch swarm report + gate verdicts); appended below the Superseded note"
    - "REQ-010 (could-have): auto-test-runner.sh invokes run-tests.sh on *.sh edits"
  batch_hint: "closure" (round 3, single sequenced worker)
  complexity: "medium"

- `step_id`: "script_tests.step_07_verification"
  title: "Final verification: run-tests green, AC checklist, dispatch-validation evidence"
  primary_agent: "orchestrator"
  dependencies: ["step_06"]
  related_requirements: ["all"]
  status: "pending"
  file_domain: []
  acceptance_criteria:
    - "bash scripts/run-tests.sh green on the merged feature branch; output quoted"
    - "Every PRD AC checked; exit-code coverage compared per REQ-009"
    - "Hermeticity: git status --porcelain identical before/after the test run"
    - "Dispatch validation: swarm report shows 4 parallel batches; gates and issue tracking show no regression (feeds REQ-007)"
  batch_hint: "verification" (round 3, orchestrator-run)
  complexity: "low"

## Dispatch Rounds (Phase 2 mapping)

| Round | Steps | Workers | Model |
|---|---|---|---|
| 1 | step_01 (prereq) | 1 subagent, worktree | opus (high) |
| — | **gate: step_01 merged to feature/script_tests, fix verified present** | orchestrator | — |
| 2 | step_02 · step_03 · step_04 · step_05 | **4 parallel subagents, worktree isolation — the 3+ dispatch path (P6.3 payload)** | sonnet each (medium) |
| 3 | step_06 (closure) → step_07 (verification) | 1 subagent, then orchestrator | sonnet |

## Risks & Assumptions

Carried from PRD Risks (lines 170-177): 4-batch must genuinely fire (REQ-007 conditional); no worker touches its script under test (REQ-013); REQ-000 invisible-to-wave hazard (round-1 gate above); temp-repo sandboxes mandatory; stub drift accepted; timing assertions target counters, not wall-clock.
