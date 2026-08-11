# Findings — `script_tests`

Defects discovered while building the four `.test.sh` suites and the REQ-000 prerequisite repair. Per REQ-006 (`docs/features/script_tests/PRD.md`), this file separates defects that were fixed in this feature (**Repaired**) from defects that were observed, documented, and deliberately left unfixed (**Open**) — the latter are report-only findings for a follow-up feature, per the REQ-013 boundary (no rewriting the four scripts under test).

Each entry: file:line, observed behavior, expected behavior per the script's own documentation, reproduction command, severity.

## Repaired

### DEF-1 — `_NEW_COUNT` lost across a subshell

- **File:line:** `scripts/lib/poll-common.sh:64-79` (pre-fix); repaired in `find_new_ids()` and its two call sites, `scripts/poll-pr-reviews.sh:92`, `scripts/poll-mr-reviews.sh:90`.
- **Observed (pre-fix):** `find_new_ids` set `_NEW_COUNT` as a side effect, but every caller invoked it as `NEW_IDS=$(find_new_ids ...)`, so the assignment happened inside a command-substitution subshell and never reached the caller. Under `set -u` the next read of `_NEW_COUNT` died with an unbound-variable error. Both poll scripts aborted on poll iteration 1, in every configuration, with exit 1 and no JSON on stdout — exit codes 1, 2, 3, and 4 were unreachable in the shipped code.
- **Expected:** the documented exit-code contract (`0/1/2/3/4/10/11`) is reachable; a poll iteration that finds new unresolved threads reports them instead of crashing.
- **Severity:** blocker.
- **Fix:** commit `00af874` ("fix(poll): repair three defects in poll-common.sh (REQ-000)"). `find_new_ids` was made pure — it only emits IDs — and each call site now derives the count itself from the captured output via the `count_ids()` helper in `poll-common.sh` (`NEW_COUNT=$(count_ids "$NEW_IDS")`), removing the shared-global coupling instead of working around it (no `declare -n`, which is bash 4.3+ and unavailable on this repo's bash 3.2 target).
- **Covering tests:** `scripts/poll-pr-reviews.test.sh` (commit `75800ef`) exercises exit 1 (`NEW_COMMENTS`) end to end; `scripts/poll-mr-reviews.test.sh` (commit `6169121`) does the same plus exit 4 (`PIPELINE_FAILED`), which was equally unreachable before the repair.
- **Repro (pre-fix behavior, for reference):** run `scripts/poll-pr-reviews.sh owner/repo 1 1 1` against any stub `gh` that returns one unresolved thread; observe `_NEW_COUNT: unbound variable` on stderr and exit 1 instead of the documented `NEW_COMMENTS` JSON.

### DEF-2 — invalid JSON escape in the bot pattern

- **File:line:** `scripts/lib/poll-common.sh:18` (pre-fix: `BASE_BOT_PATTERNS="...\[bot\]$..."`).
- **Observed (pre-fix):** `BASE_BOT_PATTERNS` interpolated `\[bot\]$` into a jq program *inside a JSON string literal*. `\[` is not a valid JSON escape, so jq exited with two compile errors on every poll. Bot-emoji approval (exit 0 via the award-emoji gate) could not fire on either script.
- **Expected:** a `[bot]`-suffixed login (e.g. `dependabot[bot]`, `cursor-bugbot`) matching the approval pattern produces exit 0 with `.approvers` populated.
- **Severity:** blocker (compounds DEF-1 — jq never even reached this code path while DEF-1 was unfixed).
- **Fix:** commit `00af874`. The literal brackets are now expressed as regex character classes (`[[]bot[]]$|-bot-|^chatgpt-codex|^cursor-bugbot`), which need no backslashes and therefore no JSON-string escaping at all. Verified to match `dependabot[bot]` and `cursor-bugbot`, and to survive `poll-mr-reviews.sh`'s concatenation of the GitLab-specific `|^gitlab-duo|^gitlab-code-review` suffix.
- **Covering tests:** `scripts/poll-pr-reviews.test.sh` (`75800ef`) asserts exit 0 via a `THUMBS_UP` reaction from both a `[bot]`-suffixed login and `cursor-bugbot`; `scripts/poll-mr-reviews.test.sh` (`6169121`) asserts exit 0 via `thumbsup` from `gitlab-duo` and `gitlab-code-review`.
- **Repro (pre-fix behavior, for reference):** feed a `THUMBS_UP` reaction from `dependabot[bot]` through the approval path; observe two jq compile errors on stderr instead of `.status == "APPROVED"`.
- **Follow-up (deferred, not taken in this repair):** the more robust fix — pass the pattern via `jq --arg` so it never reaches jq's program parser at all — was deliberately not taken. It would require editing the `jq` invocations inside both poll scripts, widening a repair that was scoped to stay inside `scripts/lib/poll-common.sh` alone (REQ-000's AC). Recorded here as a candidate for a future hardening pass, not as an open defect — the character-class fix is verified correct for the patterns in use today.
- **REQ-000 scope note:** two further changes to `poll-common.sh` — narrowing `BASE_BOT_PATTERNS`' `-bot-` to the end-anchored `-bot$`, and adding `acquire_pidfile`'s PID-reuse identity check (`<pid>:<lstart>`) — were added during Phase 3 review remediation as security hardening beyond REQ-000's original three-defect (DEF-1..DEF-3) scope. Both are now covered by regression tests in `scripts/poll-pr-reviews.test.sh` (commit `40e9e26`); see the residual gaps still open against the `-bot$` pattern and the pidfile scheme below.

