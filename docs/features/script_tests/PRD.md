# PRD: Test Suites for the Four Untested Scripts (`script_tests`)

## Problem

Four of the repo's five shell scripts have no tests: `scripts/create-github-issues.sh` (306 lines), `scripts/create-local-issues.sh` (212), `scripts/poll-pr-reviews.sh` (129), and `scripts/poll-mr-reviews.sh` (132), plus their shared `scripts/lib/poll-common.sh` (94). Only `hooks/enforce-git-conventions.sh` has a `.test.sh` sibling. These four scripts publish a contract — documented exit codes `0/1/2/3/4/10/11` and a JSON output shape that `/execute-prd`, `/pr-fix-loop`, and `/mr-fix-loop` parse — and nothing verifies it.

The cost is already realized, not hypothetical. A 20-minute investigation while drafting this PRD found **three live defects** in the polling path (see Existing Defects below), one of which makes both poll scripts abort on their first poll iteration under every configuration. The scripts have been shipped, documented in README, and referenced by two commands in that state.

Separately, this feature is the **validation vehicle for `PHASE_6 §P6.3`**. The `native_swarm` PRD's REQ-012 deferred end-to-end validation of the 3+-batch native dispatch path to "the next feature" because its own steps had overlapping file domains. Four independent test files are four genuinely non-overlapping domains, so this feature can exercise the dispatch path that `native_swarm` built but could not test.

## Users

- **Primary:** the repo owner (vyoung), who relies on these scripts inside `/execute-prd` and the fix-loop commands and currently has no signal when one breaks.
- **Secondary:** the orchestrator and coder agents, which branch on these scripts' exit codes — a wrong exit code silently misroutes the workflow.
- **Tertiary:** this feature's own swarm run, which is the evidence for the P6.3 exit criterion.

## User Stories

- US-001: As the repo owner, I want each of the four scripts to have a self-contained `.test.sh` sibling that runs offline, so that a regression in exit codes or JSON shape fails loudly instead of misrouting a workflow.
- US-002: As the repo owner, I want one command that runs every `*.test.sh` in the repo, so that verification is a single step rather than four invocations I have to remember.
- US-003: As the repo owner, I want defects found while writing tests recorded as findings rather than fixed inline, so that the test-writing batches stay independent and a script change never rides in unreviewed on a test commit.
- US-004: As the repo owner, I want this feature's run to dispatch 4 parallel batches and close the P6.3 exit criterion, so that native swarm dispatch is validated by real work instead of by a spike.

## Existing Defects (found during PRD discovery — context, not scope)

Verified on bash 3.2.57 / jq 1.7.1 by running the scripts against stub `gh` executables. These shape the acceptance criteria below and are the reason REQ-000 exists.

- **DEF-1 (blocker, `scripts/lib/poll-common.sh:64-79`)** — `find_new_ids` sets `_NEW_COUNT` but is always called as `NEW_IDS=$(find_new_ids ...)`, so the assignment happens in a command-substitution subshell and never reaches the caller. Under `set -u` the next line (`poll-pr-reviews.sh:92`, `poll-mr-reviews.sh:90`) dies with `_NEW_COUNT: unbound variable`. **Both poll scripts therefore abort on poll iteration 1 with exit 1 and no JSON on stdout, always.** Exit codes 1, 2, 3, and 4 are unreachable in the current code.
- **DEF-2 (`scripts/lib/poll-common.sh:18`)** — `BASE_BOT_PATTERNS` interpolates `\[bot\]$` into a jq program *inside a JSON string literal*; `\[` is not a valid JSON escape, so jq exits with two compile errors on every poll. Bot-emoji approval (exit 0) cannot fire on either script.
- **DEF-3 (`scripts/lib/poll-common.sh:20-27`)** — `"${_CLEANUP_PATHS[@]}"` on an empty array under bash 3.2 + `set -u` is an unbound-variable error. Every early exit that precedes the first `register_cleanup` call (all usage errors) prints a spurious error from the EXIT trap.
- **DEF-4 (minor, `scripts/create-github-issues.sh:74` vs `:97`)** — `jq` is invoked at line 74, twenty-three lines before the `command -v jq` guard at line 97. With jq absent the script exits 10 ("Plan steps file is not valid JSON") instead of the documented 1 with "jq not found"; the guard is dead code.
- **DEF-5 (cosmetic, `scripts/create-local-issues.sh:83` vs `:87`)** — `mkdir -p "$PLANS_DIR"` runs before JSON validation, so an invalid plan-steps file leaves an empty `plans/<feature_id>/` directory behind on the exit-10 path.

