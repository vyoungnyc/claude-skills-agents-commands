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

### DEF-4 — `create-github-issues.sh` jq guard is dead code

- **File:line:** `scripts/create-github-issues.sh:74` (first `jq` invocation) vs. `scripts/create-github-issues.sh:97` (`command -v jq` guard).
- **Observed (pre-fix):** `jq` is invoked twenty-three lines before the `command -v jq` availability guard. With `jq` absent from `PATH`, the script failed at line 74 first and exited **10** ("Plan steps file is not valid JSON") — the guard at line 97 never ran.
- **Expected:** exit **1** with `"jq not found — install jq"` (the message the line-97 guard emits once reachable).
- **Severity:** minor — the script still failed loudly and non-zero, just with the wrong documented code and a misleading message ("not valid JSON" when the real problem was a missing binary).
- **Fix:** commit `0e554f3` ("fix(scripts): move jq-availability guard before first jq use in create-github-issues.sh"). The `command -v jq` guard now runs before the first `jq` invocation.
- **Covering tests:** `scripts/create-github-issues.test.sh` (commit `2d57c0a`) now asserts the corrected exit 1 with the "jq not found" message when `jq` is absent from `PATH`.
- **Repro (pre-fix behavior, for reference):** `PATH=$(dirname "$(command -v git)") scripts/create-github-issues.sh <valid-plan-steps.json>` (a `PATH` with `git` but no `jq`); observed exit 10, not 1, before the fix.

### DEF-5 — `create-local-issues.sh` leaves an empty `plans/` dir on exit 10

- **File:line:** `scripts/create-local-issues.sh:83` (`mkdir -p "$PLANS_DIR"`) vs. `scripts/create-local-issues.sh:87` (JSON validation).
- **Observed (pre-fix):** `mkdir -p "$PLANS_DIR"` ran before the plan-steps JSON was validated. An invalid plan-steps file (missing, malformed, or empty array) still exited 10, but left an empty `plans/<feature_id>/` directory behind.
- **Expected:** exit 10 with no filesystem side effects, matching the "usage error, nothing written" contract implied by the other exit-10 paths.
- **Severity:** cosmetic — no data loss, no incorrect output, just a stray empty directory a caller could mistake for successful (partial) output.
- **Fix:** commit `100bf6f` ("fix(scripts): defer plans/ dir creation until plan-steps JSON validates"). `mkdir -p "$PLANS_DIR"` now runs after JSON validation succeeds.
- **Covering tests:** `scripts/create-local-issues.test.sh` (commit `e19e861`) asserts no `plans/<feature_id>/` directory is created on the invalid-JSON exit-10 path.
- **Repro (pre-fix behavior, for reference):** `scripts/create-local-issues.sh /nonexistent/steps.json somefeature` inside a scratch git repo; observed exit 10 and `plans/somefeature/` created and empty, before the fix.

### DEF-6 — malformed roadmap JSON does not omit the `## Roadmap` section

- **File:line:** `scripts/create-local-issues.sh:163-168`.
- **Observed (pre-fix):** when `ROADMAP_FILE` was present but contained invalid JSON, the `## Roadmap` heading and table header (`| Phase | Status | Summary |` + separator) were written to the epic file unconditionally, once the file existed at all. Only the jq-derived data rows were silently dropped (via `|| true` on the failing `jq` call) — the section itself was not omitted.
- **Expected (per PRD AC, `docs/features/script_tests/PRD.md:68`):** "malformed roadmap JSON still exits 0 with the section omitted" — i.e. no `## Roadmap` heading at all when the roadmap file fails to parse.
- **Severity:** cosmetic — exit code and overall JSON contract were unaffected (still exit 0); the epic markdown got an empty, header-only roadmap table instead of no table.
- **Fix:** commit `835ade0` ("fix(scripts): omit Roadmap section entirely on malformed roadmap JSON"). The heading/table header are now only written once the roadmap JSON is confirmed to parse.
- **Covering tests:** `scripts/create-local-issues.test.sh` (commit `e19e861`) asserts no `## Roadmap` heading appears in the generated epic file when `ROADMAP_FILE` contains invalid JSON.
- **Repro (pre-fix behavior, for reference):** run `create-local-issues.sh` with a `ROADMAP_FILE` containing `this is not valid json`; the generated `issue-0000.md` contained `## Roadmap` and the table header with zero data rows, before the fix.

### `poll-pr-reviews.sh` did not validate `PR_NUMBER`/`OWNER`/`NAME` before GraphQL interpolation