### DEF-3 — empty-array expansion under `set -u`

- **File:line:** `scripts/lib/poll-common.sh:20-27` (pre-fix: `"${_CLEANUP_PATHS[@]}"`).
- **Observed (pre-fix):** `"${_CLEANUP_PATHS[@]}"` on an empty array under bash 3.2 + `set -u` is an unbound-variable error. Every early exit that preceded the first `register_cleanup` call — i.e. every usage error — printed a spurious error from the `_cleanup` EXIT trap instead of the clean usage message alone.
- **Expected:** a usage error (missing/invalid arguments) exits 10 with only the documented `{"error": "..."}` message on stderr — no trap noise.
- **Severity:** minor (cosmetic, but noisy enough to obscure the real error in scripted/CI consumption of stderr).
- **Fix:** commit `00af874`. The trap loop now uses the bash-3.2-safe empty-array guard `for p in ${_CLEANUP_PATHS[@]+"${_CLEANUP_PATHS[@]}"}; do`, which expands to nothing when the array is empty instead of raising under `set -u`.
- **Covering tests:** `scripts/poll-pr-reviews.test.sh` (`75800ef`) and `scripts/poll-mr-reviews.test.sh` (`6169121`) both assert exit 10 on missing/invalid arguments with clean stderr (no unbound-variable noise from the EXIT trap), per REQ-003/REQ-004's exit-10 ACs.
- **Repro (pre-fix behavior, for reference):** run either poll script with no arguments; observe an `_CLEANUP_PATHS: unbound variable` line on stderr in addition to the usage-error JSON.

## Open

### DEF-4 — `create-github-issues.sh` jq guard is dead code