All three `poll-common.sh` defects sit in **one file** that is not any test file's domain, which is what makes REQ-000 a clean sequenced prerequisite rather than a scope explosion.

## Requirements

### Must Have

- REQ-000: **Repair `scripts/lib/poll-common.sh` (DEF-1, DEF-2, DEF-3) as a sequenced prerequisite.** *Conditional — inclusion pending the user card in Open Questions.* Without it, REQ-003 and REQ-004 cannot assert exit codes 0/1/2/3/4 against a passing suite, and the repo standard "all tests must pass before merge" cannot hold.
  - AC: `find_new_ids` returns the new-ID count to its caller without relying on a subshell assignment (e.g. return the count on a separate line, or have callers compute it from the captured output); both call sites updated to match.
  - AC: `BASE_BOT_PATTERNS` produces a jq program that compiles — verified by a test that feeds a `[bot]`-suffixed login through the approval path and gets exit 0.
  - AC: The EXIT trap is a no-op when `_CLEANUP_PATHS` is empty (bash 3.2 safe), verified by a usage-error invocation producing clean stderr.
  - AC: Confined to `scripts/lib/poll-common.sh` plus the two `_NEW_COUNT` call-site lines. No other behavior change; no change to any documented exit code or JSON key.
  - AC: If the user declines this requirement, REQ-003 and REQ-004 drop to their reduced form (stated inline there) and DEF-1/2/3 move to REQ-006 as findings only.

- REQ-001: **`scripts/create-github-issues.test.sh`** — self-contained suite for `create-github-issues.sh`, using a stub `gh` executable placed first on `PATH`. No network.
  - AC: Happy path — two plan steps, stub `gh` returning issue URLs; asserts exit 0 and that stdout parses as JSON with `.epic` a number and `.issues` an object whose keys are exactly the input `step_id`s mapped to numbers. (Output is multi-line pretty JSON; assertions go through `jq`, never string equality.)
  - AC: Exit 10 exercised four ways — no arguments; plan-steps file missing; plan-steps file not valid JSON; plan-steps array empty. Each asserts the `.error` message on stderr.
  - AC: Exit 1 exercised — `gh` absent from `PATH`; `gh auth status` failing; repo undeterminable (`GH_REPO` unset and `gh repo view` returning empty).
  - AC: Exit 1 with partial output — stub fails only the epic creation (title prefix `Epic:`); asserts stdout is JSON with `.epic == null`, `.issues` still populated from the successful child issues, and a string `.error`.
  - AC: Partial child failure — stub fails one of two child issues; asserts exit 0, the failed step's key present with value `null`, and the epic body containing a `(failed)` task-list line.
  - AC: Unparseable epic URL — stub returns a URL with no `issues/<n>` segment; asserts exit 0 with `.epic == null` and a string `.epic_url`.
  - AC: `GH_REPO` honored — asserts the stub was invoked with `--repo` matching `GH_REPO` and that `gh repo view` was never called (stub records its argv to a log file).
  - AC: Documents DEF-4 at the assertion site: with jq absent the script exits **10**, not the documented 1. The test asserts observed behavior and carries a comment naming DEF-4; it does not assert the aspirational contract.

