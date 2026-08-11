# TEST_SPEC — script_tests

## Test Strategy Summary

This feature's deliverables ARE tests, so the spec is thin by design: the four suites' case-level detail lives in the PRD's ACs (REQ-001…REQ-004 enumerate every case, fixture behavior, and assertion), and `scripts/run-tests.sh` (REQ-005) is the executable verification step. What this spec adds is the meta-level checks that the suites themselves can't express.

## Verification Levels

1. **Executable** — `bash scripts/run-tests.sh` green on the feature branch (all 5 suites: the 4 new + the existing hook test). This is the primary gate for step_07 and the review gates.
2. **Structural (grep/inspection)**
   - [UT-001] No shared test-helper library: `ls scripts/lib/` contains only `poll-common.sh`; no `test-helper`/`common` sourcing in any `*.test.sh` (each suite self-contained — the P6.3 structural constraint).
   - [UT-002] Each suite ends by printing its exercised exit codes (REQ-009); compare against documented sets: create-*: 0/1/10 · poll-pr: 0/1/2/3/10/11 · poll-mr: 0/1/2/3/4/10/11. Gaps listed in FINDINGS.md.
   - [UT-003] REQ-000 scope check: `git log --oneline` for step_01 touches only poll-common.sh + the two call-site lines; no diff to documented exit codes/JSON keys/CLI args.
   - [UT-004] REQ-013 boundary: `git diff` for steps 02-05 touches ONLY the four new `*.test.sh` files — zero changes to the scripts under test.
   - [UT-005] FINDINGS.md: Repaired (DEF-1/2/3 + REQ-000 SHA + covering test) vs Open (DEF-4/5 + any worker findings) structure per REQ-006.
   - [UT-006] §P6.3 closure present ONLY alongside quoted 4-batch evidence; Superseded note preserved above it (REQ-007).
   - [UT-007] Version surfaces: CHANGELOG v2.7.0 in 2.6.0 style stating the pre-release poll breakage plainly; README Testing subsection, Scripts (5), version 2.7.0 (REQ-008).
3. **Hermeticity** — `git status --porcelain` byte-identical before/after a full `run-tests.sh` run; repo `.gitignore` untouched (REQ-002's self-check); no stray `plans/` dirs in the repo.
4. **Meta (the P6.3 payload)** — the orchestrator's swarm report for round 2 shows 4 parallel worktree batches with per-worker rows; reviewer + security gates ran in parallel post-implementation; all issues tracked open→closed correctly. This evidence feeds REQ-007's conditional closure and is quoted, not asserted.

## Timing / Determinism Checks

- Full run < ~60s (poll suites pin `poll_interval_sec=1`, `max_polls ≤ 4`).
- Two consecutive runs produce identical PASS/FAIL output.