- **File:line:** `scripts/create-github-issues.sh:74` (first `jq` invocation) vs. `scripts/create-github-issues.sh:97` (`command -v jq` guard).
- **Observed:** `jq` is invoked twenty-three lines before the `command -v jq` availability guard. With `jq` absent from `PATH`, the script fails at line 74 first and exits **10** ("Plan steps file is not valid JSON") — the guard at line 97 never runs.
- **Expected (per the script's own documentation):** exit **1** with `"jq not found — install jq"` (the message the line-97 guard would emit if it were reachable).
- **Severity:** minor — the script still fails loudly and non-zero, just with the wrong documented code and a misleading message ("not valid JSON" when the real problem is a missing binary).
- **Repro:** `PATH=$(dirname "$(command -v git)") scripts/create-github-issues.sh <valid-plan-steps.json>` (a `PATH` with `git` but no `jq`); observe exit 10, not 1.
- **Observed-behavior test:** `scripts/create-github-issues.test.sh` (commit `0497474`) asserts the observed exit 10 at the assertion site, with a comment naming DEF-4 — it does not assert the aspirational exit-1 contract.
- **Disposition:** out of scope for this feature per REQ-013; report-only. Fix would be a one-line reorder (move the guard above line 74) inside `create-github-issues.sh`, which is REQ-001's test-file domain, not REQ-000's repair domain.

### DEF-5 — `create-local-issues.sh` leaves an empty `plans/` dir on exit 10

- **File:line:** `scripts/create-local-issues.sh:83` (`mkdir -p "$PLANS_DIR"`) vs. `scripts/create-local-issues.sh:87` (JSON validation).
- **Observed:** `mkdir -p "$PLANS_DIR"` runs before the plan-steps JSON is validated. An invalid plan-steps file (missing, malformed, or empty array) still exits 10, but leaves an empty `plans/<feature_id>/` directory behind.
- **Expected (per the script's own documentation):** exit 10 with no filesystem side effects, matching the "usage error, nothing written" contract implied by the other exit-10 paths.
- **Severity:** cosmetic — no data loss, no incorrect output, just a stray empty directory a caller could mistake for successful (partial) output.
- **Repro:** `scripts/create-local-issues.sh /nonexistent/steps.json somefeature` inside a scratch git repo; observe exit 10 and `plans/somefeature/` created and empty.
- **Observed-behavior test:** `scripts/create-local-issues.test.sh` (commit `fe92cf0`) asserts the empty directory is left behind on the invalid-JSON exit-10 path, with a comment naming DEF-5.
- **Disposition:** out of scope for this feature per REQ-013; report-only. Fix would be reordering the `mkdir -p` below JSON validation inside `create-local-issues.sh`, which is REQ-002's test-file domain.

### DEF-6 (new) — malformed roadmap JSON does not omit the `## Roadmap` section

- **File:line:** `scripts/create-local-issues.sh:163-168`.
- **Observed:** when `ROADMAP_FILE` is present but contains invalid JSON, the `## Roadmap` heading and table header (`| Phase | Status | Summary |` + separator) are written to the epic file unconditionally, once the file exists at all (`163-168`). Only the jq-derived data rows are silently dropped (via `|| true` on the failing `jq` call at line 170) — the section itself is not omitted.
- **Expected (per PRD AC, `docs/features/script_tests/PRD.md:68`):** "malformed roadmap JSON still exits 0 with the section omitted" — i.e. no `## Roadmap` heading at all when the roadmap file fails to parse.
- **Severity:** cosmetic — exit code and overall JSON contract are unaffected (still exit 0); the epic markdown gets an empty, header-only roadmap table instead of no table.
- **Repro:** run `create-local-issues.sh` with a `ROADMAP_FILE` containing `this is not valid json`; inspect the generated `issue-0000.md` — it contains `## Roadmap` and the table header with zero data rows.
- **Discovered by:** `scripts/create-local-issues.test.sh` (commit `fe92cf0`), which asserts the *observed* behavior (header present, no data rows) rather than the PRD's stated aspirational behavior, with an inline comment explaining the discrepancy.
- **Disposition:** newly found during REQ-002's suite construction, not among DEF-1..DEF-5 identified at PRD discovery time. Report-only per REQ-013's scope boundary (no changes to `create-local-issues.sh` in this feature); candidate for the same follow-up feature that addresses DEF-4/DEF-5.

### Pidfile paths hardcode `/tmp`, ignoring `TMPDIR` — and the bare-PID fallback enables a same-user DoS

- **File:line:** `scripts/lib/poll-common.sh` callers — `scripts/poll-pr-reviews.sh` (pidfile path `/tmp/poll-pr-reviews-<owner>-<name>-<pr>.pid`) and `scripts/poll-mr-reviews.sh` (equivalent GitLab-slug form); `acquire_pidfile`'s bare-PID back-compat branch, `scripts/lib/poll-common.sh:73-79,91-106`.
- **Observed:** both poll scripts write their PID file to a hardcoded `/tmp/...` path rather than honoring `${TMPDIR:-/tmp}`, the convention the rest of the repo's tooling follows (e.g. `hooks/auto-test-runner.sh`'s own pidfile). The path is fully predictable from `owner`/`name`/`pr_number` alone. Compounding this: `acquire_pidfile`'s identity check only applies when the pidfile is in the newer `<pid>:<lstart>` format — a pidfile in the older bare-PID format (no colon) still triggers the unconditional kill-if-alive behavior (`scripts/poll-pr-reviews.test.sh`'s "back-compat, bare-PID format" case, commit `40e9e26`, asserts this is intentional and still live). On a shared host or shared account, another local user (or process) can pre-create `/tmp/poll-pr-reviews-<owner>-<name>-<pr>.pid` containing the PID of an arbitrary live process it wants killed, then wait for a legitimate polling run against that same `owner/name/pr` to start and kill it on their behalf — a same-user/shared-host denial-of-service that the identity check does not close for this pidfile shape.
- **Expected:** consistent with the repo's other pidfile usage, the path should respect `TMPDIR` when set; recommend `${TMPDIR:-/tmp}`. A durable fix for the DoS vector would also need the bare-PID fallback removed or made identity-aware (e.g. treat a colon-less pidfile as untrusted rather than falling back to unconditional kill).
- **Severity:** minor (TMPDIR divergence) / low-to-moderate (bare-PID DoS vector) — functionally harmless on the vast majority of systems where `TMPDIR` is unset or resolves to `/tmp` and where the host is single-user, but a latent hazard on shared hosts or sandboxed CI where `TMPDIR` differs and multiple local principals share `/tmp`.
- **Noted by:** `scripts/poll-pr-reviews.test.sh` (commit `75800ef`, line 58) records the `TMPDIR` divergence in a comment; both poll suites use run-unique synthetic `owner/repo`/PR/MR identifiers precisely because they cannot relocate the pidfile out of `/tmp`, so their own test runs cannot collide with a real polling run or with each other. The bare-PID unconditional-kill behavior and the identity-mismatch counter-case are both explicitly exercised in `scripts/poll-pr-reviews.test.sh` (commit `40e9e26`).
- **Disposition:** out of scope per REQ-013 (would require editing both poll scripts, not just the shared lib); report-only.