- REQ-002: **`scripts/create-local-issues.test.sh`** — self-contained suite for `create-local-issues.sh`. No `gh`/`glab` involvement; the only external dependency is `jq`.
  - AC: **Every invocation runs inside a throwaway `git init` directory under the test's own temp dir.** The script does `cd "$(git rev-parse --show-toplevel)"` and appends to `.gitignore`; a test that runs it from this repo would write into the repo. This isolation is a hard requirement, and the suite must assert that the real repo's `.gitignore` is untouched by its own run.
  - AC: Happy path — asserts exit 0; stdout parses as JSON with `.epic == "plans/<feature_id>/issue-0000.md"` and `.issues` mapping each `step_id` to `plans/<feature_id>/issue-NNNN.md` with 4-digit zero padding in step order.
  - AC: File contents — `issue-0001.md` has YAML front matter with `step_id`, `title`, `status: open`, `complexity`, `domain`, `feature`, `created`; acceptance criteria rendered as `- [ ]` lines; a step with an empty `acceptance_criteria` array renders the `(no acceptance criteria defined)` placeholder.
  - AC: YAML escaping — a title containing an apostrophe (e.g. `It's a test`) is emitted as `'It''s a test'`.
  - AC: Epic file — `issue-0000.md` contains `type: epic`, the step count, one task-list line per step linking the child file, and the four quality-gate checkboxes.
  - AC: Overwrite protection — a second run over the same `plans/<feature_id>/` exits **1** with the "Issue files already exist" error and leaves the existing files byte-identical; the same run with `FORCE_OVERWRITE=1` exits 0 and rewrites them.
  - AC: Exit 10 exercised — no arguments; plan-steps file missing; invalid JSON; empty array.
  - AC: `SKIP_GITIGNORE` — with it unset in a fresh repo whose `.gitignore` lacks `plans/`, the file gains a `plans/` entry; with `SKIP_GITIGNORE=1` the file is unchanged. Also covers the no-`.gitignore`-yet branch (file created).
  - AC: Optional roadmap file — present and valid renders a `## Roadmap` table in the epic; absent renders no roadmap section; malformed roadmap JSON still exits 0 with the section omitted.
  - AC: Documents DEF-5 at the assertion site: the invalid-JSON exit-10 path leaves an empty `plans/<feature_id>/` behind. Asserted as observed behavior with a comment naming DEF-5.

- REQ-003: **`scripts/poll-pr-reviews.test.sh`** — self-contained suite for `poll-pr-reviews.sh`, using a stub `gh` on `PATH` that returns canned GraphQL fixtures. No network, no long sleeps.
  - AC: All invocations use `poll_interval_sec=1` and `max_polls` ≤ 4, so the whole suite's sleeping is bounded by a few seconds.
  - AC: The stub returns **different fixtures per call** (call counter in a temp file), so "new thread appears on poll 2" is expressible.
  - AC: Exit 0 (`APPROVED`) — a `THUMBS_UP` reaction from a login matching the bot pattern (both a `[bot]`-suffixed login and `cursor-bugbot`); asserts stdout JSON has `.status == "APPROVED"`, a numeric `.poll`, and a non-empty `.approvers`. *(Requires REQ-000/DEF-2.)*
  - AC: Exit 1 (`NEW_COMMENTS`) — snapshot has one unresolved thread, poll 2 returns that thread plus a new one; asserts `.status == "NEW_COMMENTS"`, `.count == 1`, and `.threads[0]` carrying `id`, `author`, `path`, `line`, `body`, `created`, with only the *new* thread present. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 2 (`IDLE_TIMEOUT`) — empty fixtures for `max_polls` iterations; asserts `.status == "IDLE_TIMEOUT"`, `.polls_completed == max_polls`, `.total_seconds == max_polls * poll_interval`. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 3 (`BLOCKED_ON_HUMAN`) — the same unresolved thread returned every poll; asserts the exit fires on the poll where `stale_polls` reaches `BLOCKED_THRESHOLD` (3) and not earlier, with `.threads` non-empty. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 10 — missing arguments; `poll_interval_sec` of `0`, `-1`, and `abc`; same for `max_polls`. Asserts the `must be a positive integer` error and (post-REQ-000) that stderr carries no unbound-variable noise from the EXIT trap.
  - AC: Exit 11 (`SNAPSHOT_FAILURE`) — stub returns empty output, and separately a GraphQL error object with no `.data.repository.pullRequest`.
  - AC: Transient API failure is survived, not fatal — stub returns garbage on poll 1 and a valid approval on poll 2; asserts exit 0 and that the run logged the retry line.
  - AC: PID file — asserts `/tmp/poll-pr-reviews-<owner>-<name>-<pr>.pid` exists during the run and is removed on exit; and that a pidfile holding a **live process the test itself spawned** (`sleep 30 &`) results in that process being killed and the message logged. The suite must never signal a PID it did not create.
  - AC: Test isolation — every invocation uses a unique synthetic `owner/repo` and PR number (e.g. derived from `$$`), so the suite never collides with a real polling run's pidfile or with a parallel test run. (Note: the pidfile path is hardcoded to `/tmp` and does not honor `TMPDIR`; record as a finding under REQ-006, do not change.)
  - AC: Exit 4 is **not** asserted — `PIPELINE_FAILED` is GitLab-only and unreachable here. The suite states this in a comment so the omission reads as deliberate.
  - AC: **Reduced form if REQ-000 is declined:** exercise only exits 10 and 11 plus the pidfile and isolation criteria; replace each blocked AC with an assertion of the *observed* broken behavior (exit 1, empty stdout, `_NEW_COUNT: unbound variable` on stderr), each commented with its DEF id. The suite still passes; it documents a bug instead of a contract.