- **File:line:** `scripts/poll-pr-reviews.sh` — argument parsing around its `OWNER`/`NAME`/`PR_NUMBER` assignment, before the values are interpolated into the GitHub GraphQL query string.
- **Observed (pre-fix):** unlike `poll-mr-reviews.sh` (which validates `MR_IID` via `require_positive_int` before use), `poll-pr-reviews.sh` interpolated `PR_NUMBER` (and the `owner`/`name` repo-slug components) directly into the GraphQL query body with no format validation first. A crafted value could inject additional GraphQL syntax into the query.
- **Expected:** `PR_NUMBER` validated via `require_positive_int` and `OWNER`/`NAME` constrained to a safe identifier charset before either is interpolated into the query.
- **Severity:** security-relevant (GraphQL query injection).
- **Fix:** commit `b945635` ("fix(scripts): validate PR_NUMBER/OWNER/NAME before GraphQL interpolation in poll-pr-reviews.sh"). `PR_NUMBER` is now validated via `require_positive_int`; `OWNER`/`NAME` are constrained to `^[A-Za-z0-9._-]+$` before either reaches the GraphQL query.
- **Covering tests:** `scripts/poll-pr-reviews.test.sh` (commit `b945635`) asserts a crafted `pr_number` (`"1) {id} } } #"`) is rejected as a usage error (exit 10) rather than reaching the query, and that `owner`/`name` values outside the safe charset are likewise rejected.
- **Repro (pre-fix behavior, for reference):** `scripts/poll-pr-reviews.sh 'a/b' "1) {id} } } #" 1 1` — the crafted second argument injected into the GraphQL query instead of being rejected as a usage error, before the fix.

### Pidfile forgery/DoS and predictable, unguarded pidfile path