### REQ-009 coverage gap — `poll-pr-reviews.sh` exit 4 unreachable

- **Script:** `scripts/poll-pr-reviews.sh`. Documented exit-code set: `0, 1, 2, 3, 10, 11` (per its own header) — note this set does **not** include 4 in the first place.
- **Observed:** `EXIT_PIPELINE_FAILED` (4) is defined in the shared `scripts/lib/poll-common.sh` (used by both poll scripts for a common exit-code namespace) but `poll-pr-reviews.sh` has no code path that emits it — `PIPELINE_FAILED` is a GitLab pipeline concept, exercised only by `poll-mr-reviews.sh`.
- **Expected:** none — this is a deliberate, documented omission, not a gap against `poll-pr-reviews.sh`'s own contract. `scripts/poll-pr-reviews.test.sh` (`75800ef`) states this explicitly in a comment block immediately before its final summary line ("Exit 4 is deliberately NOT asserted... PIPELINE_FAILED is GitLab-only... unreachable here") so the omission reads as deliberate rather than a missed test.
- **Severity:** informational — recorded per REQ-009's requirement that any documented exit code not exercised by a suite be listed here with the reason. `poll-mr-reviews.test.sh` (`6169121`) exercises exit 4 for the script where it is actually reachable.

### `poll-pr-reviews.sh` does not validate `PR_NUMBER`/`OWNER`/`NAME` before GraphQL interpolation

- **File:line:** `scripts/poll-pr-reviews.sh` — argument parsing around its `OWNER`/`NAME`/`PR_NUMBER` assignment, before the values are interpolated into the GitHub GraphQL query string. `scripts/poll-mr-reviews.sh` validates its equivalent `MR_IID` via `require_positive_int` (`scripts/lib/poll-common.sh:46`) before use — `poll-pr-reviews.sh` has no equivalent check on `PR_NUMBER`, `OWNER`, or `NAME`.
- **Observed:** unlike `poll-mr-reviews.sh`, `poll-pr-reviews.sh` interpolates `PR_NUMBER` (and the `owner`/`name` repo-slug components) directly into the GraphQL query body with no format validation first. A crafted value can inject additional GraphQL syntax into the query.
- **Expected:** consistent with `poll-mr-reviews.sh`'s own `MR_IID` handling, `PR_NUMBER` should be validated via `require_positive_int` and `OWNER`/`NAME` should be constrained to a safe identifier charset before either is interpolated into the query.
- **Repro:** `scripts/poll-pr-reviews.sh 'a/b' "1) {id} } } #" 1 1` — the crafted second argument injects into the GraphQL query instead of being rejected as a usage error.
- **Severity:** security-relevant (GraphQL query injection) — not merely a correctness/consistency gap between the two poll scripts; an unvalidated `PR_NUMBER`/`OWNER`/`NAME` interpolated directly into a GraphQL query string lets a crafted argument alter the query GitHub's API actually executes. Relabeled from the original "correctness/consistency gap" wording so a follow-up ticket prioritizes it correctly. The shared `require_positive_int` helper this would use already exists in `scripts/lib/poll-common.sh`.
- **Disposition:** out of scope for this feature per REQ-013 (would require editing `poll-pr-reviews.sh`, not just the shared lib). Recommend a follow-up ticket: apply `require_positive_int` to `PR_NUMBER` and a `^[A-Za-z0-9._-]+$` check to `OWNER`/`NAME`, with the regression test added to `scripts/poll-pr-reviews.test.sh`.