- REQ-004: **`scripts/poll-mr-reviews.test.sh`** — self-contained suite for `poll-mr-reviews.sh`, using a stub `glab` on `PATH`. No network.
  - AC: **Every invocation runs inside a throwaway `git init` directory with a fake `origin` remote**, because the script derives `PROJECT_SLUG` from `git remote get-url origin`.
  - AC: Slug derivation covered for both remote forms — `https://gitlab.com/group/sub/proj.git` and `git@gitlab.com:group/sub/proj.git` — asserting the resulting pidfile name in each case (`.git` stripped, `/` → `-`).
  - AC: The stub `glab` dispatches on the API path (`discussions`, `pipelines`, `approvals`, `award_emoji`) and returns per-call fixtures; the script fetches four endpoints in parallel and `wait`s, so the stub must be safe under concurrent invocation (distinct output files per endpoint).
  - AC: Exit 0 via native approval — `approvals.json` with `approved: true`, and separately `approvals_left: 0`; asserts `.status == "APPROVED"`, `.gate == "native_approval"`, and `.approved_by` populated.
  - AC: Exit 0 via award emoji — `thumbsup` from a bot-pattern username including the GitLab-specific `gitlab-duo` and `gitlab-code-review`; asserts `.gate == "award_emoji"`. *(Requires REQ-000/DEF-2.)*
  - AC: Exit 1 (`NEW_COMMENTS`) — a new resolvable, unresolved discussion on poll 2; asserts `.count`, and `.discussions[0]` with `id`, `author`, `path`, `line`, `body`, `created`, including the null-`path`/null-`line` case when `position` is absent. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 4 (`PIPELINE_FAILED`) — latest pipeline `status: failed` with an `id` differing from the startup snapshot; asserts `.pipeline_id` and `.pipeline_status`. Also asserts the negative: a `failed` pipeline whose id **equals** the snapshot id does not exit 4. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 2 and exit 3 covered with the same semantics as REQ-003, including the `BLOCKED_THRESHOLD` boundary. *(Requires REQ-000/DEF-1.)*
  - AC: Exit 10 — missing `mr_iid`; non-positive-integer `mr_iid`, `poll_interval_sec`, `max_polls`.
  - AC: Exit 11 — empty or non-JSON discussions snapshot.
  - AC: Ordering — approval is checked before discussions, so a fixture with *both* an approval and a new discussion exits 0, not 1.
  - AC: Same pidfile, uniqueness, and timing criteria as REQ-003, and the same **reduced form if REQ-000 is declined**.

- REQ-005: **`scripts/run-tests.sh` — the repo's test entry point**, and this feature's verification step.
  - AC: Discovers every `*.test.sh` under the repo (currently `hooks/` and `scripts/`) without a hardcoded list, so a new suite is picked up by existing.
  - AC: Invokes each suite as `bash <file>`, not as an executable — `hooks/enforce-git-conventions.test.sh` is mode `644` today and would otherwise be skipped or fail.
  - AC: Runs each suite in its own working directory context and does not let one suite's failure stop the others; prints one `PASS`/`FAIL` line per suite plus a final `N passed, M failed` summary.
  - AC: Exits 0 only when every suite passes; non-zero otherwise. Exits non-zero with a clear message if `jq` is unavailable.
  - AC: `bash scripts/run-tests.sh` is green on the feature branch before the review gates run, and its output is quoted in the PLAN's verification step.
  - AC: bash 3.2 compatible — no `mapfile`, no associative arrays, no `${var,,}`.