- **File:line:** `scripts/lib/poll-common.sh`'s `acquire_pidfile()`; call sites `scripts/poll-pr-reviews.sh` and `scripts/poll-mr-reviews.sh`.
- **Observed (pre-fix, original finding):** both poll scripts wrote their pidfile to a hardcoded `/tmp/...` path rather than honoring `${TMPDIR:-/tmp}`; the path was fully predictable from `owner`/`name`/`pr_number` (or MR slug/iid). Compounding this, `acquire_pidfile`'s identity check only applied to the newer `<pid>:<lstart>` pidfile format — a colon-less bare-PID pidfile still triggered an unconditional kill-if-alive. On a shared host, another local user could pre-create the pidfile naming an arbitrary live process, then wait for a legitimate polling run to kill it on their behalf — a same-user/shared-host denial-of-service.
- **Round 1 (narrowing, insufficient):** commits `973425b` (honor `TMPDIR` for the pidfile path) and `54feb35` (treat a colon-less bare-PID pidfile as untrusted — warn, don't kill — plus the `<pid>:<lstart>` identity-match check already present) closed the *unconditional*-kill shape of the bug. Security review of that round found it insufficient: the `pid:start_time` identity token is not a secret (`ps -o lstart=` is readable by any local user), so an attacker could still forge a fully identity-matching pidfile for a pidfile path they don't own and have it killed by a legitimate run (HIGH-1). Security review also found a second, more severe issue in the same code path: writing `echo "$$:..." > "$pidfile"` follows a pre-existing symlink at that path, silently clobbering whatever it points at — CWE-59 (HIGH-2).
- **Expected:** the pidfile path itself should not be writable by any local user other than its owner — closing the root cause (an untrusted, world-writable, predictable path) rather than adding further token checks on top of it.
- **Severity:** originally minor (TMPDIR divergence) / low-to-moderate (bare-PID DoS); escalated to security-relevant (HIGH) once the identity-token-forgeability and symlink-clobber gaps were found in round 2 review.
- **Fix (round 2, closes the root cause):** commit `5371443` ("fix(poll): close pidfile DoS forgery and symlink-clobber at the root (HIGH-1, HIGH-2)"). `acquire_pidfile()` now creates and uses a per-uid, `0700`-permission directory (`${TMPDIR:-/tmp}/poll-$(id -u)/`, `mkdir -m 700 -p`) that no other local user can write into at all — this is what actually closes HIGH-1, not further hardening of the identity token. It also refuses to follow a symlink at the pidfile path (logs a warning, unlinks it, proceeds as if no pidfile existed — closes HIGH-2/CWE-59) and, as defense in depth, refuses to trust/kill based on a pidfile it does not own. Both poll scripts' pidfile paths were updated to build the path under the new per-uid subdirectory.
- **Covering tests:** commit `5b0a468` ("test(poll): cover identity-verified kill, symlink refusal, and TMPDIR hermeticity"). Adds a positive-control case to `scripts/poll-pr-reviews.test.sh` proving the identity-verified kill path actually fires (a mutation neutering the kill branch to `if false && ...` was confirmed to fail this new case and pass again once reverted — no prior case exercised the true-kill path, only the withheld-kill negatives). Adds a symlinked-pidfile-refused case to both `scripts/poll-pr-reviews.test.sh` and `scripts/poll-mr-reviews.test.sh` asserting a throwaway sentinel file survives untouched and the symlink is unlinked, not followed. Updates both suites' pidfile path expectations to the new `poll-$(id -u)/` subdirectory.
- **Repro (pre-fix behavior, for reference):** as a same-uid caller (no separate attacker uid available in this repo's CI), pre-create the pidfile path as a symlink to an arbitrary file and run either poll script — pre-fix, the symlink target's contents were overwritten; post-fix, the symlink is refused and the target is untouched (see the new symlink-refusal test cases for the exact assertion).

## Open

### REQ-009 coverage gap — `poll-pr-reviews.sh` exit 4 unreachable

- **Script:** `scripts/poll-pr-reviews.sh`. Documented exit-code set: `0, 1, 2, 3, 10, 11` (per its own header) — note this set does **not** include 4 in the first place.
- **Observed:** `EXIT_PIPELINE_FAILED` (4) is defined in the shared `scripts/lib/poll-common.sh` (used by both poll scripts for a common exit-code namespace) but `poll-pr-reviews.sh` has no code path that emits it — `PIPELINE_FAILED` is a GitLab pipeline concept, exercised only by `poll-mr-reviews.sh`.
- **Expected:** none — this is a deliberate, documented omission, not a gap against `poll-pr-reviews.sh`'s own contract. `scripts/poll-pr-reviews.test.sh` (`75800ef`) states this explicitly in a comment block immediately before its final summary line ("Exit 4 is deliberately NOT asserted... PIPELINE_FAILED is GitLab-only... unreachable here") so the omission reads as deliberate rather than a missed test.
- **Severity:** informational — recorded per REQ-009's requirement that any documented exit code not exercised by a suite be listed here with the reason. `poll-mr-reviews.test.sh` (`6169121`) exercises exit 4 for the script where it is actually reachable.

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

### `poll-pr-reviews.sh`'s `REPO` argument accepts slash-free or multi-slash values and silently derives a wrong owner/name

- **File:line:** `scripts/poll-pr-reviews.sh:23-29` (`OWNER="${REPO%%/*}"`, `NAME="${REPO##*/}"`, followed by the per-component `^[A-Za-z0-9._-]+$` charset check).
- **Observed:** the charset check validates `OWNER` and `NAME` individually after splitting, but nothing validates that `REPO` actually contained exactly one `/` in the first place. A slash-free value like `myrepo` splits to `OWNER=myrepo`, `NAME=myrepo` (both halves pass the charset check, silently duplicating the input instead of being rejected); a multi-slash value like `a/b/c` splits to `OWNER=a`, `NAME=c` (the middle segment is silently discarded), again passing charset validation with no indication the input was malformed.
- **Expected:** `REPO` should be validated as a whole against `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` before splitting, rejecting any value that isn't exactly one owner segment, one `/`, and one name segment.
- **Severity:** low — the derived `OWNER`/`NAME` still pass the existing charset guard, so this doesn't reopen the GraphQL-injection finding fixed above; the practical effect is a confusing wrong-repo query (or silently-wrong owner="myrepo" name="myrepo") rather than a security bypass.
- **Repro:** `scripts/poll-pr-reviews.sh myrepo 1 1 1` or `scripts/poll-pr-reviews.sh a/b/c 1 1 1`; observe the script proceeds past validation instead of exiting 10 with a usage error.
- **Disposition:** report-only per this round's scope (identity/pidfile hardening and B1/N3/N2 only). Recommend a follow-up ticket: replace the per-component charset check with a single pre-split `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` validation against the raw `REPO` argument.

### `create-local-issues.sh`'s `FEATURE_ID` is interpolated into `PLANS_DIR` unvalidated, risking a path traversal write

- **File:line:** `scripts/create-local-issues.sh` — `PLANS_DIR="plans/${FEATURE_ID}"` (and the corresponding issues output directory built from the same `FEATURE_ID`).
- **Observed:** `FEATURE_ID` (the script's second positional argument) is interpolated directly into `PLANS_DIR` with no charset or traversal check. A value such as `../../etc` produces `PLANS_DIR="plans/../../etc"`, which resolves outside the repo the script is run from.
- **Expected:** `FEATURE_ID` should be constrained to a safe identifier charset (e.g. `^[A-Za-z0-9._-]+$`, explicitly excluding `/`) before being used to build any filesystem path, rejecting traversal sequences.
- **Severity:** low — requires the caller to pass an attacker-controlled `FEATURE_ID` (this is a local CLI tool, not a network-facing service), but the blast radius if it happens is a write outside the repo, so it's worth tracking rather than dismissing.
- **Repro:** `scripts/create-local-issues.sh <valid-plan-steps.json> '../../etc'` inside a scratch git repo; observe `PLANS_DIR` resolves outside the repo instead of being rejected.
- **Disposition:** report-only per this round's scope. Recommend a follow-up ticket: add a `^[A-Za-z0-9._-]+$` charset guard on `FEATURE_ID` immediately after argument parsing, consistent with the charset guards already used elsewhere in the poll scripts.

## Documented exit-code coverage summary (REQ-009)

| Script | Documented set | Exercised | Gap |
|---|---|---|---|
| `create-github-issues.sh` | 0, 1, 10 | 0, 1, 10 | none |
| `create-local-issues.sh` | 0, 1, 10 | 0, 1, 10 | none |
| `poll-pr-reviews.sh` | 0, 1, 2, 3, 10, 11 | 0, 1, 2, 3, 10, 11 | exit 4 N/A — see gap entry above |
| `poll-mr-reviews.sh` | 0, 1, 2, 3, 4, 10, 11 | 0, 1, 2, 3, 4, 10, 11 | none |