### Consumer-project deployment: hook resolves to the toolkit's own `REPO_ROOT`, not the consumer's

- **File:line:** `hooks/auto-test-runner.sh` — `REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` inside the `*.sh` branch.
- **Observed:** per the README's documented deployment layout (copying this toolkit's `.claude/hooks/` and `.claude/scripts/` into a consumer project), `REPO_ROOT` is derived from `hooks/auto-test-runner.sh`'s own location — i.e. the toolkit's checkout inside the consumer project's `.claude/` directory — not the consumer project's own repo root. `scripts/run-tests.sh` would therefore discover and run the *toolkit's own* `*.test.sh` suites on every `*.sh` edit anywhere in the consumer project, not any test suite belonging to the consumer project itself.
- **Expected:** none defined yet — this is a design gap, not a defect against a stated contract. A consumer-project deployment has no documented mechanism for `auto-test-runner.sh` to discover the *consumer's* shell test suites (if any) rather than the toolkit's.
- **Severity:** informational — no impact on this repo's own use of the hook (`REPO_ROOT` correctly resolves to this repo when the hook runs here); only surfaces once the toolkit is deployed into another project per the README's layout.
- **Disposition:** known limitation, not fixed here. Needs an architect decision in a future feature (e.g. detecting a consumer-side `scripts/run-tests.sh` and preferring it, or an explicit config knob) — out of scope for `script_tests` per REQ-013.

### `BASE_BOT_PATTERNS`' `-bot$` anchor still permits suffix impersonation