- REQ-006: **`docs/features/script_tests/FINDINGS.md`** — defects observed but deliberately not fixed.
  - AC: Contains DEF-1 through DEF-5 above (minus any repaired under REQ-000, which move to a "Repaired" section citing the commit), plus any new defect a worker finds while writing its suite.
  - AC: Each entry: file and line, observed behavior, expected behavior per the script's own documentation, reproduction command, and severity.
  - AC: Written in the final sequenced step from the workers' reports — it is a shared file and must not be edited by parallel workers.

- REQ-007: **P6.3 closure (conditional, per DC-03).** The feature's final step marks the `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3 exit criterion — "one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking" — as **MET**, dated, with this run's swarm report and gate verdicts as evidence.
  - AC: Recorded **only if** this feature's own run genuinely dispatched 3+ parallel batches (here: 4, one per test file) and showed no regression in the review gates or issue tracking. If the run fell back to fewer batches or a gate regressed, the criterion stays open and the reason is recorded instead.
  - AC: The evidence is quoted, not asserted — batch count, per-worker rows from the swarm report, and the reviewer/security-researcher verdicts.
  - AC: §P6.3's existing **Superseded** note is preserved; the closure is appended below it, not written over it.

- REQ-008: **README and CHANGELOG updated as v2.7.0.**
  - AC: CHANGELOG v2.7.0 entry in the 2.6.0 style (grouped, bolded change titles with rationale), covering the four suites, the runner, the findings, and the P6.3 closure.
  - AC: README gains a **Testing** subsection: how to run everything (`bash scripts/run-tests.sh`), the convention that a shell file's tests live beside it as `<name>.test.sh`, and the offline/stub rule.
  - AC: README `### Scripts (4)` becomes `### Scripts (5)` with a `run-tests.sh` row; the version line at README:5 goes to 2.7.0.
  - AC: If REQ-000 landed, the CHANGELOG says plainly that both poll scripts were broken in every configuration before this release and names the fix.

### Should Have

- REQ-009: **Documented-exit-code coverage is stated, not assumed.** Each suite ends by printing which exit codes it exercised, and the PLAN's verification step compares that against the script's documented set (`create-*`: 0, 1, 10; `poll-pr`: 0, 1, 2, 3, 10, 11; `poll-mr`: 0, 1, 2, 3, 4, 10, 11).
  - AC: Any documented code not exercised is listed in FINDINGS.md with the reason (e.g. exit 4 is unreachable in `poll-pr-reviews.sh`).

### Could Have

- REQ-010: `hooks/auto-test-runner.sh` extended to invoke `scripts/run-tests.sh` when a `*.sh` file is edited, so suites run automatically on edit.

### Won't Have (this phase)

- REQ-011: CI workflow activation in this repo. `docs/CI_DISPATCH.md` stays documentation; no `.github/workflows/` file is added or enabled.
- REQ-012: Integration tests that call the real GitHub or GitLab APIs. Every external binary is stubbed; a test that needs credentials is out of scope by construction.
- REQ-013: Rewriting or refactoring the four scripts under test. Behavior changes to `create-github-issues.sh`, `create-local-issues.sh`, `poll-pr-reviews.sh`, and `poll-mr-reviews.sh` are out of scope; defects are reported via REQ-006. The only exception under consideration is REQ-000's narrow repair of the shared `scripts/lib/poll-common.sh`, which is a separate file from all four.
- REQ-014: Bash coverage instrumentation (`kcov`, `bashcov`). Coverage is evidenced by enumerated exit codes and branches (REQ-009), not by a percentage from a tool.
- REQ-015: Tests for `hooks/*.sh` other than the one already covered, and for `scripts/lib/poll-common.sh` as a unit. The lib is exercised through the two poll suites.

## Technical Constraints

