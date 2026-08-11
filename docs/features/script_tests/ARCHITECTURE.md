# Architecture: `script_tests`

Design source of truth for the feature. Contract is `docs/features/script_tests/PRD.md`; this document says *how*.

## 1. Test harness pattern

`hooks/enforce-git-conventions.test.sh` (47 lines) is the only precedent and the template. What it establishes:

- `set -euo pipefail`; resolve the script under test relative to `${BASH_SOURCE[0]}` so the suite runs from any cwd.
- A `jq` availability guard that exits 1 with a plain message (line 7).
- One `fail()` that writes to stderr and exits 1. First failure aborts the suite — no failure accumulation, no counts.
- Small `expect_*` wrappers named in the vocabulary of the thing under test (`expect_denied`, `expect_allowed`), each taking the input and the expectation.
- Flat top-level assertion calls. No test framework, no discovery protocol, no `main`.
- A closing `echo "<script> tests passed"`.

Each of the four suites follows this shape, substituting its own vocabulary: `expect_exit`, `expect_json`, `expect_stderr_match`, and per-script helpers such as `run_with_stub`. The suites are peers of the scripts they test (`scripts/<name>.test.sh`), matching the hook precedent.

**Deliberate duplication.** Every suite carries its own copy of `fail()`, the assertion wrappers, and its stub scaffolding. See §4 for why a shared helper library is forbidden here.

## 2. Stubbing seams

No suite touches the network. The seam in every case is `PATH`: each suite writes stub executables into a per-run temp dir and prepends it, so the script under test resolves `gh`/`glab` to the stub. `jq` is a genuine dependency and is never stubbed except in the one test that asserts its absence.

| Script | Seam | Notes |
|---|---|---|
| `create-github-issues.sh` | stub `gh` | Dispatches on `$1 $2` (`auth status`, `repo view`, `label create`, `issue create`); returns issue URLs from an incrementing counter file; appends its argv to a log the suite asserts against. `GH_REPO` bypasses repo detection. |
| `create-local-issues.sh` | filesystem only | Needs no binary stub; needs **isolation** (below). `SKIP_GITIGNORE` and `FORCE_OVERWRITE` are the env seams. |
| `poll-pr-reviews.sh` | stub `gh` | Returns canned GraphQL fixtures, selected by a per-call counter file so state can change between polls. |
| `poll-mr-reviews.sh` | stub `glab` | Dispatches on the API path (`discussions`, `pipelines`, `approvals`, `award_emoji`). The script fetches four endpoints in parallel then `wait`s, so the stub must be safe under concurrent invocation — write to distinct per-endpoint files, never a shared one. |

**Temp-repo isolation (`create-local-issues.sh`, `poll-mr-reviews.sh`).** `create-local-issues.sh:58-61` runs `cd "$(git rev-parse --show-toplevel)"` and then appends `plans/` to `.gitignore` — a suite that invoked it from this checkout would write into this repo. Every invocation therefore runs inside a throwaway `git init` directory under the suite's temp dir, and the suite asserts the real repo's `.gitignore` is unchanged by its own run. `poll-mr-reviews.sh` needs the same sandbox for a different reason: it derives `PROJECT_SLUG` from `git remote get-url origin`, so the sandbox needs a fake `origin`.

**Timer stubbing (poll scripts).** There is no timer injection point; the scripts `sleep "$POLL_INTERVAL"` directly. The interval is a positional argument, so the seam is the argument itself: every invocation passes `poll_interval_sec=1` with `max_polls` ≤ 4. `BLOCKED_THRESHOLD` is 3, so the longest path is ~4 seconds. Assertions target the emitted `poll` and `stale_polls` counters, never elapsed wall-clock.

**Pidfile hazard.** Both poll scripts write to a hardcoded `/tmp/poll-*-<slug>.pid` that ignores `TMPDIR`. Suites use run-unique synthetic identifiers (derived from `$$`) so they cannot collide with a real polling run or with each other. The kill-the-previous-instance path is tested only against a `sleep 30 &` the suite itself spawned — a suite must never signal a PID it did not create.

## 3. REQ-000 repair design

Three defects, all rooted in `scripts/lib/poll-common.sh`. All fix idioms below were verified on bash 3.2.57 / jq 1.7.1 before being specified.

**DEF-1 — `_NEW_COUNT` lost across a subshell.** `find_new_ids` assigns `_NEW_COUNT` (lines 67, 71, 77) but every caller invokes it as `NEW_IDS=$(find_new_ids ...)`, so the assignment happens in a command-substitution subshell and dies there. Under `set -u` the caller's next read is a fatal unbound-variable error.

The obvious fix — an out-parameter via `declare -n` — is unavailable: namerefs are bash 4.3+, and this repo targets bash 3.2. The design is instead to **make the function pure and have callers compute the count** from the output they already capture:

```bash
NEW_IDS=$(find_new_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS")
NEW_COUNT=$(printf '%s' "$NEW_IDS" | grep -c . || true)   # || true: grep -c exits 1 on no match
```