- **File:line:** `scripts/lib/poll-common.sh:28` (`BASE_BOT_PATTERNS="[[]bot[]]$|-bot$|^chatgpt-codex|^cursor-bugbot"`).
- **Observed:** the round-1 security fix narrowed the unanchored `-bot-` to the end-anchored `-bot$`, closing the "contains -bot- anywhere" bypass (e.g. `mallory-bot-reviewer`, now correctly rejected — see the regression test added in commit `40e9e26`). But `-bot$` is still a suffix match with no ownership/allowlist check: any GitHub login an attacker controls and that simply *ends* in `-bot` — e.g. `attacker-bot`, `my-bot` — satisfies the pattern and can award a `THUMBS_UP`/`WHITE_CHECK_MARK` reaction that the poll scripts treat as a trusted bot approval, bypassing the emoji-approval gate's intent (trusted CI/review bots only).
- **Expected:** only reactions from a fixed, known set of trusted bot accounts (Dependabot, Renovate, the repo's configured code-review bots, etc.) should satisfy the approval gate — not any login matching a naming convention, which is attacker-choosable at GitHub account-creation time.
- **Repro:** feed a `THUMBS_UP` reaction from login `attacker-bot` or `my-bot` through `poll-pr-reviews.sh`'s approval path (or test directly against `BASE_BOT_PATTERNS` with `echo '"attacker-bot"' | jq "test(\"$BASE_BOT_PATTERNS\"; \"i\")"`); observe a match (`true`) and, in the full script, `.status == "APPROVED"`.
- **Severity:** security-relevant (approval-gate impersonation) — no regex-based suffix/prefix/infix pattern can fully close this class of bypass, since GitHub logins are attacker-choosable; regex narrowing (as done in round 1) reduces the attack surface but does not eliminate it.
- **Disposition:** out of scope for this feature per REQ-013 (would require editing the approval-gate design, not just tightening a regex, and is arguably an architecture decision). Durable fix recommended for a follow-up ticket: replace the regex-based `BASE_BOT_PATTERNS` match with an explicit allowlist of known bot login strings (exact match, not pattern match).

### `hooks/auto-test-runner.sh`'s `*bash*` comm-match is loose; small self-terminating orphan window

- **File:line:** `hooks/auto-test-runner.sh:61-66` (skip-if-in-flight identity check on the shell-suite pidfile).
- **Observed:** before treating a live PID recorded in `${TMPDIR:-/tmp}/auto-test-runner-shell.pid` as "a shell-suite run in flight," the hook checks `ps -o comm=` against the case pattern `*bash*|*run-tests*`. `*bash*` matches essentially any bash process, not specifically a `run-tests.sh` invocation — if the PID recorded in the pidfile is reused (after the original run-tests.sh process exits) by any unrelated bash process (an interactive shell, an unrelated script, a subshell of anything), the hook will treat it as an in-flight run and skip starting a new one, indefinitely, until that unrelated bash process itself exits.
- **Expected:** the comm-match should identify the specific `run-tests.sh` invocation, not any bash process. However, dropping `*bash*` in favor of `*run-tests*` alone against `ps -o comm=` output would not achieve this: `comm=` reports only the interpreter name (`bash` or `/bin/bash`), never the invoked script's filename, in both invocation styles (`bash "$RUN_TESTS" &` and a direct, shebang'd `run-tests.sh &`). A `*run-tests*` pattern matched against `comm=` therefore never matches in either case, so the hook invokes `bash "$RUN_TESTS" &` — meaning the in-flight check would silently stop matching altogether, and the hook would never skip a concurrent run, reintroducing the pile-up problem the earlier M2 fix solved. The correct remediation is to match against `ps -o args=` instead of `ps -o comm=` — `args=` includes the full command line (and therefore the `run-tests.sh` path) in both invocation styles — e.g. `case "$(ps -o args= -p "$PID" 2>/dev/null)" in *run-tests.sh*) ... ;; esac`. This identifies the specific invocation without the `*bash*` arm's over-broad match against any bash process.
- **Severity:** low — requires PID reuse (bounded by the OS PID space and unlikely in the hook's short in-flight windows) landing on an unrelated long-lived bash process; the practical effect is a missed/delayed test run rather than a correctness or security failure of the tests themselves.
- **Repro:** not independently reproduced (would require deliberately engineering a PID-reuse race); flagged from code review of the comm-match pattern against the identity-check technique already validated for `poll-common.sh`'s `acquire_pidfile` (commit `40e9e26`'s pidfile identity-mismatch test covers the equivalent case for that pidfile scheme).
- **Related — accepted, not a fix target:** a second, smaller gap in the same hook: if the hook process itself is killed while blocked in `wait "$SH_PID"` (line 82), its `EXIT` trap (line 71) still fires and removes `$SH_PIDFILE`, but the backgrounded `run-tests.sh` child it was waiting on survives (it has its own process group via `set -m`). A subsequent hook invocation then sees no pidfile and starts a second, concurrent `run-tests.sh` run. This window is bounded by the shell suite's own runtime (observed ~47-52s per the reviewer's round-2 runtime note) and self-terminating (the orphaned run finishes and exits on its own); noted here as an accepted risk rather than something requiring a fix in this feature.
- **Disposition:** out of scope for this feature per REQ-013 (would require editing `hooks/auto-test-runner.sh`, not the four scripts under test). Recommend a follow-up ticket: switch the identity check from `ps -o comm=` to `ps -o args=` and match `*run-tests.sh*` against that output, rather than dropping `*bash*` against `comm=` (which would never match and would break the in-flight check entirely — see Expected above).

## Documented exit-code coverage summary (REQ-009)

| Script | Documented set | Exercised | Gap |
|---|---|---|---|
| `create-github-issues.sh` | 0, 1, 10 | 0, 1, 10 | none |
| `create-local-issues.sh` | 0, 1, 10 | 0, 1, 10 | none |
| `poll-pr-reviews.sh` | 0, 1, 2, 3, 10, 11 | 0, 1, 2, 3, 10, 11 | exit 4 N/A — see gap entry above |
| `poll-mr-reviews.sh` | 0, 1, 2, 3, 4, 10, 11 | 0, 1, 2, 3, 4, 10, 11 | none |