- **Four independent file domains, one per suite** — `scripts/create-github-issues.test.sh`, `scripts/create-local-issues.test.sh`, `scripts/poll-pr-reviews.test.sh`, `scripts/poll-mr-reviews.test.sh`. This is a **structural requirement, not an incidental property**: the feature exists partly to fire the 3+ dispatch path in `agents/orchestrator.md`, so the plan must decompose into at least 4 parallel batches, one per file.
- **No shared test-helper library.** A common `scripts/lib/test-helpers.sh` would turn four independent domains into four workers editing one file, destroying the property above and the validation it provides. Each suite is self-contained and duplicates its own `fail`/`assert` helpers and stub scaffolding, matching `hooks/enforce-git-conventions.test.sh`. Deduplication is a candidate for a later feature, once the suites exist and the runner can prove nothing broke.
- **Overlapping domains must be sequenced or orchestrator-owned:** `README.md`, `CHANGELOG.md`, `docs/PHASE_6_NATIVE_PARALLELISM.md`, `docs/features/script_tests/FINDINGS.md`, and `scripts/run-tests.sh` are a single final step. `scripts/lib/poll-common.sh` (REQ-000) is a single prerequisite step that must complete before the two poll suites start.
- **Workers run in worktrees cut from `origin/main`** and must begin with `git merge feature/script_tests --no-edit` — see the dispatch patterns in `agents/orchestrator.md` §4 and its "Post-swarm merge-back (orchestrator-owned)" sequence; do not re-derive the mechanics.
- **bash 3.2 (macOS `/bin/bash`)** — no `mapfile`, `declare -A`, `${var^^}`, or `&>>`. Note that `set -u` plus empty-array expansion is an error on 3.2 (this is DEF-3); test code must not repeat the pattern.
- **Offline and deterministic** — no test may reach the network. `gh` and `glab` are stubbed by prepending a temp dir to `PATH`. `jq` is a genuine dependency of the scripts and of the existing hook test; suites require it and exit with a clear message if absent, matching `hooks/enforce-git-conventions.test.sh:7`.
- **No writes outside the test's temp dir**, with one unavoidable exception: the poll scripts write pidfiles to a hardcoded `/tmp` path. Suites must use synthetic, run-unique identifiers so those paths cannot collide with a real polling run.
- All commits via conventional commits, `git commit -F -` heredoc form (the hook cannot parse multi-line `-m`).

## Existing Patterns to Follow

- **Harness style:** `hooks/enforce-git-conventions.test.sh` — `set -euo pipefail`, a `jq` availability guard, a `fail()` that writes to stderr and exits 1, small `expect_*` wrapper functions expressed in the vocabulary of the thing under test, flat top-level assertion calls (no test framework, no runner protocol), and a final `echo "<script> tests passed"`. Read it before writing; match it rather than inventing a style.
- **Script-under-test resolution:** the same `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` idiom, so a suite runs correctly from any working directory.
- **Exit-code constants:** `scripts/lib/poll-common.sh:6-12` is the authoritative list; README:116 restates it for users. Tests assert the numbers, not the constant names.
- **JSON contracts:** `create-github-issues.sh:27-28` and `create-local-issues.sh:29-30` document the output shape in their headers; those comments are the contract to test.
- **CHANGELOG:** grouped, bolded change titles with rationale, per the 2.6.0 entry.

## Non-Functional Requirements

- **Runtime:** `bash scripts/run-tests.sh` completes in under ~60s total on a laptop. The only sleeping is the poll scripts' own `sleep "$POLL_INTERVAL"`, pinned to 1 second with `max_polls` ≤ 4.
- **Determinism:** no test depends on wall-clock time, network reachability, ambient credentials, or the contents of the user's `/tmp` beyond files it created. Repeated runs give identical results.
- **Hermeticity:** a test run leaves the repo working tree unchanged — verifiable with `git status --porcelain` before and after.
- **Security:** stubs are written into a per-run temp dir and never onto the repo's `PATH` permanently; no credentials, tokens, or real repo identifiers appear in fixtures.

## Open Questions

- **NEEDS USER CARD — REQ-000: what to do about the three `poll-common.sh` defects?** Both poll scripts are currently broken in every configuration (DEF-1), so exits 0/1/2/3/4 cannot be asserted green. This is a scope decision, not an architect call, because it changes the feature from test-only to test-plus-fix.
  - *Option A (recommended): include REQ-000 as a sequenced prerequisite step.* The fix is confined to one file that is nobody's test domain, so the 4-way parallel structure is preserved. Cost: one extra step and a script change in a test-only feature. Benefit: the suites assert the real contract, the repo standard "all tests pass" holds honestly, and two broken scripts get fixed by the feature that discovered them.
  - *Option B: tests-only; assert the broken behavior.* Keeps the won't-have boundary exactly as written. The suites pass, but they encode `exit 1 / no output` as expected for both poll scripts, and the P6.3 evidence is a green suite over known-broken code. The fix becomes a follow-up feature.
  - *Option C: tests-only; assert the contract and let the poll suites fail.* Most honest signal, but `scripts/run-tests.sh` is red on merge, which breaks the verification step (REQ-005) and the review gates.