`find_new_ids` drops its `_NEW_COUNT` assignments and its "Sets `$_NEW_COUNT`" comment, and emits only IDs. This removes the shared-global coupling rather than working around it.

**DEF-2 — invalid JSON escape in the bot pattern.** `BASE_BOT_PATTERNS` (line 18) contains `\[bot\]$`, which is interpolated into a jq program *inside a JSON string literal*; `\[` is not a valid JSON escape and jq fails to compile on every poll. Fix by expressing the literal brackets as regex character classes, which need no backslashes at all:

```bash
BASE_BOT_PATTERNS="[[]bot[]]$|-bot-|^chatgpt-codex|^cursor-bugbot"
```

Verified to match `dependabot[bot]` and `cursor-bugbot`, and to survive `poll-mr-reviews.sh:31`'s concatenation of `|^gitlab-duo|^gitlab-code-review`. The more robust alternative — pass the pattern with `jq --arg` so it never reaches jq's program parser — is deliberately **not** taken here: it would require editing the `jq` invocations inside both poll scripts, widening a repair that is meant to stay in one file. Recorded as a follow-up option in `FINDINGS.md`.

**DEF-3 — empty-array expansion under `set -u`.** `"${_CLEANUP_PATHS[@]}"` (line 23) is an unbound-variable error on bash 3.2 when the array is empty, which is the case on every exit that precedes the first `register_cleanup` — i.e. all usage errors. Fix with the standard 3.2-safe guard:

```bash
for p in ${_CLEANUP_PATHS[@]+"${_CLEANUP_PATHS[@]}"}; do
```

**Call sites — precise scope.** Each poll script references `_NEW_COUNT` on **two** lines: the `-gt 0` test and the `count:` field of the `NEW_COMMENTS` JSON (`poll-pr-reviews.sh:92,107`; `poll-mr-reviews.sh:90,105`). Each also gains one line assigning `NEW_COUNT`. That is four edited lines and two added lines across the two scripts — a refinement of the PRD's looser phrasing "the two `_NEW_COUNT` call-site lines". Nothing else in either script changes. No documented exit code, JSON key, or CLI argument is altered; the repair makes the existing contract real.

## 4. Dispatch shape

```
step 1  (sequential)  REQ-000 repair  ──►  merge back to feature/script_tests  ──►  VERIFY present
                                                                                        │
steps 2-5 (parallel wave, 4 batches)  ◄─────────────────────────────────────────────────┘
   REQ-001  REQ-002  REQ-003  REQ-004
step 6  (sequential)  runner + FINDINGS + README + CHANGELOG + PHASE_6 closure
```

**Sequencing precondition (load-bearing).** Worker worktrees are cut from `origin/main` and see feature-branch state only through the `git merge feature/script_tests --no-edit` that opens each spawn prompt. If REQ-000 rides in the same wave as the poll suites, or merges back after they spawn, those workers merge a branch without the fix and their exit-code assertions fail against unrepaired code. The orchestrator must confirm the repair is present on `feature/script_tests` before spawning the wave. This is a precondition, not a preference.

**Four independent domains, and no shared helper.** The four test files touch nothing in common. That independence is the feature's *purpose*, not a convenience: `native_swarm` REQ-012 deferred validation of the 3+ dispatch path because its own steps had overlapping domains, and these four files are the vehicle for closing `PHASE_6 §P6.3`. A `scripts/lib/test-helpers.sh` — the natural instinct when writing four similar suites — would put four workers in one file, collapse the wave, and destroy the validation. It is forbidden for this feature. Deduplication is a legitimate follow-up once the suites exist and the runner can prove nothing broke.

Everything with an overlapping domain is quarantined in step 6. Step 1 touches the two poll *scripts*, which are nobody's test-file domain, so it does not collide with the wave.

## 5. Change map

| REQ | Files |
|---|---|
| REQ-000 | `scripts/lib/poll-common.sh` (edit); `scripts/poll-pr-reviews.sh`, `scripts/poll-mr-reviews.sh` (2 lines edited + 1 added each) |
| REQ-001 | `scripts/create-github-issues.test.sh` (new) |
| REQ-002 | `scripts/create-local-issues.test.sh` (new) |
| REQ-003 | `scripts/poll-pr-reviews.test.sh` (new) |
| REQ-004 | `scripts/poll-mr-reviews.test.sh` (new) |
| REQ-005 | `scripts/run-tests.sh` (new) — globs `*.test.sh`, invokes each as `bash <file>` because `hooks/enforce-git-conventions.test.sh` is mode 644 |
| REQ-006 | `docs/features/script_tests/FINDINGS.md` (new) |
| REQ-007 | `docs/PHASE_6_NATIVE_PARALLELISM.md` (§P6.3 closure appended below the existing Superseded note) |
| REQ-008 | `README.md` (version, `Scripts (4)`→`(5)`, Testing section), `CHANGELOG.md` (v2.7.0) |

No file appears in more than one parallel batch.