- **NEEDS USER CARD — does REQ-000, if accepted, ship in this feature's CHANGELOG as a fix, or does it warrant its own patch release first?** Only relevant if Option A is chosen. Recommendation: same release (v2.7.0), one grouped entry, since the tests are the evidence the fix works.

## Risks

- **The 4-batch dispatch does not actually fire**, which would leave P6.3 unvalidated for a second consecutive feature. *Mitigation:* the four suites are genuinely independent files with no shared helper (a constraint stated above, not left to worker judgment); every overlapping file is quarantined in the final step; REQ-007's closure is explicitly conditional on the batch count, so a fallback run cannot be papered over.
- **A worker "fixes" the script it is testing** when its tests fail, silently expanding scope and creating a domain overlap with another worker's fix. *Mitigation:* REQ-013 is an explicit won't-have; DEF-1 through DEF-5 are pre-recorded here so a worker meeting them recognizes a known defect rather than a surprise; the disposition is decided once, up front, by the REQ-000 card.
- **Test pollution of the real repo.** `create-local-issues.sh` `cd`s to the git root and appends to `.gitignore`; the poll scripts write to `/tmp` and send signals. *Mitigation:* per-suite temp `git init` sandboxes (REQ-002, REQ-004), run-unique pidfile identifiers, a self-check that the repo `.gitignore` is untouched, and the hermeticity NFR.
- **Stub drift** — stubs encode today's `gh`/`glab` JSON, so an upstream API shape change leaves the suites green while production breaks. *Mitigation:* accepted deliberately; fixtures are copied from the shapes the scripts' own jq filters consume, and REQ-012 records that real-API coverage is out of scope.
- **Flaky timing** on the `BLOCKED_THRESHOLD` boundary if a stub is slower than the 1-second poll interval. *Mitigation:* stubs are `cat` of a fixture file with no computation; assertions target the emitted `poll` and `stale_polls` counters rather than elapsed time.

## Agreement

Drafted 2026-08-10 by the architect from decision cards DC-01, DC-02, and DC-03, recorded verbatim:

- **DC-01:** Validation vehicle = test suites for the 4 untested scripts: `scripts/create-github-issues.sh`, `scripts/create-local-issues.sh`, `scripts/poll-pr-reviews.sh`, `scripts/poll-mr-reviews.sh`. Each gets a `.test.sh` sibling following the existing pattern in `hooks/enforce-git-conventions.test.sh` (read it first — match its harness style, assertion helpers, and self-contained execution).
- **DC-02:** PRD drafted directly by architect, refined at the Phase 0.2 review gate — no `/discover` session.
- **DC-03:** The feature's final step marks `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3's exit criterion ("one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking") as MET — dated, with the run's swarm report and gate verdicts as evidence — plus a CHANGELOG entry. This closure is conditional: it is recorded only if this feature's own run genuinely dispatches 3+ parallel batches and shows no regression.

Passed architect adversarial self-review 2026-08-10 with 7 findings resolved: (1) the poll suites' exit-code ACs were unachievable against the current code — three live defects found by running the scripts, promoted to a documented defect list, a conditional REQ-000, and a user card, with a reduced form specified for each blocked requirement so the PRD stands whichever way the card resolves; (2) a shared test-helper library was the obvious way to write four similar suites and would have collapsed the four file domains into one, defeating the feature's own P6.3 purpose — now an explicit constraint; (3) `create-local-issues.sh` mutates `.gitignore` at the git root, so an unsandboxed suite would have written into this repo — temp-repo isolation is now a hard AC with a self-check; (4) `poll-mr-reviews.sh` needs a git remote to derive its pidfile slug, which the original ACs did not account for; (5) "100% of documented exit codes" was unsatisfiable as written because exit 4 is unreachable in `poll-pr-reviews.sh` — coverage is now per-script and the gap is recorded rather than silently missed; (6) the pidfile ACs would have signalled a PID the suite did not create, and `/tmp` paths could collide with a real polling run — both now constrained; (7) `hooks/enforce-git-conventions.test.sh` is mode 644, so a runner invoking suites as executables would have skipped the only pre-existing test — the runner now invokes via `bash`.

This document is the contract for implementation.
All acceptance criteria will be validated before delivery.
