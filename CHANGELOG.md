# Changelog

All notable changes to this multi-agent orchestration system are documented in this file.

## [2.15.0] - 2026-09-04

### Caveman Mode for omp, Deployed Via `sync-omp-config.sh`

A self-owned omp (oh-my-pi) port of [jonjonrankin/pi-caveman](https://github.com/jonjonrankin/pi-caveman), whose injected rules track the canonical upstream skill from [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) rather than a hand-copied snapshot.

- **New `omp-extensions/caveman/`** — a self-contained omp extension: `/caveman` command (toggle, set level, `config` dialog), the upstream level taxonomy (`lite`/`full`/`ultra`/`wenyan-lite`/`wenyan-full`/`wenyan-ultra`), an animated campfire status bar, session-persistent level, and auto-activation on every new session. Ported from pi-caveman with three changes: imports target `@oh-my-pi/pi-coding-agent`/`@oh-my-pi/pi-tui`, config resolves via `getAgentDir()` (`~/.omp/agent/caveman.json`), and the prompt is loaded from a vendored file instead of inline strings.
- **Rules tracked from upstream.** `omp-extensions/caveman/prompts/caveman.SKILL.md` is a verbatim vendored copy of `skills/caveman/SKILL.md` in JuliusBrussee/caveman. The extension reads it at runtime, strips the YAML frontmatter, injects the body, and appends the active level. `before_agent_start` therefore always injects the canonical definition.
- **New `scripts/update-caveman-prompt.sh`** re-pulls the upstream skill into the vendored path (curl, with a `name: caveman` frontmatter sanity guard that refuses to overwrite a good copy with a 404 body). `--check` exits 3 when the vendored copy is stale — a CI drift gate. Exit codes: 0 up-to-date/updated · 2 usage · 3 stale · 1 missing curl · 4 fetch failed · 5 failed sanity guard.
- **`sync-omp-config.sh`** now overlays every package under `omp-extensions/` into `<OMP_HOME>/agent/extensions/<name>/` (which omp auto-discovers) and seeds `<OMP_HOME>/agent/caveman.json` from the extension's `caveman.default.json` **only when absent**, so a fresh install starts in caveman mode without ever clobbering a chosen level. On `--apply` it first refreshes the vendored prompt from upstream via `update-caveman-prompt.sh` (best-effort — an offline or failed fetch is non-fatal and deploys the committed copy); dry runs never refresh. Skip extensions with `--no-extensions`, the refresh with `--no-update`.
- **Tests.** New `scripts/update-caveman-prompt.test.sh` (8 cases, network-free via `file://` fixtures). `scripts/sync-omp-config.test.sh` gains 8 cases (16 → 24): extension deployed verbatim, settings seeded when absent, seed never clobbers an existing file, `--no-extensions` skips both, and the upstream refresh is invoked on apply / suppressed by `--no-update` / never run on dry-run / non-fatal on failure. Script count 7 → 8.

## [2.14.1] - 2026-08-27

### Fix: Two Flaky Tests Introduced in 2.14.0

Both passed standalone and failed only under `scripts/run-tests.sh`, where the machine is loaded — so they were green when written and red on the merged branch. Both were defects in the tests, not the code under test, and both are now deterministic rather than merely retimed.

- **`statusline/statusline-command.test.sh` — the `fmt_reset` relative-time assertions raced the clock.** The fixture computed `now + 5400` and then asserted the render matched `in 1h3[0-9]m`, but the script recomputes `now` after the fixture is built: once a single second elapses the value is `5399`, which renders `1h29m` and fails the pattern. Under a loaded full-suite run that second always elapses. The assertions now check the *branch* (an `in XhYYm` relative form) rather than exact arithmetic, and are verified against a deliberately injected 90-second clock skew. They also report the actual render on failure — previously they printed a stale global from an earlier test, because the helper runs in a command substitution and its assignment never reaches the parent shell.
- **`statusline/token-stats.test.sh` — the lock-takeover test polled for the lock from outside.** It waited for the lock directory to appear and then swapped the owner, so under load the run could finish before the poll landed and the test failed for a reason unrelated to the invariant. The takeover is now performed by the `jq` wrapper from *inside* the critical section, which removes the race entirely. Mutation-verified: removing the release-side ownership check still fails the test.

## [2.14.0] - 2026-08-27

### Rich Status Line, Deployed Via `sync-claude-config.sh`

- **New `statusline/` directory (5 scripts, 5 test suites):** `statusline-command.sh` (the `statusLine.command` entrypoint — model/effort/⚡fast-mode, clickable repo/branch/PR-or-MR, context-window usage with a computed cache-hit rate on line 1, session cost on line 2), `fetch-usage.sh` (calls the same `api.anthropic.com/api/oauth/usage` endpoint `/usage` uses, retrying 429/5xx with `Retry-After`), `usage-refresh.sh` (populates `usage-cache.json` — 5h/7d rate limits, credit spend — atomic mkdir lock, single-flight across sessions, backoff on throttling), `mr-refresh.sh` (optional GitLab MR number/link via `glab`, same lock pattern), and `token-stats.sh` (sums a session's cumulative token usage, incl. subagents, and derives context length from the newest main-chain transcript entry).
- **`scripts/sync-claude-config.sh`:** flat-copies `statusline/*.sh` straight into `$CLAUDE_HOME` (not a `statusline/` subdirectory — the scripts locate each other, and their caches, as siblings in whatever Claude home they were deployed into) and now also merges a top-level `statusLine` settings key (full replace when the repo defines one, same rule as `CLAUDE.md`; a live-only `statusLine` survives untouched when the repo has none) alongside the existing `hooks`/`env` merge.
- **`hooks/*.sh`/`statusline/*.sh` now get the same backup-before-overwrite treatment as the overlay dirs** (see `2.11.2` below) — any live hook or status-line script a sync is about to overwrite is copied under `<CLAUDE_HOME>/backups/sync-<timestamp>/` first.
- **Root `settings.json`:** gains the `statusLine` key and a `SessionStart` hook (`usage-refresh.sh --force`, backgrounded) that refreshes the usage cache regardless of its age, since a login rotates the OAuth token and may change plan. (`--force` skips the freshness gate only — a throttle backoff is always honored; see the review fix below.)
- **`token_history/` cache relocation:** per-session token stats move from a flat `~/.claude/.tokstats-<session_id>.json` (all projects mixed together) to `~/.claude/token_history/<project-slug>/<session_id>.json` — one subdirectory per project, named from Claude Code's own transcript directory slug (no separate repo lookup needed). `token-stats.sh` now `mkdir -p`s its output directory and scopes its 7-day cleanup sweep to that project's own subfolder.
- The design doc this ships from, `~/claude-statusline-PRD.md`, is updated to match (file paths, install steps via this repo, "Last verified" date).
- **Fix:** the `hooks/*.sh` and `statusline/*.sh` flat-copy globs also matched `*.test.sh`, so dev-only test suites were being deployed alongside the real scripts into a live `~/.claude` (harmless clutter — nothing there ever executes them — but deadweight). Both loops now skip `*.test.sh`.
- **Fix:** the `hooks`/`env`/`statusLine` settings.json merge deduped by whole `.hooks`-array equality, not by individual command. A live event that bundles multiple commands into one hand-merged group (discovered live: `SessionStart` running a local hook + `usage-refresh.sh` together) was treated as unrelated to the repo's own single-command group for that same command, so every sync appended a duplicate group — running that command twice on every session start. The merge now skips a repo group only when every one of its commands already appears somewhere in the live groups for that event.

### PR Review Fixes (Codex, PR #37)

- **Fix (`scripts/sync-claude-config.sh`):** the command-level hook dedup (above) was itself all-or-nothing per repo group — a repo group `[A, B]` where live already had `A` (in some other group) but not `B` appended the *whole* group anyway, re-duplicating `A`. Now filters each repo group down to just its missing commands before appending, dropping the group entirely if nothing is left.
- **Fix (`scripts/sync-claude-config.sh`):** that same dedup keyed on command text alone, so the same command under two *different* matchers (live runs `X` under `matcher: "Edit"`, repo wants `X` under `matcher: "Write"` too) was wrongly treated as already covered and dropped — `X` would never run for `Write`. Now keys on the (command, matcher) pair.
- **Fix (`scripts/sync-claude-config.sh`):** deploying to an explicit alternate `CLAUDE_HOME` (a documented use of this script, not just for tests) copied repo-authored hook/statusLine commands verbatim, still hardcoding the literal `"$HOME"/.claude/...` text — telling Claude Code to run the deployed scripts from the *default* location instead of wherever they actually just landed. Now rewrites that literal prefix to the real target when `CLAUDE_HOME` differs from the default; the default deploy path is unaffected (keeps the portable, unexpanded `"$HOME"` form).
- **Fix (`statusline/fetch-usage.sh`):** `get_token()`'s credentials-file branch returned as soon as `jq` exited 0, even when the extracted token was empty (a valid-JSON file missing every recognized field) — permanently blocking the Keychain fallback. Now only returns early on an actual non-empty token.
- **Fix (`statusline/mr-refresh.sh`, `statusline/statusline-command.sh`):** the `.mr-cache.json` MR lookup was keyed only by branch name, so (a) two different repos sharing a branch name could show/reuse each other's cached MR, and (b) switching branches within the cache's 10-minute freshness window left the new branch showing no MR (the stale-check only looked at mtime, not which branch the cache was actually for). The cache now also records repo identity (`origin` remote URL, falling back to the repo root path); both the freshness check and the display check require branch **and** repo to match.
- **Fix (`statusline/token-stats.sh`):** subagent transcripts were summed by passing every `agent-*.jsonl` file to one `jq` invocation, so the streaming-dedup rule ("keep a trailing `stop_reason:null` row") only protected whichever file `find` happened to list last — any other concurrently-streaming subagent's own pending trailing row was silently dropped, undercounting tokens/cost. Now runs the sum filter once per file and adds the per-file results.
- **Fix (`statusline/usage-refresh.sh`):** `iso2epoch`'s BSD fallback only stripped fractional seconds (`${1%%.*}`) before parsing with the fixed format `%Y-%m-%dT%H:%M:%S`, which has no timezone directive. A `resets_at` with a trailing `Z` and no fractional seconds (e.g. `2026-08-26T18:00:00Z`) has no `.` for that strip to trigger, so real BSD `date -j -f` rejects the leftover `Z` and the 5h/7d reset epoch silently comes back null. Now also strips a trailing `Z` or numeric UTC offset.
- **Fix (`statusline/statusline-command.test.sh`):** two of this suite's own MR-cache tests relied on the real `glab` binary being on `PATH` rather than stubbing it, violating this repo's own offline/stub testing convention — they failed in an environment without `glab` installed even though the runtime behavior under test was correct. Now stub `glab` on `PATH` like every other suite that needs it.
- **Fix (`statusline/statusline-command.sh`, `usage-refresh.sh`, `mr-refresh.sh`, `fetch-usage.sh`):** the settings.json path rewrite above got an alternate-`CLAUDE_HOME` install *starting* correctly, but every runtime path inside the scripts was still hardcoded to `$HOME/.claude` — so such an install read the **default** home's caches and looked for its helper scripts (`mr-refresh.sh`, `token-stats.sh`, `usage-refresh.sh`, `fetch-usage.sh`) somewhere they were never deployed: usage, token, and MR data never refreshed at all. All four scripts now resolve their own Claude home — an explicit `CLAUDE_HOME` wins, else the script's own directory when a sibling `settings.json` marks it as a deployed Claude home, else `$HOME/.claude` (the default install, and the repo checkout). `fetch-usage.sh` checks the deployed home's `.credentials.json` first, then the default home, before the Keychain — an alternate-home deploy may hold config only, with the OAuth login still in `$HOME/.claude`.
- **Fix (`statusline/token-stats.sh`):** the streaming-dedup rule was gated on a *file-level* `any(.message | has("stop_reason"))` probe. In a transcript that mixes schemas — older rows with no `stop_reason` field at all, newer rows carrying it, e.g. a session spanning a client upgrade — one field-bearing row flipped **every** row into field-aware mode, where an absent field reads as `null` and the row is discarded as a streaming intermediate. That silently dropped every fieldless billable row except whichever one happened to land last, undercounting session tokens and cost. Dedup is now decided per row: field absent → finalized (that schema never emitted one), present and truthy → finalized, present and `null` → streaming intermediate, kept only as the file's last row. This matches what the `context_length` filter already did.
- **Fix (`scripts/sync-claude-config.sh`):** the alternate-`CLAUDE_HOME` rewrite spliced the target path into the command string raw, dropping the quoting that had protected the original `"$HOME"/.claude` prefix — a `CLAUDE_HOME` containing a space or shell metacharacter produced a command the shell word-split and could not execute. The path is now shell-quoted via `jq`'s `@sh` before substitution.
- **Fix (`statusline/mr-refresh.sh`, `statusline/statusline-command.sh`):** scoping the MR cache to repo+branch (above) stopped the *wrong* MR from being shown, but left one global entry that every session overwrote: two concurrent sessions on different repos or branches each rejected the other's entry, launched a refresh, and clobbered it — so both could sit in a loop showing no MR link while repeatedly querying GitLab. `.mr-cache.json` is now an object keyed by `"<repo>\t<branch>"`, one entry per pair, with per-entry `ts` freshness (file mtime is no longer used — another session's write to a different key bumps it without making this entry any fresher). Writes merge only the session's own key and prune entries older than 24h; a pre-upgrade flat-format cache file is detected and discarded rather than carried forward malformed.
- **Fix (`scripts/sync-claude-config.sh`):** the hook dedup key was `(command, matcher)`, ignoring the group-level `if` predicate — so the same command+matcher under a *different* `if` was treated as already covered and dropped, and would never run under the repo's intended condition. This repo's own `settings.json` relies on exactly that shape (`enforce-git-conventions.sh` under `matcher: "Bash"` **and** `if: "Bash(git *)"`). The key is now the whole group metadata minus its command list, so `matcher`, `if`, and any trigger field Claude Code adds later all count. Empty and null values are normalized away, so an explicit `matcher: ""` and an absent matcher dedup as the same trigger rather than duplicating on every sync.
- **Fix (`scripts/sync-claude-config.sh`):** *upgrading* an existing alternate-`CLAUDE_HOME` install left the hook duplicated. Its live `settings.json` still held commands written before the path rewrite existed (the literal `"$HOME"/.claude/...` form) while the repo side was now rewritten to the alternate path — the same hook, no longer comparing equal, so the rewritten one was appended and the obsolete default-home one stayed active: the command ran twice, once from a path where nothing was ever deployed. A live command is now migrated in place to its rewritten form when — and only when — that rewritten form matches a repo-authored (command, trigger) pair, which means it *is* that hook's previously-deployed copy. Live-only hooks the user pointed at their default home keep the path they were given.
- **Fix (`statusline/usage-refresh.sh`):** `iso2epoch`'s BSD fallback *deleted* the timezone suffix before parsing, so `date -j -f "%Y-%m-%dT%H:%M:%S"` read the remaining wall clock in the machine's **local** timezone — on any host outside UTC a `...T18:00:00Z` reset came out shifted by the local UTC offset (4h out in EDT) and the status line showed the wrong reset time. The zone is now split off and parsed explicitly: `Z` → `-u` (read as UTC), a numeric offset → a matching `%z` directive, no zone → local time (the correct reading of a zone-less stamp). Fractional seconds are stripped only *after* the zone is removed, since `${v%%.*}` cuts to the end of the string and would otherwise swallow an offset that follows the fraction.
- **Fix (`statusline/usage-refresh.test.sh`):** this suite's own BSD-`date` stub forced `-u` when parsing, interpreting every zone-less stamp as UTC — which is exactly what hid the local-time bug above. The stub now honors `-u` instead of forcing it (matching real BSD behavior), understands the `%z` format, and the suite runs under a deliberately non-UTC `TZ` asserting the exact epoch, so a misparse surfaces as a concrete offset error rather than merely "something non-null parsed".
- **Security fix (`statusline/fetch-usage.sh`) — OAuth bearer token was exposed in `curl`'s argv.** `-H "Authorization: Bearer $tok"` placed the token on the command line, where it is readable by other users on the host (`ps`, `/proc/<pid>/cmdline`) and by any process-monitoring agent, for the lifetime of every request. The token is now passed to curl on **stdin** via `-H @-`. `printf` is a bash builtin, so the secret never becomes another process's argv either, and the pipe is an anonymous fd — nothing touches disk. Non-secret headers stay on the command line, where they still document the request. Verified end-to-end against a local listener with real curl: the `Authorization` header arrives intact, and a concurrent `ps` sweep during the request finds no token in argv.
- **Security fix (`statusline/fetch-usage.sh`) — predictable world-writable temp path.** Response headers were written to `/tmp/.usage-hdrs.$$`: `/tmp` is world-writable and a PID-derived name is guessable, so another user could pre-create that path as a symlink and have curl clobber whatever it pointed at. The observed files were also mode `0644`. Now created with `mktemp` (mode `0600`) and removed by an `EXIT` trap — the old `rm -f` ran only on the success path, so a retry that gave up, or any signal, left the file behind. Not part of the review finding; found while fixing the argv exposure in the same block.
- **Fix (`statusline/fetch-usage.test.sh`):** the `curl` stub recorded neither argv nor stdin, so it could not have caught either issue above. It now records both per call, and the suite asserts the token is **absent from argv** *and* **present on stdin** — both directions, so the test cannot pass by the header silently not being sent at all — across every retry attempt, plus that the header temp file is neither predictably named nor left behind (including when retries are exhausted).
- **Fix (`statusline/usage-refresh.sh`, `mr-refresh.sh`, `token-stats.sh`) — the single-flight lock could admit concurrent runs.** All three used a purely time-based staleness check (`>120s` → `rmdir`) plus an *unconditional* `rmdir` trap on exit, which is unsafe on both sides of the critical section: a run that legitimately outlived the threshold had its **live** lock reclaimed, starting a second concurrent run; the original then exited and its trap deleted whichever **newer** process now held the lock, admitting a third — and concurrent writers then raced on a single fixed `*.tmp` path, so one could publish a partially-written cache. The lock directory now records the holder's PID in an `owner` file: a lock is reclaimed only when its recorded owner is gone, and released only while this process still owns it. A hard age ceiling bounds the pathological case where the owner's PID was recycled by an unrelated live process, which would otherwise wedge the lock permanently. Temp files are now per-PID (`*.tmp.$$`) so a race cannot interleave two writers into one file. Codex raised this against `usage-refresh.sh`; the identical pattern was present verbatim in the other two, and `mr-refresh.sh` shares the same trigger (`glab` does network I/O), so all three were fixed together.
- **Fix (`statusline/fetch-usage.sh`, `mr-refresh.sh`):** neither network call had a time limit, which is what made "a run outlives the staleness threshold" reachable in the first place. `curl` now runs with `--connect-timeout 10 --max-time 30`. The `glab` lookup is wrapped in `timeout 30` **when available** — `timeout` is GNU coreutils and is not on a stock macOS, so it is used only if `timeout` or `gtimeout` is on `PATH`, with the owner-aware lock as the backstop otherwise.
- **Fix (`statusline/usage-refresh.test.sh`, `mr-refresh.test.sh`, `token-stats.test.sh`):** each suite's lock coverage only exercised the no-owner path, so none could have caught the above. All three now also assert that a lock owned by a **live** process is never reclaimed however old it is, that a **dead** owner is still reclaimed (no deadlock), and that no temp file is left behind; the `usage-refresh` suite additionally covers the release side — a process whose lock is taken over mid-fetch must not delete the new owner's lock. Verified against a design-faithful reproduction: the old unconditional trap destroys the new holder's lock, the owner-checked release preserves it.
- **Security fix (`statusline/mr-refresh.sh`, `statusline-command.sh`) — a credential-bearing remote URL was persisted into the MR cache.** Repo identity comes from `git remote get-url origin`, and credential-embedding HTTPS remotes are common (a PAT or CI token, e.g. `https://TOKEN@gitlab.com/group/repo.git`). The raw URL was written to `.mr-cache.json` as **both** the JSON key and the `repo` field, copying the token into a long-lived, predictably-named file created at the ambient umask (observed `0644`). URL userinfo is now stripped before the value is used as an identity, cutting only the **authority** component — an `@` can legitimately appear in a path, and cutting there would mangle unrelated identities. `statusline-command.sh` carries the same function because it looks up the key that `mr-refresh.sh` writes: any divergence would turn every lookup into a silent miss (no MR link, and a refresh fired on every render). The cache is now created mode `0600` via `umask 077`, and entries left by earlier versions whose identity carries userinfo are **actively purged** on the next write rather than lingering until the 24h age-based prune.
- **Fix (`statusline/mr-refresh.test.sh`, `statusline-command.test.sh`):** added coverage for a credential-bearing origin (the token must appear nowhere in the cache; key and `repo` must be the sanitized URL), for the file mode, for an `@` inside the URL *path* being preserved rather than cut as userinfo, for purging a credential-bearing entry written by an earlier version, and a cross-script round-trip that runs the real `mr-refresh.sh` and then `statusline-command.sh` against a tokenized remote — proving writer and reader derive the same identity, and that the token reaches neither the cache nor the rendered status line.
- **Fix (`statusline/usage-refresh.sh`) — `--force` bypassed the throttle backoff, so every new session re-hammered a throttled endpoint.** `--force` exists because a login rotates the OAuth token and may change plan, making the cache wrong however recently it was written — that is a reason to skip the *freshness* gate. It was also skipping the *backoff* gate, which exists for the opposite purpose: to stop N sessions from hitting an endpoint that just returned 429. Since the `SessionStart` hook runs `--force`, and `SessionStart` fires on every start/resume/clear rather than only on an OAuth login, each staggered session during a cooldown would immediately drive another full three-request retry cycle. `--force` now skips only the freshness gate; the backoff gate is always honored. Regression test covers both halves — `--force` blocked during an active cooldown, and still bypassing freshness once the window has expired — plus the README/CHANGELOG wording that described the old semantics.
- **Fix (`scripts/sync-claude-config.sh`) — hook-level execution metadata could never be deployed.** The dedup key is `(command, trigger)`, which correctly prevents duplicate appends, but it silently blocked *updates* too: `type`, `async`, `timeout`, and `statusMessage` are not part of a hook's identity, so once a command existed live the repo could never change any of them. This bit the repo's own config — `auto-test-runner.sh` ships `async: true, timeout: 300`, and a live copy lacking those would have stayed synchronous forever. A live hook matching a repo hook on (command, trigger) now **adopts the repo's hook object**, so the metadata is updated in place rather than the repo hook being dropped. Repo wins, the same rule as `statusLine` and `CLAUDE.md`, and the live file is still backed up before any write. Only the matching hook object is replaced, so a multi-command live group keeps its other commands, its own group metadata, and any live-only hook's own settings.
- **Fix (`statusline/mr-refresh.sh`, `statusline-command.sh`) — a failing MR lookup was retried on every render.** When `glab` is installed but the lookup fails (auth error, network down, unknown host, timeout), the script exited without writing anything. The reader therefore saw no fresh entry and relaunched it on *every* status-line render (~30s), respawning the failing CLI and re-hitting the network indefinitely. A failed lookup now records an entry marked `failed`, which both sides treat as fresh for a shorter `FAIL_COOLDOWN` (120s) rather than the 600s success window — long enough to stop the per-render storm, short enough that a transient failure does not hide a real MR. A successful retry clears the marker. The cache write is now a single shared function, so the success and failure paths cannot drift apart on pruning or credential-purging.
- **Fix (`scripts/sync-claude-config.test.sh`, `statusline/mr-refresh.test.sh`, `statusline-command.test.sh`):** added coverage for deploying `async`/`timeout`/`statusMessage` onto an existing live hook without duplicating it or disturbing a multi-command group; and for the failure cooldown on both sides — a failed lookup writes a marked entry, a second run inside the cooldown does not re-invoke `glab`, an expired one does retry, and a success clears the marker. The expiry cases deliberately backdate to 300s: past the 120s failure cooldown but still inside the 600s success window, so only the failure-specific window can explain the retry. Both fixes verified to fail against a pre-fix variant.
- **Fix (`statusline/usage-refresh.sh`, `mr-refresh.sh`, `token-stats.sh`) — reclaiming an abandoned lock was not mutually exclusive.** Two processes could both pass the owner/age checks, and the second one's `rm -rf` then destroyed the lock the first had already reclaimed and recreated — putting both inside the critical section and racing the cache write. An atomic rename is *not* sufficient here, which is worth recording: the lock is identified by path, not identity, so a contender that decided "abandoned" a moment earlier will tear down the brand-new lock a winner has since created at that path; `rename(2)` only guarantees that one rename of one directory instance wins. The whole decide-and-reclaim is now serialized on its own atomic `mkdir`, with the owner re-read *under* it, so a process that reclaimed while we waited is correctly seen as a live owner. The reclaim also re-checks its `mkdir` result, since a fast-path acquirer can slip in between the `rm` and the recreate — in which case it owns the lock and we must not overwrite its `owner` file. A concurrency test launches six real contenders at one abandoned lock and requires exactly one to enter the critical section; both earlier forms (plain `rm -rf` and the rename attempt) admit 2–3 of 6 on every run.
- **Fix (`statusline/usage-refresh.sh`) — only a 429 recorded a cooldown, so other persistent failures were hammered.** A 401, 5xx, unreachable host, or a `fetch-usage.sh` that exits nonzero (no token found) left both the stale cache and the backoff untouched, so `statusline-command.sh` saw a stale cache and relaunched the refresh on every ~30s render — each run driving `fetch-usage.sh`'s full three-attempt retry cycle against an already-failing endpoint, indefinitely. Every failure now records a bounded cooldown, and the backoff file carries its *kind*: `throttle` (a 429, 300s) or `error` (anything else, 120s). `--force` may bypass an `error` cooldown but never a `throttle` one — a 429 is the server instructing us to stop and must be honored no matter who asks, whereas an error cooldown is our own rate limiting and a login is precisely the event that fixes a 401, so making `--force` wait it out would leave the status line stale right after the user fixed the problem. A kind-less backoff file (written by an earlier version) is read as `throttle`, the conservative choice. `set_backoff` now does plain epoch arithmetic, dropping the `date -d` / `date -v` GNU-vs-BSD fallback pair.
- **Fix (`statusline/usage-refresh.test.sh`):** `set_backoff` wrote no trailing newline, so `read` returned nonzero at EOF and — under the suite's `set -e` — aborted the whole run silently with no failing assertion. The writer now emits a newline and the suite's reads are guarded. Added coverage for every non-429 status recording an `error` cooldown while leaving the last-good cache alone, for a failing `fetch-usage.sh` doing the same, for the kind-aware `--force` split in both directions, for the legacy kind-less file, and for the lock-reclaim concurrency invariant above.
- **Fix (`statusline/statusline-command.sh`) — self-inflicted regression from the typed-backoff change above.** That change gave `.usage-backoff` a `<until_epoch> <kind>` format and updated the reader inside `usage-refresh.sh`, but missed the *second* reader here, which `cat`s the whole line into `-ge`. Two fields is an integer-expression error, so the condition never fired: once any cooldown had ever been written the automatic usage refresh stayed suppressed permanently, including long after the window expired, leaving the cache stale until a forced refresh or manual cleanup. The reader now takes only the epoch field and validates it is numeric. The regression test drives the backoff file from the **real** `usage-refresh.sh` (via a 429) rather than hand-writing it, so the two scripts are asserted to agree on the format instead of a literal being pinned that could drift from the writer.
- **Seam audit (no further changes needed).** Prompted by the above, every cross-script shared format and constant was checked directly: the four copies of `resolve_claude_home` are byte-identical; the two copies of `sanitize_repo_id` differ only in comments, not behavior; the MR freshness windows (600/120) and the usage freshness window (600) agree on both sides. The backoff format was the only genuine divergence.
- **Fix (`statusline/token-stats.sh`) — a torn trailing transcript row zeroed the whole session.** Transcripts are appended to *live*, so the final line is frequently a partially written object. `jq` aborts the entire parse on that, and the zero fallback then replaced every valid row with zeros — publishing a zeroed session to the cache, which silently misreports token counts and cost rather than looking broken. Reproduced: a transcript with 3000 valid input tokens plus a half-written trailing row returned 0. Each file now goes through a `jq -c .` pre-pass that emits every row which parses and stops at the first that does not, so a torn trailing row costs only itself; applied to the main transcript, the `context_length` pass, and each subagent file. As a second layer, a populated cache is never replaced by an all-zero one — a session's cumulative totals only grow, so zeros mean the read failed, and serving the last good figures beats misreporting. A brand-new session with genuinely zero usage still writes its cache.
- **Rebased onto `main`'s v2.13.0** (`sync-omp-config.sh`), which also touched `scripts/sync-claude-config.sh`. The overlapping regions were merged by hand rather than taking one side: `main`'s symlink hardening and whole-directory hook snapshots are kept, and the same symlink handling was extended to the new `statusline/*.sh` flat-copy loop, which lands files in `$CLAUDE_HOME`'s root and has the identical write-through-a-link exposure. `main`'s richer collide test (live-only hook survival, whole-directory snapshot, symlink preservation) is kept whole with the statusline copy style folded into it. Version renumbered 2.12.0 → **2.14.0** to sit above `main`'s 2.13.0.
- **Fix (`statusline/token-stats.sh`) — a malformed row mid-file truncated the tail.** The previous fix parsed each transcript with a single whole-stream `jq -c .`, which stops at the first row that will not parse. That is not only a torn-*tail* problem: resuming an interrupted session appends valid rows **after** the partial one, so the damaged row ends up mid-file and the session silently stops accumulating from there on, permanently. `rows()` now uses `jq -Rc 'fromjson?'` — each line is read as a raw string and parsed individually, with the `?` swallowing the error for a line that will not parse — so only the bad row is lost and every other row still counts. Still one jq process per file, so O(n). Verified: a transcript of 1000 + 2000 + torn + 4000 + 8000 returned 3000 before and 15000 after.
- **Fix (`statusline/usage-refresh.sh`) — a 200 whose body could not be parsed left no cooldown.** The backoff was cleared as soon as the status was 200, *before* the cache had actually been written. A malformed body, or an unexpected field that makes `tonumber` fail, therefore left the cache stale with nothing to stop `statusline-command.sh` relaunching the refresh on every ~30s render, and leaked a temp file each time. The cooldown is now cleared only after the cache is successfully written; a parse or write failure records an `error` cooldown, removes the partial temp file, and leaves the last-good cache in place. The body-field `jq` extractions also had their stderr silenced, since a malformed body is now an expected path rather than an anomaly.
### Whole-PR Review Fixes (structural pass, not line-level)

After 14 rounds of line-by-line automated review, the PR was reviewed as a whole. That surfaced nine defects a per-diff-line reviewer structurally cannot see — four of them introduced *by* the earlier review-round fixes. All were reproduced before fixing and are covered by regression tests.

- **Security (`statusline/token-stats.sh`) — the cleanup sweep could delete the user's global config.** `find "$(dirname "$out")" -name '*.json' -mtime +7 -delete` trusted a path built from `basename "$(dirname "$transcript")"`, which yields `..` for a transcript path like `/a/b/../s.jsonl` — escaping `token_history/` into the Claude home root. Reproduced: `settings.json`, `usage-cache.json` and `.mr-cache.json` were all deleted. The script now refuses an `out` path containing a `..` component, the sweep runs only inside a directory under a `token_history/` component, and the caller validates both the project slug and the session id against a conservative charset.
- **Security (`statusline-command.sh`, `mr-refresh.sh`) — arithmetic injection.** An unvalidated `ts` from `.mr-cache.json` reached `$(( ))`, and bash evaluates the *value* as an arithmetic expression: `x[$(cmd)]` executes `cmd` via the array-subscript rule, on every ~30s render. Reproduced end-to-end. Requires write access to a 0600 file, so it is a post-compromise persistence primitive rather than initial access — but every arithmetic sink now coerces through one `int_or0` guard (which also strips leading zeros, since bash reads those as octal).
- **`file_age`/`age` (5 copies) — the mtime fallback returned junk on a GNU-coreutils host.** `stat -c %Y … || stat -f %m …` assumed the fallback fails quietly. GNU `stat -f` means `--file-system`: it exits **zero** and prints a multi-line filesystem report to stdout, so `|| echo 0` never fired. Under `set -u` the helper then aborted and returned empty — which made **both** lock guards false and reclaimed a lock whose owner was still running, defeating the single-flight invariant the previous rounds were spent establishing. All five sites now validate the result numerically.
- **`statusline-command.sh` — the Session line showed a real dollar amount beside fabricated zeros.** The segment reads `m_*`/`a_*`, while the intended current-response fallback was being written to `t_in`/`t_out`/`t_cr`/`t_cw` — variables orphaned when the standalone Tokens segment was removed. Rendered `$1.50 — main $1.50 (0 in · 0 out · 0 cache-r · 0 cache-w)` on every session before the first cache write. The fallback now populates the variables actually consumed; the orphans are deleted.
- **`statusline-command.sh` — `token-stats.sh` was respawned on every render.** Its failure paths exited without writing a cache, and the caller treats "no cache" as stale, so a missing or unparseable transcript produced an unbounded spawn loop (measured: 5 renders → 5 launches). It now writes a `failed` marker, matching the negative-caching its two sibling refreshers already had. Measured after: 5 renders → 1 launch.
- **`scripts/sync-claude-config.sh` — a hook could be registered twice (regression vs `main`).** Including the group `if` predicate in the dedup key meant a live group predating a newly-added `if:` read as a *different* trigger, so the repo group was appended and the stale one kept. This repo's own `enforce-git-conventions.sh` ended up firing on every Bash call as well as under `Bash(git *)`. The merge is now one rule — **the repo owns the complete trigger set for its own commands** — which replaces the previous dedup + metadata-adoption + path-migration stack and also makes removing or re-targeting a repo hook work at all. Deliberate consequence: a hand-added extra trigger for a repo-shipped hook is replaced on sync, matching how `CLAUDE.md` and `statusLine` already deploy; hooks the user wrote themselves are untouched.
- **`scripts/sync-claude-config.sh` — a live hook group with no `hooks` key aborted the merge.** The live side iterated `.hooks` unguarded while the repo side used `?`, so a hand-edited group produced `Cannot iterate over null`, exit 5, and a partial apply with no backup pointer printed.
- **Security (`scripts/sync-claude-config.sh`) — `CLAUDE.md` and `settings.json` were written *through* a symlink.** The script already defends the overlay directories, hooks and statusline against this; these two paths were the gap, so an `--apply` clobbered a file outside `CLAUDE_HOME` and left the link in place. Both now back the link up as a link and replace it with a real file.
- **`statusline-command.sh` — the PR/MR number was gated on a non-empty branch name.** `.pr.number` comes from the stdin JSON and needs no git, but the whole block sat inside `if [ -n "$branch" ]`, so a detached HEAD, a mid-rebase checkout, or a non-repo `cwd` silently dropped the link. Resolution and rendering now sit outside the branch guard; only the branch *name* and the branch-keyed MR cache lookup remain git-dependent.
- **Hardening:** `umask 077` extended to `usage-refresh.sh` and `token-stats.sh` (their caches carry plan tier, credit spend and per-project paths; `mr-refresh.sh` already had it); unguarded `printf "%.0f"` conversions no longer leak `invalid number` to the terminal; dead `model_id` read, a duplicated `pr` read, and four orphaned `t_*` reads removed, and `now` is computed once so both output lines share a clock — together cutting ~130ms off each render.
- **Test-quality fixes** prompted by the same pass: `run_statusline` captured its output from a pipeline under `set -euo pipefail` without checking status, so a nonzero exit killed the largest suite **silently, with no failing assertion** — the third instance of that shape in this PR. It now asserts the exit status. Also fixed: a vacuous `[ ! -e "" ]` leak check that tested nothing, eight `VAR=$(find … | head -1)` extractions with the same silent-exit shape, and a dead assertion whose `fail` branch was unreachable. The `glab` stub now records argv and cwd (it previously ignored both, so a wrong `--source-branch` or a dropped `cd` was invisible — the same gap the `curl` stub was fixed for), and the duplicated MR freshness windows are now asserted equal across reader and writer, since a code comment claimed they must match and nothing checked it.
### Test-Suite Audit Fixes

An audit of the ~2400 lines of new test code ran 40 targeted source mutations to find assertions that could not fail. Every fix below was verified by re-running the mutation and confirming it is now caught.

- **Two runtime defects the test gaps were concealing:**
  - **`statusline/fetch-usage.sh` — a transport failure got zero retries while a 5xx got three.** On a DNS failure, refused connection, or `--max-time`, curl exits nonzero and prints no status trailer, so `code` was empty and both HTTP tests were false — the script broke out after one attempt. The commonest transient failure was the least tolerated. curl's exit status is now checked alongside the HTTP status; measured 1 → 3 attempts, and a transient failure now recovers on retry.
  - **`statusline/statusline-command.sh` — malformed stdin emitted ~24 `jq: parse error` lines** straight into the terminal, on every render, because each of the 26 field reads parsed the payload independently. The payload is now validated once and falls back to an empty object. Also gave `model.display_name` and `cwd` defaults — the only two reads without one, which rendered the literal string `null`.
- **The lock body was tested in 1 of the 3 files carrying it.** Removing the release-side ownership check or the reclaim serialization from `mr-refresh.sh` or `token-stats.sh` left the suite green. Both now have coverage, and all four mutations are caught. `token-stats` is tested deterministically rather than by racing: it has no under-lock freshness re-check (correctly — its lock is per-session-file), so contenders running one-after-another is valid and a winner count proves nothing; the reclaim lock and the ownership-checked release are set up directly instead.
- **The `curl` stub had no failure mode** (always exited 0 with a status trailer), so the retry asymmetry above was unexpressible. It now models a transport failure. Added with it: the `Retry-After` cap — previously unpinned, so a server sending `Retry-After: 86400` would have slept for a day *while holding the single-flight lock* — and the `--connect-timeout`/`--max-time` flags.
- **The `date` stub could not run on stock macOS.** Its BSD branch delegated to `date -d`, the very GNU-only flag the branch exists to work around — so the test covering the BSD `iso2epoch` fallback only passed on hosts with GNU coreutils, the one platform where that fallback is *not* the live path. It now converts in `python3`; the suite passes under a `/usr/bin:/bin` PATH where `date` is genuinely BSD.
- **The `glab` stub ignored argv and cwd entirely**, so a wrong `--source-branch` or a dropped `cd "$cwd"` was invisible — the same gap the `curl` stub was fixed for earlier in this PR. It now records both, and the invocation contract is asserted.
- **Silent-exit shapes.** `run_statusline` captured its output from a pipeline under `set -euo pipefail` without checking status, so a nonzero exit killed the largest suite with **no failing assertion** — the third instance of that shape in this PR. Fixed there and in eight `VAR=$(find … | head -1)` extractions, which fired precisely when the thing under test had regressed. Also removed a vacuous `[ ! -e "" ]` leak check (true for an empty string, so it asserted nothing) and a dead assertion whose `fail` branch was unreachable.
- **Unpinned constants**, all previously mutable with a green suite: `FRESH` (probed either side of the boundary), `BACKOFF_THROTTLE`/`BACKOFF_ERROR` (magnitude and relative ordering), `PRUNE_AGE` (an entry each side of the threshold), and the MR freshness windows, which are now asserted equal across reader and writer since a code comment claimed they must match and nothing checked it.
- **`token-stats.sh`'s cost model had zero coverage** despite producing the dollar figure on screen — every fixture used one model and the flat cache shape. Now covers all five price tiers plus the unknown-model fallback, output pricing, the 0.1× cache-read multiplier, the 5m/1h TTL split in the nested `cache_creation` shape, and the `<dir>/subagents/` fallback search location. Five mutations that previously survived are now caught. The known `cache_write`-vs-`est_cost` inconsistency for nested-shape transcripts is pinned by a test so it stays a deliberate choice.
- **`fmt_reset`'s near-term branches never executed** — every fixture used a year-2286 reset, so only the `>7d` branch ran and the `resets …` text was never asserted at all. Now covers `<1h`, `<24h`, `<7d`, `>7d` and the past-reset clamp. (The `<7d` assertion checks for a clock: the `>7d` format also starts with a weekday, so a weekday-only match cannot tell the branches apart.) Severity colors are asserted on the raw output, since every other assertion reads an ANSI-stripped copy and the whole mapping was unverifiable.
- **Other untested render paths** now covered: the worktree segment, the repo hyperlink, `.pr.*` taking priority over the MR cache, and malformed/empty stdin.
- **Fix (`scripts/sync-claude-config.sh`) — a repo command moved between hook EVENTS kept its old registration.** The repo-owns-its-commands strip was scoped within an event, so a hook the repo relocated (say `PreToolUse` → `PostToolUse`) was appended under its new event while the stale live registration survived under the old one — firing on both triggers. That is the same defect the rule exists to prevent, one scope up, and it was introduced with the rule itself. Repo-owned commands are now collected across all events and stripped from every live event before the repo groups are appended; an event left with no groups is dropped rather than leaving a bare empty array. Live-only hooks sharing a vacated event still survive.
- **Reviewed, not changed:** a `find -maxdepth 1` finding claimed BSD `find` on macOS rejects `-maxdepth` as GNU-only. Verified false — `-maxdepth` is supported by both BSD and GNU `find`; no fix applied.
- **Reviewed, not changed:** a finding claimed `%-d` is a GNU-only `strftime` modifier that makes BSD `date` fail and `_dfmt` return an empty string. Verified false on macOS 15.7.9: real `/bin/date -r <epoch> '+%a %b %-d'` returns `Wed Aug 5` with exit 0 — correctly unpadded — and `_dfmt` produces the same when run with only `/usr/bin:/bin` on `PATH`, so the BSD branch is genuinely exercised. Apple's `strftime(3)` page does not document the `-` modifier, but the implementation supports it. No fix applied.

## [2.13.0] - 2026-08-27

### `sync-omp-config.sh`: Convert + Deploy Claude Config to oh-my-pi (omp)

- **New `scripts/sync-omp-config.sh` (+ `sync-omp-config.test.sh`, 16 cases):** converts this repo's Claude config to oh-my-pi (omp) format and syncs it into `~/.omp/agent/` (or `$OMP_HOME`). Conversion is **ephemeral** — it runs into a temp staging dir on every invocation and nothing converted is committed; the repo stays Claude-only, the script is the single source of the translation.
- **agents/** require real conversion — omp deliberately skips `~/.claude/agents` (schema mismatch). The script rewrites frontmatter to the omp task-agent contract: `name`/`description` kept, Claude tool names translated to omp names (`Read`→`read`, `Task`/`Agent`→`task`, `AskUserQuestion`→`ask`, `TaskList`→`todo`, `SendMessage`→`hub`, …), `LS`/`mcp__*`/unknown dropped, and Claude-only keys (`model`, `memory`, `maxTurns`, `isolation`, `permissionMode`) stripped. A translated list containing `task` lets omp auto-enable sub-spawning. `--map-models` optionally emits `@good`/`@fast` role aliases (opus/haiku) instead of dropping `model`.
- **skills/** and **commands/** carry over verbatim (already omp-compatible; omp ignores the extra command `model`/`args` keys).
- **hooks/** are bridged by a generated `claude-compat.ts` adapter that maps the mappable Claude hook events to omp events (`UserPromptSubmit`→`before_agent_start`, `PostCompact`→`session.compacting`, `PreToolUse` Bash→`tool_call`, `PostToolUse`→`tool_result`) and shells out to the original `.sh`. `PermissionRequest` (`auto-approve-safe-ops.sh`) has no omp event and is intentionally not wired. Skip the whole category with `--no-hooks`.
- Dry run by default (prints planned changes, touches nothing); `--apply` writes with overlay copy (never deletes live-only files). bash 3.2 compatible.
- **Global adapter omits the project-scoped merge reminder (Codex PR #38):** `pr-merge-sync-reminder.sh` is wired only in the project-scoped `hooks/settings.json` (`PostToolUse Bash(gh *)`), never the global `settings.json` — it points the user at this repo's `sync-claude-config.sh` and is meaningful only here. The generated adapter deploys at omp user scope, so it now mirrors the GLOBAL hook set and no longer wires that reminder; wiring it globally emitted an invalid sync prompt after squash merges in unrelated repos.
- **Whole-directory backup snapshots (both sync scripts):** `sync-omp-config.sh` and `sync-claude-config.sh` now snapshot each modified target directory (agents/skills/commands/hooks — plus rules for the Claude script) as one full directory copy before the first change, instead of backing up individual overwritten files. Rolling back a bad apply is a single recursive restore. A first-ever deploy (no prior state) still writes no backup. Each run's backup path carries a per-process suffix (`omp-sync-<timestamp>-<pid>-<rand>/`, `sync-<timestamp>-<pid>-<rand>/`) so two applies within the same UTC second never collide into one directory and skip a needed snapshot. Copies use `cp -R` (no-follow) so a live symlinked file is backed up as a symlink, not a dereferenced copy (Codex PR #38).
- **Valid YAML for `--map-models` + jq gating (Codex PR #38):** `--map-models` now emits quoted role aliases (`model: "@good"` / `"@fast"`) — an unquoted leading `@` is a reserved YAML indicator that made generated agent files unparseable. Separately, the jq/awk preflight moved after argument parsing; awk stays unconditional but jq is required only for an `--apply` that actually deploys hooks — the converter never calls jq (only the deployed hook scripts do), so `--help`, unknown args, dry runs, and `--no-hooks` syncs no longer require jq on `PATH`.
- **Never follow a symlink into an external target when deploying (Codex PR #38, both scripts):** a live directory where a staged file belongs made `cp` nest the file (`reviewer.md/reviewer.md`); a symlink anywhere on the destination path (the staged file itself, a **nested ancestor** like `skills/demo-skill/`, or the **category root** like `agent/agents`) made `cp` follow the link and overwrite the EXTERNAL referent, with the snapshot capturing only the link. Both overlays now detect a non-regular/symlink component and replace it with a real file/dir before copying — recording a replaced root/link in the backup, leaving the external referent untouched, so the deploy always lands at the intended path and a bad apply stays restorable.
- **Version note:** cut from `main` (2.11.3) alongside the in-flight statusline branch that also claims 2.12.0; took 2.13.0 to avoid the collision. Whichever of the two lands second must re-verify its bump per the `## Git` squash-merge rule.
## [2.11.4] - 2026-08-26

### /codereview: Markdown-Formatted MR Comments

- **`commands/codereview.md`:** `mr_comment` is now required to be Markdown-formatted for readability and actionability by the MR author — a self-contained first sentence (thread previews and notification emails show only the first line), then a blank line, then bullet points for evidence and listed fix steps — instead of a flat 1-4 sentence prose paragraph. The dedup step preserves that shape when merging comments from multiple reviewers, and Step 6 presents each comment inside a fenced markdown block so it copies verbatim, reformatting any prose-only comment that slipped through.

Note: authored before `2.11.2`/`2.11.3` landed on `main`; renumbered from a colliding `2.11.2` self-assignment to the next free slot when rebased in.

## [2.11.3] - 2026-08-20

### `/codereview`: `--no-codex-adversarial` Flag

- **`commands/codereview.md`:** new optional flag `--no-codex-adversarial` skips the Codex adversarial reviewer (#7) while keeping the other 6 (5 Claude agents + standard Codex #6). Skipped like a not-installed Codex companion — no verdict impact, not counted toward the reviewer-failure threshold.
- **`README.md`:** `/codereview` command table entry documents the new flag.

## [2.11.2] - 2026-08-20

### `sync-claude-config.sh`: Back Up Overlay-Copied Files Before Overwrite

- **`scripts/sync-claude-config.sh`:** `agents/`, `skills/`, `commands/`, `rules/`, and `hooks/*.sh` now get the same backup-before-overwrite treatment as `CLAUDE.md` and `settings.json` — any live file/dir the sync is about to overwrite is copied under `<CLAUDE_HOME>/backups/sync-<timestamp>/` first. Previously only `CLAUDE.md` and `settings.json` were backed up; a live agent/skill/command/rule/hook file colliding with a repo file of the same name was silently overwritten with no recovery path.
- **`scripts/sync-claude-config.test.sh`:** new case covers a live `agents/example.md` and `hooks/example.sh` colliding with repo files of the same name — asserts both are overwritten with the repo version and both are backed up with their pre-sync content intact.

## [2.11.1] - 2026-08-12

### Shell Commands Rule: No Expansions In One-Off Bash Commands

- **`CLAUDE.md`:** new Shell Commands section — never append `echo "exit=$?"`-style suffixes, and avoid `$VAR`/`$(...)` in one-off Bash commands when a literal would do. Expansions can't be matched by permission allowlist rules, so they trigger a "Contains simple_expansion" prompt every time; the Bash tool already reports exit codes, making the echo suffixes pure prompt noise. Workflows that genuinely need dynamic values (e.g. `/codereview` base-ref resolution) are exempt.

## [2.11.0] - 2026-08-11

### Review-Hardened Hooks, Scripts, And Commands (PR #31)

Twenty-eight rounds of automated review (Codex per-push, plus a 7-angle preemptive audit) against the review-findings branch, every confirmed finding fixed with regression tests. Highlights:

- **`hooks/auto-test-runner.sh`:** project-namespaced coordination (two projects never share a lock/marker); runner ownership as an atomic symlink lock carrying a PID-reuse-safe `pid:start-time` identity for both the wrapper and the live suite child; single-winner stale-lock reclamation with reclaim-token re-verification; release-then-recheck marker handoff; exiting signal handlers with group-wide child termination; orphan sweeps after every suite run.
- **`hooks/enforce-git-conventions.sh`:** rebuilt as a segment/token classifier — chained commands, env/wrapper prefixes, subshells, quoted real arguments, and command substitutions (nested, quote-aware) are all enforced; commit-message values are masked so free text never false-positives; ordered `-m`/`--message` extraction validates every commit in a chained command. Closed a long-standing fast-path bypass that skipped all checks for any command not starting with `git`.
- **`hooks/plan-context.sh`:** status-dialect plans pair `step_id` with status before truncation (anchored field match, END-flush fail-open for status-less steps); fully-completed plans are never reinjected.
- **`scripts/run-tests.sh`:** same-tree recursion refusal; validated per-suite watchdog timeout with unconditional group escalation; orphan sweeps on normal completion; active-suite group cleanup on runner termination; root-anchored runtime-dir prunes; zero-suite discovery guard.
- **`scripts/poll-pr-reviews.sh` / `scripts/lib/poll-common.sh` / `scripts/create-local-issues.sh`:** full `owner/name` shape validation; `feature_id` path-traversal rejection; pidfile-directory mode repair.
- **Four new test suites** (`hooks/auto-test-runner.test.sh`, `hooks/plan-context.test.sh`, `scripts/run-tests.test.sh`, and poll-common's chmod case) bring the runner to 10 suites.
- **`commands/codereview.md`:** lazy, verified base-ref resolution with sole-remote discovery; dirty-tree and untracked-file review supplements; per-scope proposed-fix sourcing; Codex scope classification corrections; branch checkout restore with `--no-overwrite-ignore`.
- **`docs/CI_DISPATCH.md`:** failure-isolated snapshot + bundle steps so committed CI work always ships; artifact-exposure warnings extended to the implementation bundle; `run-result.json` written outside the checkout.

## [2.10.1] - 2026-08-11

### Pre-Merge Checklist Codified In CLAUDE.md + `/git`

The rebase/version-bump habit adopted for PR #34's merge (check the branch isn't behind the target, and its README/CHANGELOG version bump is still correct against the target's current version, before every squash-merge) was only recorded as the agent's private memory. Since this repo is a template other projects deploy, that meant the habit wouldn't travel with it — codified here instead so it deploys with everything else.

- **`CLAUDE.md` — new `## Git` bullet:** before every squash-merge, check `git merge-base --is-ancestor origin/<target> <branch>` and rebase if behind; if the repo tracks a version (README `**Version:**` line plus a matching top `CHANGELOG.md` entry), diff the branch's version against the target branch's current version and fix the bump if it's stale, colliding, or was cut before another PR landed.
- **`commands/git.md`:** `sync-branch` guidance extended to state the same check, so it's visible to a human running `/git` directly, not just to an agent reading `CLAUDE.md`.
- Phrased conditionally ("if the repo tracks a version...") so it's a genuine no-op in projects without this repo's README/CHANGELOG version convention, rather than a repo-specific assumption leaking into every deploy target.
- This release is the rule's own first live exercise: branch was checked against `main` (2.10.0, not behind, no rebase needed) and the version bumped 2.10.0 → 2.10.1 before merging.

## [2.10.0] - 2026-08-11

### `pr-merge-sync-reminder.sh` — Nudge To Sync After A Squash Merge

`scripts/sync-claude-config.sh` (2.9.0) only closes the CLAUDE.md/hooks/settings.json drift when someone remembers to run it with `--apply`, and the natural trigger — a PR just landed — is easy to let slip. This adds the reminder as a hook instead of relying on memory.

- **New `hooks/pr-merge-sync-reminder.sh` (PostToolUse):** matches a `Bash` tool call running `gh pr merge` with `--squash` or `-s` and returns a `systemMessage` telling the agent to ask the user whether to run `scripts/sync-claude-config.sh --apply`. Silent on non-squash merges (`--merge`, `--rebase`, plain `gh pr merge`) and on unrelated `gh`/`git` commands.
- **Project-scope only** — wired into `hooks/settings.json` (matcher `Bash`, `if: "Bash(gh *)"`) but deliberately **not** added to the global `settings.json`: this reminder is specific to repos that ship `sync-claude-config.sh`, and firing it in every other repo the user works in would be a false positive every time.
- **New `hooks/pr-merge-sync-reminder.test.sh`:** asserts the reminder fires on `--squash`/`-s` in either argument position and stays silent on non-squash merges and unrelated `gh pr`/`git` commands, following `hooks/enforce-git-conventions.test.sh`'s stdin-JSON-in, jq-output-out pattern.
- `scripts/run-tests.sh` picks the new suite up automatically. Hook count 6 → 7.

## [2.9.0] - 2026-08-11

### `sync-claude-config.sh` — Deploy This Repo To The Live Global Config

The README's Quick Start has always documented a manual `cp -r` deployment (project scope) or a manual copy-and-merge (global scope), and this project's own drift — CLAUDE.md, hooks, and `settings.json` are edited here but only ever synced to `~/.claude` by hand — was the concrete motivating case: at the time this script was written, `~/.claude/CLAUDE.md` was missing the `## Response Style` section, `~/.claude/hooks/` was missing `response-style.sh`, and `~/.claude/settings.json` was missing the `UserPromptSubmit` hook entry, all merged in this repo but never pushed live.

- **New `scripts/sync-claude-config.sh`:**
  - Dry run by default — prints exactly what differs and touches nothing; `--apply` performs the sync.
  - `agents/`, `skills/`, `commands/`, `rules/`, and `hooks/*.sh` are overlay-copied: added or updated, never deleted, so a live-only file with no repo counterpart survives untouched.
  - `CLAUDE.md` is fully overwritten, but only when it differs from the live copy, and only after backing up the live version.
  - `settings.json` is never overwritten wholesale. Only the `hooks` and `env` keys are merged in: a hook event present in the repo but missing live is added; a hook event already present live is left alone unless the repo has an entry (matched by its `hooks` array) not already there, in which case it's appended. Every other live-only top-level key (`enabledPlugins`, `extraKnownMarketplaces`, `effortLevel`, `tui`, `model`, `skipDangerousModePermissionPrompt`, `_comment`, etc.) is preserved untouched. The merge is idempotent — a second `--apply` run is a no-op.
  - Every file this script overwrites is backed up first under `<CLAUDE_HOME>/backups/sync-<timestamp>/` (uses the existing `~/.claude/backups/` convention).
  - `CLAUDE_HOME` env var overrides the target directory (default `$HOME/.claude`) — used by the test suite and available for deploying to an alternate location.
- **New `scripts/sync-claude-config.test.sh`:** sandboxed against throwaway fake-repo and fake-`CLAUDE_HOME` trees (never reads or writes the real `$HOME/.claude`) — dry run vs. `--apply`, no-op detection, overlay-copy preserving a live-only file, `CLAUDE.md` backup-then-overwrite, `settings.json` merge preserving live-only keys, and second-run idempotency (no duplicated hook entry).
- `scripts/run-tests.sh` picks the new suite up automatically (no registration needed). Script count 5 → 6.

## [2.8.0] - 2026-08-11

### Response Style Rules + Drift-Resistant Reinjection

Added a user-scope response-style contract (BLUF, no preamble, no validation-as-move or reflexive praise, plain language, compression rules, epistemic-status labeling) and a hook that keeps it from fading over long sessions.

- **CLAUDE.md — new `## Response Style` section:**
  - BLUF always: bottom-line first, then reasoning. For anything non-trivial, summary capped at 5 bullets, rest of the content in decreasing order of importance. BLUF is not "be brief" — the reasoning stays, only the ceremony goes.
  - No preamble or recap — skip framing like "excellent question," don't restate the request or what was just done, go straight to the answer.
  - No validation-as-move ("you're right to feel that," "that's not your fault") and no reflexive agreement or praise ("you're absolutely right," "great question") — a brief acknowledgment is fine, but it can't substitute for substance; agree only when earned and say why.
  - No performed insight — skip polished aphorisms, metaphors, or named "tensions."
  - Plain language over elegant phrasing, tested by portability: if a sentence would fit unchanged in a different conversation, cut it or make it specific.
  - Compression cuts ceremony, not reasoning: no tool-call narration, cut filler/hedges/pleasantries, no emoji or decorative headers on short answers, quote the shortest decisive line instead of dumping logs/files/diffs, state each fact once, never invent abbreviations. Exceptions get full prose: security warnings, destructive/irreversible-action confirmations, and ordered multi-step instructions where dropping a connective creates ambiguity.
  - Don't repeat a follow-up suggestion the user didn't take.
  - Label epistemic status when it matters (known / inferred / guessed); prefer "I don't know" over confident fabrication; search when currency matters.
- **`hooks/response-style.sh` (new, UserPromptSubmit):** echoes a short pointer back at the CLAUDE.md rule on every prompt submission instead of restating it. Addresses a documented failure mode — instructions loaded once at session start lose weight against recent conversation history and the tone drifts back toward preamble and buried conclusions somewhere past the first hour. Firing on every turn puts the reminder exactly where recency pressure is highest. Wired into both `settings.json` (global, `$HOME` paths — the deploy target that makes it apply to every project) and `hooks/settings.json` (project-scope mirror, kept for parity with the repo's existing per-hook convention). Hook count 5 → 6.
- **No test suite added for `response-style.sh`** — consistent with the repo's existing pattern (`plan-context.sh`, `auto-format.sh`, `auto-test-runner.sh`, `auto-approve-safe-ops.sh` are also untested): it's a static, branchless echo, unlike `enforce-git-conventions.sh`'s parsing/validation logic, which does have a `.test.sh` sibling.

**Design references (best-practice sources this design follows):**
- [Opus 5 Made Claude Code Chatty. Three Changes Reined It In.](https://joecotellese.com/posts/steering-claude-code-bluf/) — source of the exact pattern used here: a CLAUDE.md tone rule plus a one-line `UserPromptSubmit` hook that re-points attention at the rule instead of restating it. Also the source of "BLUF is not 'be brief'" and the "past the first hour, tone slips back" drift observation.
- [BLUF (communication) — Wikipedia](https://en.wikipedia.org/wiki/BLUF_(communication)) — origin of the BLUF convention (US Army Regulation 25-50): lead with the conclusion, detail underneath, reader can stop once they have what they need.
- [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks) — `UserPromptSubmit` event semantics: fires before Claude processes the prompt, stdout is injected as additional context.

## [2.7.0] - 2026-08-10

### Poll-Scripts Repair — Both Poll Scripts Aborted On Their First Poll, In Every Configuration

**Both `scripts/poll-pr-reviews.sh` and `scripts/poll-mr-reviews.sh` aborted on their first poll iteration, in every configuration, before this release.** This was a user-visible bug, not internal cleanup: `/pr-fix-loop` and `/mr-fix-loop` depend on these scripts and would have failed the moment either one hit its first poll. Found and fixed as the `script_tests` feature's REQ-000 prerequisite, ahead of the four test suites that are now the evidence it's fixed.

- **DEF-1 (blocker) — `_NEW_COUNT` lost across a subshell** (`scripts/lib/poll-common.sh`) — `find_new_ids` set `_NEW_COUNT` as a side effect, but every caller captured its output via `NEW_IDS=$(find_new_ids ...)`, so the assignment happened inside a command-substitution subshell and never reached the caller. Under `set -u`, the next read of `_NEW_COUNT` died with an unbound-variable error — both scripts crashed on poll 1, always, with no JSON on stdout. Fixed by making `find_new_ids` pure (it only emits IDs) and having each of the two call sites derive the count itself from the output it already captured — no `declare -n` namerefs, which are bash 4.3+ and unavailable on this repo's bash 3.2 target.
- **DEF-2 (blocker) — invalid JSON escape in the bot-approval pattern** (`scripts/lib/poll-common.sh`) — `BASE_BOT_PATTERNS` interpolated `\[bot\]$` into a jq program inside a JSON string literal; `\[` is not a valid JSON escape, so jq failed to compile on every poll and bot-emoji approval (exit 0) could never fire. Fixed by expressing the literal brackets as regex character classes (`[[]bot[]]$`), which need no backslash escaping at all.
- **DEF-3 (minor) — empty-array expansion under `set -u`** (`scripts/lib/poll-common.sh`) — `"${_CLEANUP_PATHS[@]}"` on an empty array is an unbound-variable error on bash 3.2 + `set -u`, so every usage-error exit (before the first `register_cleanup` call) printed spurious trap noise alongside the real error. Fixed with the standard bash-3.2-safe guard, `${_CLEANUP_PATHS[@]+"${_CLEANUP_PATHS[@]}"}`.
- **Scope held to one file plus two call sites** — the repair touches only `scripts/lib/poll-common.sh` and the two `_NEW_COUNT` read sites in `scripts/poll-pr-reviews.sh` / `scripts/poll-mr-reviews.sh`. No documented exit code, JSON key, or CLI argument changed; the fix makes the existing documented contract real rather than altering it.

### Test Suites For The Four Previously-Untested Scripts

Only `hooks/enforce-git-conventions.sh` had a test sibling before this release; `create-github-issues.sh`, `create-local-issues.sh`, `poll-pr-reviews.sh`, and `poll-mr-reviews.sh` — which publish exit codes 0–4/10/11 and a JSON shape that `/execute-prd`, `/pr-fix-loop`, and `/mr-fix-loop` all parse — had none. The poll-common repair above is the evidence these new suites found and pinned down.

- **`scripts/create-github-issues.test.sh`** — happy path, all four exit-10 usage-error shapes, exit-1 auth/repo-detection failures, partial-failure JSON shapes (epic or a child issue fails independently), `GH_REPO` override, and the documented set (0, 1, 10) fully exercised, against a stubbed `gh`.
- **`scripts/create-local-issues.test.sh`** — happy path, YAML front-matter and apostrophe-escaping correctness, overwrite protection (`FORCE_OVERWRITE=1`), `SKIP_GITIGNORE`, optional roadmap rendering, and the documented set (0, 1, 10) fully exercised — every invocation sandboxed inside a throwaway `git init` directory so the suite can never write into this repo.
- **`scripts/poll-pr-reviews.test.sh`** — full documented exit-code contract (0, 1, 2, 3, 10, 11) against a stubbed `gh` returning per-poll GraphQL fixtures, including the `BLOCKED_THRESHOLD` boundary, pidfile kill-and-cleanup (only ever signaling a process the suite itself spawned), and transient-failure survival.
- **`scripts/poll-mr-reviews.test.sh`** — full documented exit-code contract (0, 1, 2, 3, 4, 10, 11) against a stubbed `glab`, including both remote-URL slug forms, native-approval vs. award-emoji gates, and approval-before-discussions ordering — sandboxed inside a throwaway `git init` directory with a fake `origin` remote.
- **`scripts/run-tests.sh` added** — the repo's test entry point. Discovers every `*.test.sh` under the repo with no hardcoded list, runs each via `bash <file>` (not as an executable, since `hooks/enforce-git-conventions.test.sh` is mode 644), isolates one suite's failure from the others, and prints per-suite PASS/FAIL lines plus a final `N passed, M failed` summary. Script count 4 → 5.
- **`hooks/auto-test-runner.sh` extended** — editing any `*.sh` file now triggers `scripts/run-tests.sh` synchronously, in place of the existing vitest/jest detection (this repo's shell scripts have no vitest/jest coverage of their own, only `*.test.sh` suites) rather than running alongside it.

### Findings

- **`docs/features/script_tests/FINDINGS.md` added** — separates **Repaired** defects (DEF-1/2/3 above, each citing the fix commit and its covering test) from **Open**, report-only findings left for a follow-up feature: DEF-4 (`create-github-issues.sh` jq-guard is dead code — observed exit 10, documented exit 1), DEF-5 (`create-local-issues.sh` leaves an empty `plans/` dir behind on an invalid-JSON exit-10 path), and DEF-6, newly found while writing the suites (`create-local-issues.sh` writes the `## Roadmap` heading and table header unconditionally, dropping only the data rows on malformed roadmap JSON, rather than omitting the section as documented). Also recorded: both poll scripts' pidfile paths hardcode `/tmp` rather than honoring `TMPDIR`; a deferred `jq --arg` hardening option for `BASE_BOT_PATTERNS`; and the deliberate, documented REQ-009 coverage gap (`poll-pr-reviews.sh` exit 4 is GitLab-only and unreachable there).

### P6.3 Exit Criterion — MET

`docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3's exit criterion — one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking — is marked **MET (2026-08-10)**, appended below the existing Superseded note. This feature's four independent test-file domains were the validation vehicle: a 4-batch parallel worktree-isolated wave (one worker per test file), following a sequenced single-worker repair round for REQ-000. See `docs/PHASE_6_NATIVE_PARALLELISM.md` for the full evidence.

## [2.6.0] - 2026-08-10

### Native Swarm Dispatch (`swarm-dispatch.sh` retired)

Parallel implementation dispatch moves from a custom bash driver to the harness's own primitives. The script was written when running N implementation sessions in parallel meant launching N `claude` CLI processes by hand; background subagents with `isolation: "worktree"` and per-spawn `model` now cover the same ground, so the script had become duplicated machinery with its own failure modes to maintain (see 2.3.2 and 2.3.3). Design validated by a two-worker spike before any file was touched — findings in `docs/features/native_swarm/SPIKE_FINDINGS.md`.

- **`scripts/swarm-dispatch.sh` deleted — 533 lines of bash removed** — Worktree creation and cleanup, background process/PID tracking, `--model`/`--max-turns` per session, the `--allowedTools` allowlist, batch-config JSON, `classify_failure()`, and session-JSON parsing all have native equivalents. Script count 5 → 4. The script was deleted **last**, after every guard it encoded was written down in `agents/orchestrator.md` — it was the only remaining record of them.
- **Dispatch rule rewritten** (`agents/orchestrator.md`, `commands/execute-prd.md`) — 3+ parallelizable steps now spawn one background `coder` subagent per domain batch with `isolation: "worktree"`, `run_in_background: true`, and `model` set by the highest complexity in the batch (high→opus, medium→sonnet, low→haiku). The 1-step and 2-step paths, issue creation, the Phase 3 review gates, and the merge-conflict flow are unchanged.
- **Steps are pre-assigned inline in each spawn prompt; the task queue is orchestrator-side tracking only** — The spike found that spawned subagents cannot see `TaskList`/`TaskGet`/`TaskUpdate` at all, despite `coder.md` granting them, so a shared queue cannot be the dispatch contract. `TaskCreate` entries (carrying `file_domain`, `issue_ref`, `complexity`) are now the orchestrator's progress ledger, and each worker receives its step IDs, file domain, issue numbers, and acceptance criteria in the prompt text. Batch construction — not queue claiming — is what keeps workers off each other's files, so double-claim safety is moot.
- **Worker worktrees branch from `origin/main`, not from the dispatching branch** — Workers therefore cannot see feature-branch state; the spike's first round failed outright because the workers could not find the feature's own docs. Every spawn prompt must now begin with `git merge feature/<id> --no-edit`, and merge-back must anticipate conflicts against files the feature branch changed after `origin/main`.
- **Post-swarm merge-back documented as an orchestrator-owned sequence** — The script's guards survive the migration even though its implementation does not: clean-working-tree check, explicit feature-branch checkout, **skip the merge for failed or incomplete workers** so partial work never lands, skip workers whose branch is absent (an unchanged worktree is torn down with its branch, which is not a failure), skip branches with no new commits, then `git merge --no-ff worktree-agent-<id>`; on conflict, record the files, abort, and spawn a conflict-resolution session.
- **Dirty-worktree salvage replaces the `git add -u` auto-commit guard** — `git worktree remove` refuses on a dirty worktree and `--force` destroys uncommitted work permanently. The orchestrator now runs `git -C <worktree> status --porcelain` before removing any worktree and either commits the changes on the worker branch or copies them out. This is the successor to the data-loss guard added in 2.3.2; untracked files remain invisible to merge-back, so workers are instructed to commit everything.
- **Failure recovery retiered** — `max_turns` → respawn with an upgraded model (haiku→sonnet→opus, then escalate); stalled or incomplete worker → `SendMessage` continuation, **valid only while that worker's worktree still exists** (after a clean completion tore it down, continuation resumes in the shared checkout with isolation gone, so respawn instead); `context_overflow` → respawn on opus 1M; `tool_error` still escalates immediately. The `launch_failure` row is gone — the harness owns worktree creation — and `claude --resume` is gone with the CLI sessions it resumed. Abandoned tasks must have `owner`/`status` reset before any respawn, or the replacement worker reads them as already claimed and skips them.
- **Turn budget is now fixed at 30 for every worker** — The Agent tool exposes `subagent_type`, `model`, `isolation`, `name`, `prompt`, and `run_in_background`, and nothing for turns, so per-spawn budgets do not survive. `agents/coder.md`'s frontmatter `maxTurns: 30` applies to all workers and complexity drives **model selection only**. High-complexity batches drop from 40 turns to 30, which makes `max_turns` recovery *more* likely to fire, not less — batches should be sized accordingly. The old opus/40 · sonnet/30 · haiku/20 mapping is retired.
- **Best-effort swarm report added** (`agents/orchestrator.md`) — Per worker: batch, model, duration, turns, steps completed, issues closed, and outcome/recovery — covering failed and incomplete workers with their failure mode and the recovery taken, not just the successes. When the harness exposes no duration/turn metrics, the orchestrator falls back to its own observed spawn/finish timestamps and marks turns `unavailable` rather than dropping the row. Per-worker cost is deliberately not itemized; subscription usage makes per-session dollars notional.
- **Orchestrator tool grants corrected** — `agents/orchestrator.md` frontmatter gains `TaskCreate`, `TaskList`, `TaskUpdate`, and `SendMessage`. It previously granted none of them, so it could not build a queue or recover a worker — the dispatch design it was documenting was not one it could execute.
- **Two new docs** — `docs/CI_DISPATCH.md` documents the headless GitHub Actions entry point for the implementation phase only, against an already-approved plan (the interactive approval gates are never auto-answered by CI), with a hardened copyable workflow (validated inputs, read-only contents permission, no persisted credentials). `docs/REMOTE_DISPATCH_NOTES.md` is a one-page research note on when `isolation: "remote"` would beat local worktrees — no implementation.
- **Reference cleanup** — `CLAUDE.md` dispatch bullet, `README.md` (scripts table, platform table, key design principles, directory structure), and `docs/AGENT_TEAMS_GUIDE.md` Pattern 5 plus the decision framework, which named "swarm dispatch (Pattern 5)" without the script name and so would not have been caught by grep. `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3 is marked **superseded** — it argued for keeping the script as a fallback, contradicting the full-retirement decision recorded in that same document — and the doc is otherwise left as a historical record.

### Decision Cards (user-blocking questions)

Blocking gates previously asked whatever question was in front of them, in whatever form, wherever the flow happened to stop — so the user answered one question, work resumed, and a second question surfaced two minutes later. Every point where the pipeline blocks on a person now uses one protocol.

- **New skill `skills/decision-cards/SKILL.md`** — Five-part protocol: (1) a summary of *all* open decisions first, each with a card ID (`DC-01`, …), title, why it blocks, and a one-line recommendation; (2) cards presented via `AskUserQuestion` in batches of ≤4, one decision per card, the card ID as the header chip, the recommendation as the first option labeled `(Recommended)` with its rationale, then concrete alternatives described by their trade-offs; (3) a standing `Discuss this card` option on every card that drops into plain Q&A about that decision only and then re-presents the card — same ID, refined context, plus any option the discussion produced; (4) an answered/unanswered ledger, with open cards re-presented in the next batch and no partial starts while any card is open; (5) every answer recorded as a dated decision in its owning artifact (PRD Agreement, `UX_NOTES.md`, or `PLAN_steps.md`) before work starts or resumes. Skill count 10 → 11.
- **Wired into every blocking gate** — `commands/execute-prd.md` Phase 0.2 (PRD gaps), Phase 1.6 (approval as one card, each requested change area as its own card), the escalate-to-user rows in failure recovery, and Phase 5.1 (push/PR); `commands/discover.md` at every phase that collects user input, including the adversarial review gate's per-finding disposition and the final PRD approval; `agents/orchestrator.md` as a user-interaction policy section referenced from the plan approval checkpoint and Rule 2. The gates themselves are unchanged — what changed is the shape of the question, not whether it is asked.
- **`architect` and `ui-ux` ask in batches** — They are the only agents permitted to ask the user, and both previously fired `AskUserQuestion` per ambiguity as it came up. Both now collect their open questions, present a summary, and run recommendation-first cards with the discuss loop, recording answers in `ARCHITECTURE.md` / `UX_NOTES.md`.
- **Single-question escalations skip the summary** — A lone urgent card (typically a `tool_error` escalation or the push gate) is presented directly with no preamble. The summary orients the user across a batch; one card does not need the ceremony, and recovery should not be slowed by it.

### Not Included

- **End-to-end validation of a real 3+-batch native swarm** — This feature's own steps concentrate in `orchestrator.md`, `execute-prd.md`, and `README.md`, whose overlapping file domains must be sequenced in a single batch, leaving only two parallelizable units. It therefore could not exercise the 3+ path it introduces. The Phase 6 P6.3 exit criterion — one full `/execute-prd` feature shipped through native dispatch with no regression in review gates or issue tracking — stays open and lands on the next feature through the pipeline.
- **Remote/cloud dispatch**, agent-teams changes, and per-worker cost itemization remain out of scope.

## [2.5.0] - 2026-08-10

### CLAUDE.md Modernization & Path-Scoped Rules

Audit against Claude Code native features (August 2026). CLAUDE.md restructured per current memory best practices; stack-specific standards moved to path-scoped rules.

- **CLAUDE.md rewritten for user scope** — The file deploys to `~/.claude/CLAUDE.md` (loaded in every project), but previously declared a project tech stack, npm commands, and Prisma paths — misleading context in non-TypeScript repos. Now contains only universal standards (principles, file management, git, testing, task markers, agent dispatch rules). Trimmed well under the recommended 200-line target; derivable/duplicated content removed.
- **`rules/` directory added** — `typescript.md` (paths: `**/*.{ts,tsx,mts,cts}`) and `infra.md` (paths: `*.tf`, `prisma/**`, `*.prisma`) carry the stack-specific standards. Deployed to `~/.claude/rules/`, they load only when Claude touches matching files.
- **README** — Quickstart copies `rules/`; documented that global (user-scope) hook deployment requires changing hook command paths from `"$CLAUDE_PROJECT_DIR"/.claude/hooks/` to `~/.claude/hooks/`.
- **AGENT_TEAMS_GUIDE** — Removed stale "Claude Opus 4.6" requirement; agent teams remain experimental (flag still required) as of Aug 2026.

### Global Hook Deployment & Native-Feature Cleanup

- **Root `settings.json` is now the full global config** — plugins, model, effort, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, and all hooks with `$HOME`-based command paths. Deploy by copying to `~/.claude/settings.json`. Previously the hook config lived only in `hooks/settings.json` with `$CLAUDE_PROJECT_DIR` paths, which silently did nothing at user scope — hooks were never active globally.
- **`reinject-context.sh` removed; `plan-context.sh` added** — Project-root CLAUDE.md now survives compaction natively (Claude Code re-reads it from disk), so re-stating standards was pure duplication/drift risk. The replacement PostCompact hook re-injects only what doesn't survive on its own: active `PLAN_steps.md` step/status state (globs `docs/features/*/PLAN_steps.md`, `plans/*/PLAN_steps.md`, root).
- **Reviewer agent slimmed to Step Review Mode** — Removed the built-in 5-angle PR Review Mode, the `Agent` tool grant, and the haiku scoring/dedup pipeline (maxTurns 30 → 20). PR-scale multi-angle review is delegated to `/codereview` (kept for its Codex cross-check) or the native `/code-review` skill (effort levels, `--fix`, `ultra`).
- **`fix-lint-and-typescript-errors` skill removed** — Grouping and safely fixing lint/TS errors is native model capability; the durable rules (no blanket `any`/`@ts-ignore`) live in `rules/typescript.md`. Skill count 11 → 10; references removed from backend-coder and frontend-coder.
- **`docs/PHASE_6_NATIVE_PARALLELISM.md` added** — Proposed (not yet approved) plan to evaluate replacing `swarm-dispatch.sh` with native background subagents using `isolation: worktree`, per-spawn `model` selection, the native task queue, and `SendMessage`-based recovery in place of `claude --resume`. Agent teams usage unchanged.

## [2.4.0] - 2026-03-31

### Multi-Angle Parallel Review System

- **Reviewer agent PR Review Mode** — 5-angle parallel review with haiku scoring and dedup (CLAUDE.md compliance, bug scan, git history, PR comments, code comments). Spawns read-only sub-agents only.
- **`/codereview` command** — 7-angle parallel review (5 Claude + 2 Codex background reviewers). Haiku scoring, cross-source dedup, incremental Codex result integration. User decides what to fix.
- **`/discover` adversarial review gate** — Inline adversarial PRD review before `/execute-prd` invocation. Verdict normalization, finding presentation, user re-approval after edits.
- **Codex scope handling** — Three-case scope logic: matching (in-verdict), narrower (branch-wide section), different target like `PR #N` (Codex skipped).
- **Failure threshold clarity** — Reviewer failure threshold scoped to 5 review agents only; haiku/dedup failures handled via fallback score (75).
- **Feature ID derivation** — Existing-PRD intake path now derives `feature_id` before any canonical-path or branch references.
- **Branch detection** — Approval gate uses explicit `git rev-parse --abbrev-ref HEAD` instead of ambiguous "if not already on one".

## [2.3.3] - 2026-03-30

### Deep Review & Hardening Pass (5-round code review)

Five-round automated code review across all 40 changed files, verifying end-to-end orchestration correctness, efficiency, bash portability, and edge-case safety.

### Fixed

- **Critical: Worktree creation failure masked by `tee` pipe** (`scripts/swarm-dispatch.sh`) — `git worktree add ... 2>&1 | tee -a "$LOG_FILE"` always returned `tee`'s exit code (0) under `pipefail`, silently proceeding when worktree creation failed. Replaced with direct redirect to log file.

- **Critical: Subshell exit code not propagated to `wait`** (`scripts/swarm-dispatch.sh`) — The subshell ended with `echo $? > file` whose exit was always 0, making the `wait` fallback unreliable if the `.exit` file write failed. Now ends with `exit $EXIT` so both `.exit` file and `wait` return the correct code.

- **Bash 3.2 incompatibility on macOS** (`scripts/create-github-issues.sh`, `scripts/swarm-dispatch.sh`) — `readarray` (bash 4+) and `${var,,}` lowercase expansion (bash 4+) broke on macOS `/bin/bash` 3.2. Replaced with `while read` loop and `tr '[:upper:]' '[:lower:]'`.

- **Labels fail on fresh repos** (`scripts/create-github-issues.sh`) — `gh issue create --label` failed when labels didn't pre-exist. Added idempotent `gh label create --force` before issue creation.

- **Issues filed in wrong repo** (`scripts/create-github-issues.sh`) — No `--repo` flag meant issues landed in whatever the CWD resolved to. Added auto-detection via `GH_REPO` env var or `gh repo view`, passed `--repo "$REPO"` to all `gh` calls.

- **Stderr contaminated issue URLs** (`scripts/create-github-issues.sh`) — `2>&1` mixed error messages into the URL variable used for number parsing. Separated stderr to a temp file; URL parsing now uses `grep -oE 'issues/[0-9]+'` instead of fragile `basename | tr -cd '0-9'`.

- **Temp files leaked on early exit** (`scripts/create-github-issues.sh`, `scripts/create-local-issues.sh`) — `ISSUE_MAP_FILE` temp files not cleaned up on unexpected exit. Added to EXIT traps.

- **Missing STEP_COUNT guard** (`scripts/create-local-issues.sh`) — Accepted 0-step plans, creating an epic with no child issues. Added guard matching `create-github-issues.sh`.

- **Missing JSON validation** (`scripts/create-local-issues.sh`) — Invalid JSON in plan file silently produced empty variables. Added `jq -e '.'` validation matching the other scripts.

- **Hand-assembled JSON output** (`scripts/swarm-dispatch.sh`) — Final output used string concatenation, breaking on special characters in feature IDs. Replaced with `jq -n` for proper escaping.

- **String-concat results array** (`scripts/swarm-dispatch.sh`) — Session results built via manual comma insertion, fragile for escaping. Replaced with JSONL accumulation + `jq -s '.'`.

- **Stale subshell comment** (`scripts/swarm-dispatch.sh`) — Comment incorrectly described the `.exit` file as working around an unfixed `echo $?` issue.

- **Orchestrator rule 6 misleading** (`agents/orchestrator.md`) — Said "create the feature branch" (`checkout -b`) which fails when `/discover` already created it. Changed to `checkout || checkout -b`.

- **Duplicate `# Args` section header** (`scripts/swarm-dispatch.sh`) — Dead artifact from insertion between header and content.

### Improved

- **Efficiency: jq process spawning reduced ~80%** — All three scripts consolidated from 6-8 jq forks per loop iteration to 1-2 via `jq @sh` field extraction and here-strings.

- **Efficiency: O(n^2) JSON map rebuilding eliminated** — Both issue scripts replaced per-iteration `jq '. + {key: val}'` rebuilds with file-based accumulation + single `jq -n` assembly.

- **Efficiency: `classify_failure` 4x faster** — Replaced 4 `echo | grep` forks with bash `[[ =~ ]]` pattern matching on a single lowercase string.

- **Efficiency: Summary stats single-pass** — Replaced 3 separate `jq` calls for success/failure/conflict counts with one `jq @tsv` extraction.

- **Consistency: `echo|jq` normalized to here-strings** — All `echo "$VAR" | jq` patterns replaced with `jq ... <<< "$VAR"` across all three scripts.

- **Agent tools aligned** — `coder.md` added `mcp__chunkhound` to match backend/frontend-coder tool sets.

- **Style lines removed** — Removed inconsistent `**Style:**` directives from backend-coder, frontend-coder, coder (already removed from other agents in v2.3.0).

- **AGENT_TEAMS_GUIDE.md updated** — Count corrected to "three" patterns; swarm dispatch added to decision tree.

- **Dead config removed** — `handoff_targets` field removed from `derive-plan-from-spec/SKILL.md` (no consumer used it).

- **Exit code constants** — Added `EXIT_OK`, `EXIT_FATAL`, `EXIT_USAGE` to `create-local-issues.sh` (parity with other scripts).

---

## [2.3.2] - 2026-03-30

### Hardening, Correctness Fixes & Tiered Failure Recovery

Comprehensive review and hardening pass across the entire swarm pipeline, fixing critical bugs that caused silent data loss and adding tiered failure recovery with model upgrades.

### Fixed

- **Critical: Failed sessions silently merged** (`scripts/swarm-dispatch.sh`) — The merge loop used `wait`'s exit code to determine session success, but `wait` returns the subshell's exit code (always 0 because `echo $?` is the last subshell command), not claude's exit code. Failed sessions were merged into the feature branch with incomplete/broken code. Now reads the actual exit code from the `.exit` file.

- **Critical: Swarm dispatch arg mismatch** (`commands/execute-prd.md`, `agents/orchestrator.md`) — Both callers passed the plan file path as arg 2 to `swarm-dispatch.sh`, but the script expects the feature branch name. Fixed to pass `feature/{feature_id}`.

- **Critical: Batch config field mismatch** (`commands/execute-prd.md`) — Batch config JSON used a `"model"` field, but `swarm-dispatch.sh` reads `"complexity"`. Fixed to use `"complexity"` consistently.

- **Critical: Merge targeted wrong branch** (`scripts/swarm-dispatch.sh`) — No `git checkout` before the merge loop meant merges could land on whatever branch HEAD pointed to. Added explicit checkout of the feature branch with dirty-tree guard.

- **28 stale agent references cleaned** — Replaced references to removed agents (planner, test-spec, documenter) across 20 files: 6 agents, 2 commands, 1 doc, 10 skills, 2 hooks. The `reinject-context.sh` PostCompact hook was re-injecting "planner may ask questions" on every compaction. The `auto-test-runner.sh` hook routed failures to nonexistent `test-spec` agent.

- **SESSION_MODELS/SESSION_TURNS array misalignment** (`scripts/swarm-dispatch.sh`) — Launch failures skipped array appends, causing all subsequent sessions to read the wrong model/turns from misaligned arrays.

- **Auto-commit failure silently dropped edits** (`scripts/swarm-dispatch.sh`) — If auto-commit failed (missing git config, empty tree), `|| true` swallowed the error, then the no-new-commits check removed the worktree. Now treats auto-commit failure as a merge blocker and preserves the worktree for manual recovery.

- **Auto-commit staged secrets** (`scripts/swarm-dispatch.sh`) — `git add -A` staged everything including potential `.env` files or debug artifacts. Changed to `git add -u` (tracked files only).

- **Branch creation failed on rerun** (`commands/execute-prd.md`) — `git checkout -b` failed when `/discover` already created the branch. Changed to `checkout || checkout -b`.

- **Remote branch not found** (`scripts/swarm-dispatch.sh`) — Branch detection didn't fetch from origin, so remote-only branches weren't found. Added `git fetch origin $FEATURE_BRANCH` before detection.

- **Invalid YAML frontmatter** (`scripts/create-local-issues.sh`) — Unescaped titles with colons or quotes produced invalid YAML. Added `yaml_escape()` with single-quote wrapping.

- **Unconditional .gitignore modification** (`scripts/create-local-issues.sh`) — `.gitignore` was modified even outside a git repo. Guarded with git repo check; added `SKIP_GITIGNORE=1` opt-out.

- **Local issue files overwritten on rerun** (`scripts/create-local-issues.sh`) — Reruns silently overwrote issue files containing notes/progress. Now refuses unless `FORCE_OVERWRITE=1`.

- **Stale worktree branches deleted without warning** (`scripts/swarm-dispatch.sh`) — Prior-run branches with unmerged commits were force-deleted. Now warns with commit count before deletion.

### Added

- **Tiered failure recovery** (`agents/orchestrator.md`, `commands/execute-prd.md`, `scripts/swarm-dispatch.sh`):
  - `classify_failure()` function examines session output and logs to determine: `max_turns`, `tool_error`, `context_overflow`, `infrastructure`, `launch_failure`, or `success`
  - `max_turns` → upgrade model (haiku→sonnet→opus); already opus → escalate to user
  - `tool_error` → escalate to user immediately
  - `context_overflow` → retry with opus 1M context; already opus → escalate to user
  - `infrastructure` → `claude --resume` same model; fails again → escalate to user
  - `launch_failure` → retry worktree creation once; fails again → escalate to user
  - Per-session `failure_reason` and `model` fields in swarm JSON output

- **Preflight dependency checks** (`scripts/swarm-dispatch.sh`) — Validates `jq`, `git`, and `claude` CLI are available before any git mutations.

- **Dirty-tree guard** (`scripts/swarm-dispatch.sh`) — Requires clean working tree before checkout/merge to prevent stomping local changes.

- **No-changes merge skip** (`scripts/swarm-dispatch.sh`) — Skips merge when worktree branch has no new commits vs the feature branch.

### Changed

- **Model names normalized** — `swarm-dispatch.sh` model constants changed from `claude-opus-4-5`/`claude-sonnet-4-5`/`claude-haiku-3-5` to short names `opus`/`sonnet`/`haiku`. `commands/git.md` changed from `claude-4.5-haiku` to `haiku`.

- **README.md** — Orchestrator model corrected to sonnet. Scripts count corrected to 5. Swarm-dispatch description expanded. v2.3.2 summary added.

- **Efficiency: create-local-issues.sh** — Plan steps file cached in variable (was re-reading from disk 7 times per step per iteration). Roadmap file cached. `yaml_escape()` moved above loop.

---

## [2.3.1] - 2026-03-30

### Phase 5: Swarm Architecture, Discovery & Issue Tracking

True swarm implementation with parallel claude sessions in git worktrees, interactive PRD discovery, and platform-aware issue tracking (GitHub Issues or local file-based fallback for GitLab).

### Added

- **`/discover` command** (`commands/discover.md`) — Interactive PRD creation through structured conversation:
  - Phase 0: Codebase analysis (scan existing patterns, find similar features, identify conventions)
  - Phase 1: Problem & Users (grounded in codebase findings)
  - Phase 1.5: Research & Prior Art (web search for examples, dig into vague references)
  - Phase 2-7: User stories, scope boundaries, acceptance criteria, technical constraints, non-functional/risks, priority (MoSCoW)
  - Uses opus for complex multi-turn reasoning
  - Scope management: refuses PRDs > 8 plan steps, proposes incremental v1/v2/v3 splits, creates roadmap in epic
  - Output: structured PRD with acceptance criteria that feed directly into plan steps and GitHub issues

- **`scripts/swarm-dispatch.sh`** — Launch N parallel `claude` sessions, each in its own git worktree:
  - Complexity-based model selection per batch: opus (high), sonnet (medium), haiku (low)
  - Each session can spawn its own agent team for work-stealing within its batch
  - Worktrees branch off `feature/{feature_id}`, merged back after all sessions complete
  - JSON output with session IDs, costs, durations, merge conflict reports
  - PID file management for re-run cleanup

- **`scripts/create-github-issues.sh`** — Create GitHub epic (tracking issue) + child issues from plan steps:
  - Epic body: task list with auto-progress bar, quality gates, roadmap table for multi-phase features
  - Child issues: acceptance criteria checkboxes, file domain, complexity label, dependencies
  - Output: `{"epic": N, "issues": {"step_01": M, ...}}` for swarm sessions

- **`scripts/create-local-issues.sh`** — Fallback for non-GitHub repos (GitLab, local):
  - Creates `plans/{feature_id}/issue-0000.md` (epic) + `issue-0001.md` through `issue-NNNN.md`
  - Frontmatter with status, complexity, domain for programmatic access
  - `plans/` auto-added to `.gitignore` (tracking artifacts not committed)
  - Same JSON output shape as GitHub script for pipeline interchangeability

- **`agents/coder.md`** — General-purpose swarm coder for team mode:
  - TaskList work loop: claim → context → implement → validate → checkpoint → complete → next
  - File-domain conflict avoidance (checks in-progress tasks before claiming)
  - Validates against GitHub issue or local issue file acceptance criteria
  - Closes issues with commit SHA evidence on completion
  - 5-turn progress checkpointing for maxTurns recovery

- **Pattern C (Swarm)** in `CLAUDE.md` — Parallel worktree sessions with complexity-based model selection
- **Pattern 5 (Swarm Implementation)** in `docs/AGENT_TEAMS_GUIDE.md` — Full documentation of the swarm pattern

### Changed

- **`agents/orchestrator.md`** — Major update:
  - Model downgraded from opus to sonnet (pure coordination, no complex reasoning)
  - PRD review gate: architect checks incoming specs for gaps/scope before proceeding
  - GitHub issue creation integrated into Phase 1 (auto-detects GitHub vs local fallback)
  - Swarm dispatch: 1 step → subagent, 2 steps → parallel subagents, 3+ steps → swarm
  - Streaming review: reviewer + security-researcher in parallel after merge
  - maxTurns recovery: detect abandoned tasks, resume sessions or respawn
  - Phase 5: PR creation, epic closes only on PR merge

- **`commands/execute-prd.md`** — Full pipeline rewrite:
  - Phase 0: Branch creation (`feature/{feature_id}`) + PRD review gate
  - Phase 1: Requirements, architecture, plan (with new fields), test strategy, GitHub/local issues, mandatory user approval with epic/issue links
  - Phase 2: Swarm dispatch with complexity-based model selection, worktree isolation per batch
  - Phase 3: Parallel quality gates (reviewer + security-researcher)
  - Phase 4: Documentation via skill
  - Phase 5: PR creation, `/pr-fix-loop` if needed, epic closes on merge
  - Auto-detects GitHub vs non-GitHub for issue tracking

- **`skills/derive-plan-from-spec/SKILL.md`** — New fields per plan step:
  - `file_domain`: glob patterns for files touched
  - `acceptance_criteria`: checkable list from spec requirements
  - `batch_hint`: suggested swarm grouping (backend, frontend, infra, tests)
  - `complexity`: high/medium/low (drives model selection and turn budget)

- **`README.md`** — Updated: 8 agents, 7 commands, 5 scripts, swarm documentation
- **`.gitignore`** — Added `plans/` for local issue tracking artifacts

### Full Pipeline

```
/discover → PRD → /execute-prd → Epic+Issues → Plan → User approval
  → Swarm (worktrees, complexity-based models) → Merge → Review → Docs → PR
  → Merge → Close Epic
```

### Migration Notes

1. Copy new files: `commands/discover.md`, `agents/coder.md`, `scripts/swarm-dispatch.sh`, `scripts/create-github-issues.sh`, `scripts/create-local-issues.sh`
2. Replace: `agents/orchestrator.md`, `commands/execute-prd.md`
3. Update: `skills/derive-plan-from-spec/SKILL.md`, `docs/AGENT_TEAMS_GUIDE.md`, `CLAUDE.md`
4. Ensure `gh` CLI is authenticated for GitHub issue tracking, or local fallback activates automatically
5. `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` must be set in `hooks/settings.json` for swarm team mode inside sessions

---

## [2.3.0] - 2026-03-30

### Phase 4: Agent Architecture Simplification

This release consolidates the 10-agent architecture into 7 core agents by demoting planner, test-spec, and documenter to reusable skills that the orchestrator invokes directly. Coders now implement tests alongside code. Reviewer and security-researcher run in parallel after implementation is complete.

### Removed

- **Planner agent** (`agents/planner.md`) — Demoted to `derive-plan-from-spec` skill. Orchestrator now invokes this skill directly instead of delegating to a separate agent. Reduces ceremony around plan creation while maintaining structured planning.

- **Test-spec agent** (`agents/test-spec.md`) — Demoted to `derive-test-spec-from-requirements` skill. Orchestrator invokes this skill to generate test plans. Backend and frontend coders now implement tests alongside their code (no sequential hand-off).

- **Documenter agent** (`agents/documenter.md`) — Demoted to `sync-docs-with-implementation` skill. Orchestrator invokes this skill after implementation to identify and update impacted docs, changelogs, and ADRs.

- **Sequential mode in `/execute-prd`** — All workflows now run parallel implementation (backend + frontend as subagents with worktree isolation). Sequential mode is removed; no time is lost to sequential execution.

### Changed

- **Agent count** — Reduced from 10 to 7: orchestrator, architect, backend-coder, frontend-coder, ui-ux, reviewer, security-researcher.

- **Agent responsibilities**:
  - **backend-coder, frontend-coder** — Now responsible for implementing tests alongside feature code (no separate test-spec handoff).
  - **reviewer, security-researcher** — Run in parallel after coders finish (no orchestrator sequencing between them).

- **Orchestrator workflow**:
  - Calls `derive-plan-from-spec` skill instead of dispatching to planner agent.
  - Calls `derive-test-spec-from-requirements` skill instead of dispatching to test-spec agent.
  - Dispatches backend + frontend coders in parallel with isolated worktrees.
  - Dispatches reviewer and security-researcher in parallel (no sequence).
  - Calls `sync-docs-with-implementation` skill instead of dispatching to documenter agent.

- **CLAUDE.md** — Updated Agent Spawning Patterns:
  - Pattern A: Removed planner, test-spec, documenter from subagent list. Reduced to 6 core agents plus orchestrator.
  - Pattern B: Simplified to show reviewer + security-researcher as a parallel review team.
  - Removed references to sequential mode.

- **README.md**:
  - Updated "Agents (10)" to "Agents (7)".
  - Removed planner, test-spec, documenter rows from agent table.
  - Updated directory structure to remove `planner.md`, `test-spec.md`, `documenter.md`.
  - Updated "AskUserQuestion routing" to remove planner (now only architect and ui-ux).
  - Updated "What Changed" section with Phase 4 notes.

- **Skills section** — Added note: "orchestrator invokes directly". No agent boundary; coders own tests.

### Rationale

The 10-agent architecture had intermediate agents (planner, test-spec, documenter) that primarily transformed specifications into other specifications. These created handoffs without adding value:

- **Planner agent** — Users already understand what needs to be done; plan creation is best done with the same context as implementation.
- **Test-spec agent** — Tests are tightly coupled to code; separate design of tests from implementation caused rework.
- **Documenter agent** — Demoting to a skill means docs are updated as part of implementation, not after.

The 7-agent architecture is leaner and preserves the same level of rigor:
- Orchestrator invokes skills for structured planning, test planning, and docs sync.
- Coders implement features with tests embedded (faster feedback, fewer handoffs).
- Review is parallel, not sequential (faster to merge).
- Total agent count is lower → simpler mental model for engineers.

### Migration Notes (Phase 3 → Phase 4)

1. Remove agent files from `.claude/agents/`:
   - `planner.md`
   - `test-spec.md`
   - `documenter.md`

2. Update your `/execute-prd` command invocations: remove `mode=sequential`. All workflows default to parallel.

3. Update CLAUDE.md with the new Agent Spawning Patterns section.

4. Update README.md with the new agent table and directory structure.

5. Brief coders: they now own tests (implement alongside code, not as a separate step after test-spec design).

---

## [2.2.2] - 2026-03-30

### Added

- **`/mr-fix-loop` command** (`commands/mr-fix-loop.md`) — GitLab counterpart to `/pr-fix-loop`. Automates the fix-review-poll loop for GitLab merge requests:
  - Uses `glab` CLI and GitLab REST API for discussion management (list, reply, resolve)
  - Uses GitLab MCP tools (`get_merge_request`, `get_merge_request_pipelines`, `get_pipeline_jobs`) where available
  - **Dual approval gate:** GitLab native MR approval (`approvals_left == 0`) OR bot award emoji (`thumbsup`/`white_check_mark`) on the MR
  - **Pipeline failure fixing:** Detects failed pipeline jobs (lint, tests, type-check, build), runs checks locally to reproduce, fixes and pushes — treated as implicit Category A comments
  - Supports GitLab Duo, Cursor BugBot, custom CI bots, and cross-platform Codex integration
  - Same Category A (fix) / B (push back) / C (clarify) triage logic as `/pr-fix-loop`
  - **Never merges** — strictly scoped to review comment and pipeline failure resolution

- **Reusable polling scripts** (`scripts/poll-pr-reviews.sh`, `scripts/poll-mr-reviews.sh`, `scripts/lib/poll-common.sh`) — Zero-token-cost bash scripts that replace background haiku agents for polling. Features:
  - PID file management with auto-kill of previous instance on re-run
  - Snapshot-based new-thread detection (distinguishes new comments from stale disputed threads)
  - Structured JSON output with exit codes: 0=approved, 1=new comments, 2=idle timeout, 3=blocked on human, 4=pipeline failed
  - Parallel API calls for GitLab (4 endpoints fetched concurrently)
  - Shared library (`poll-common.sh`) with set-difference, PID management, validation, and cleanup functions
  - Haiku agent fallback if scripts not found

### Fixed

- **`+` refspec force-push bypass** (`enforce-git-conventions.sh`) — `git push origin +HEAD:main` bypassed force-push detection because only `--force`/`-f` flags were checked. The `+` refspec prefix (equivalent to `--force` per-ref) is now detected and blocked with distinct error messages.

- **`--no-verify` after `-m` bypass** (`enforce-git-conventions.sh`) — `git commit -m "msg" --no-verify` was invisible because `OPTS_BEFORE_MSG` stripped everything after `-m`. The `--no-verify` long form is now checked against the full normalized command.

- **Bare `git push` skipped all push checks** (`enforce-git-conventions.sh`) — The push guard regex required a trailing space (`git\s+push\s`), so bare `git push` (no args) bypassed force-push, main-branch, and `--all`/`--mirror` checks. Changed to `git\s+push(\s|$)`.

- **`--all`/`--mirror` matched inside branch names** (`enforce-git-conventions.sh`) — `git push origin feature/fix--all-bugs` was incorrectly blocked. Added leading `\s` requirement before `--all`/`--mirror`.

- **`git branch -D` auto-approved** (`auto-approve-safe-ops.sh`) — Prefix matching on `git branch` allowed destructive flags (`-D`, `-d`, `--delete`). Added a destructive flag denylist that also blocks `--config`, `--plugin`, `--rulesdir`, and `--require` on npx commands.

- **Global option normalization consumed subcommands** (`enforce-git-conventions.sh`) — The greedy regex `-[a-zA-Z]([[:space:]]+[^[:space:]]+)?` treated standalone flags like `-p` as having arguments, consuming the next token (e.g., `git -p push` → `git origin`). Replaced with explicit flag lists: flags-with-args (`-C`, `-c`, `--git-dir`, etc.) vs standalone flags (`-p`, `--no-pager`, etc.).

- **`git commit -n` not blocked** (`enforce-git-conventions.sh`) — The `-n` shorthand for `--no-verify` was only checked in long form. Added clustered short-flag detection scoped to `git commit` only (`-n` means `--dry-run` for push).

- **GitLab discussion ID type mismatch** (`poll-mr-reviews.sh`) — GitLab returns numeric discussion IDs but the `jq -R` pipeline produced strings, causing `index()` comparisons to silently fail. Added `tostring` coercion.

- **`PROJECT_SLUG` dropped group path** (`poll-mr-reviews.sh`) — The sed regex stripped everything up to the last `/`, losing GitLab group/subgroup paths. Two projects with the same name in different groups would collide on PID files. Fixed with mutually exclusive SSH vs HTTP parsing.

- **Polling scripts reported stale threads as new** (`poll-pr-reviews.sh`, `poll-mr-reviews.sh`) — Without snapshot comparison, every unresolved thread triggered `NEW_COMMENTS` on every poll, preventing idle timeout or blocked-on-human termination. Added startup snapshot of known thread IDs.

### Changed

- **README.md** — Added `/mr-fix-loop` to commands table (now 6 commands), platform support matrix (GitLab-only), directory structure listing, scripts section with exit codes and usage. Updated skill count to 11. Fixed exit code documentation. Updated quick-start to include scripts and lib directory.

- **`/pr-fix-loop` and `/mr-fix-loop` commands** — Phase 3 polling now references reusable scripts with haiku agent fallback. PID-based auto-cleanup replaces TaskStop.

- **`agents/ui-ux.md`** — Fixed AskUserQuestion rule to include planner (was missing, inconsistent with all other files).

- **`agents/reviewer.md`** — Removed Write tool from read-only agent (contradicted `permissionMode: plan`).

---

## [2.2.1] - 2026-03-30

### Phase 3.1: Hook Hardening & PR Fix Loop Enhancements

Security hardening for git convention and auto-approve hooks based on automated code review (Codex), plus a major upgrade to the `/pr-fix-loop` command.

### Fixed

- **Force-push `-f` bypass** (`enforce-git-conventions.sh`) — The regex only matched `-f` with a preceding space, so `git push -f origin branch` (where `-f` immediately follows `push`) slipped through. Fixed by restructuring the pattern to allow `-f` at any position after `push`.

- **Clustered `-fu` flag bypass** (`enforce-git-conventions.sh`) — Git accepts combined short options like `-fu` (`-f` + `-u`), but the regex only matched standalone `-f` followed by whitespace/end. Changed to `-[a-zA-Z]*f[a-zA-Z]*(\s|$)` to catch `-fu`, `-uf`, `-fvu`, etc.

- **`refs/heads/main` refspec bypass** (`enforce-git-conventions.sh`) — Full ref paths like `git push origin refs/heads/main` and `git push origin HEAD:refs/heads/main` bypassed the protected branch check. Added `(refs/heads/)?` optional group to all patterns.

- **`--delete main` bypass** (`enforce-git-conventions.sh`) — `git push origin --delete main` bypassed the check because `--delete` sits between the remote and branch name. Added a dedicated pattern for `(-d|--delete)\s+(refs/heads/)?(main|master)`.

- **`\b` false positive on `main-feature`** (`enforce-git-conventions.sh`) — `\b` treats `-` as a word boundary, so `git push origin main-feature` was incorrectly blocked. Replaced `\b` with `(\s|$)` in all protected-branch patterns.

- **Single `&` bypass** (`auto-approve-safe-ops.sh`) — The unsafe metacharacter filter caught `&&` but not standalone `&`, allowing `git status & rm -rf /tmp/x` to pass the safe-prefix check. Added `&` to the filter.

### Changed

- **`/pr-fix-loop` command** — Major enhancements:
  - **Multi-bot support** — Now recognizes Codex (`chatgpt-codex-connector[bot]`), Cursor BugBot (`cursor-bugbot[bot]`), and GitLab Copilot (`gitlab-copilot[bot]`) as review bots.
  - **Removed `@codex review` triggers** — Review bots auto-review on every push; no manual trigger needed.
  - **User comment triage** — Human reviewer comments are now triaged with the same Category A (fix) / B (push back) / C (clarify) logic as bot comments.
  - **`@codex review the feedback` tag** — Category B (disagree) and Category C (unclear) replies to Codex end with `@codex review the feedback` to prompt re-evaluation.
  - **Bot follow-up resolution** — If a bot responds to a disputed thread and its reply satisfies concerns, the thread is resolved. Otherwise, re-triage as B or C and continue the loop.
  - **Mandatory approval gate** — The 👍 or ✅ emoji on the PR description from a bot reviewer is the mandatory approval signal. Positive text like "Didn't find any major issues" complements but does not replace the emoji gate. Loop also ends on 15 consecutive minutes idle (reported as unapproved).

- **README.md** — Updated `/pr-fix-loop` description in commands table. Updated quick-start hook install to copy all `*.sh` files.

---

## [2.0.0] - 2026-03-29

### Phase 1: Modernize for Claude Code v2.1.86

This release updates the multi-agent orchestration from Claude Code v2.0.25 patterns to v2.1.86 native capabilities, while preserving the structured workflow, gated approvals, and strict delegation model.

### Removed

- **RAG agent** — Agents now query MCP tools (Context7, Chunkhound) directly. Claude Code's Tool Search feature (introduced v2.1.76) automatically defers tool loading when definitions exceed 10% of context, providing ~85% token savings. A dedicated routing agent is no longer needed.
- **session-checkpoint skill** — Replaced by native auto-memory + PostCompact hook. Claude Code handles context compaction automatically. The PostCompact hook in `hooks/reinject-context.sh` re-injects critical project standards after compaction without manual intervention.
- **Duplicated git/test-runner reference sections** in agent definitions — These bloated every agent file. Git workflow and test failure routing are now documented once in the commands and will be enforced by hooks in Phase 2.

### Added

- **PostCompact hook** (`hooks/reinject-context.sh` + `hooks/settings.json`) — Automatically re-injects project standards, workflow rules, and context hierarchy after context compaction. Replaces the manual session-checkpoint skill that required agents to monitor their own usage at ~85% thresholds.
- **`memory: project`** on all long-lived agents — Reviewer, architect, security-researcher, and others now persist learnings across sessions. A reviewer that has reviewed your codebase 20 times actually learns your conventions.
- **`isolation: worktree`** on backend-coder and frontend-coder — Each coder gets its own copy of the repo via git worktrees. Eliminates the file-ownership coordination rules the orchestrator previously enforced. Worktrees are auto-cleaned if the agent makes no changes.
- **`permissionMode: plan`** on reviewer and security-researcher — These agents are structurally read-only. They can read and analyze but cannot modify code, preventing accidental changes during review.
- **`model:` tuning per agent** — opus for architectural/review reasoning, sonnet for implementation, haiku for documentation. Reduces cost without sacrificing quality where it matters.
- **`maxTurns:` limits per agent** — Prevents runaway agent execution. Tuned per role: 50 for orchestrator, 30 for coders, 15-25 for others.
- **MCP tool access on agents** — Architect, coders, ui-ux, and test-spec now have direct `mcp__context7` and/or `mcp__chunkhound` in their tools list, eliminating the RAG intermediary.

### Changed

- **CLAUDE.md** — Updated agent spawning pattern to reflect new frontmatter (model, isolation, memory, permissionMode). Removed Task tool pseudocode example, replaced with named agent table.
- **feature-autopilot command** — Added v2 change notes documenting what's different. Removed RAG orchestration steps, session checkpoint references. Added worktree isolation notes for coders.
- **All agent definitions** — Streamlined by ~40-60% by removing duplicated git workflow reference sections, test-runner routing templates, and session-checkpoint boilerplate. Each agent now focuses on its core mission.
- **Agent count** — Reduced from 11 to 10 (RAG agent removed). Remaining: orchestrator, architect, planner, backend-coder, frontend-coder, test-spec, reviewer, security-researcher, documenter, ui-ux.
- **Skill count** — Reduced from 13 to 12 (session-checkpoint removed). All other skills remain unchanged.

### Migration Notes

If upgrading from v1:
1. Remove the `agents/rag.md` file from your `.claude/agents/` directory.
2. Remove the `skills/session-checkpoint/` directory.
3. Copy `hooks/reinject-context.sh` to `.claude/hooks/` and make it executable (`chmod +x`).
4. Merge `hooks/settings.json` into your `.claude/settings.json` under the `"hooks"` key.
5. Replace all agent files in `.claude/agents/` with the v2 versions.
6. Replace the `commands/execute-prd.md` with the v2 version.
7. Update your `CLAUDE.md` with the new agent spawning pattern section.

---

## [2.1.0] - 2026-03-29

### Phase 2: Native Hook Automation

This release replaces manual coordination patterns (orchestrator routing test failures, enforcing git conventions in agent prompts) with deterministic hooks that execute 100% of the time.

### Added

- **Auto-test runner hook** (`hooks/auto-test-runner.sh`) — PostToolUse async hook that runs the test suite in background after any source file edit. Detects Jest or Vitest automatically. Skips docs, config, and non-source files. Results delivered as a systemMessage on the next turn, with failure output routed for triage. Replaces the orchestrator's manual "call /backend-test-runner after coders finish" coordination pattern.

- **Git convention enforcement hook** (`hooks/enforce-git-conventions.sh`) — PreToolUse hook on all `git *` commands. Enforces:
  - Conventional commit format (`feat|fix|refactor|test|docs|chore(scope): subject`)
  - Branch naming convention (`feature/*`, `fix/*`, `refactor/*`, `hotfix/*`, `release/*`)
  - Blocks `git push --force` (suggests `--force-with-lease`)
  - Blocks direct push to `main`/`master`
  - Blocks `--no-verify` flag
  - Uses conditional hook (`if: "Bash(git *)"`) so the script only spawns for git commands, not every Bash call.

- **Auto-format hook** (`hooks/auto-format.sh`) — PostToolUse hook that runs Prettier and ESLint fix on edited source files (TS/JS/TSX/JSX/CSS). Runs synchronously before the async test runner so tests run against formatted code. Skips non-source files.

- **Auto-approve safe operations hook** (`hooks/auto-approve-safe-ops.sh`) — PermissionRequest hook that auto-approves known-safe Bash commands: `npm test`, `npm run lint`, `npx jest`, `npx vitest`, `npx playwright test`, `npx prettier`, `npx eslint`, `npx tsc --noEmit`, `git status`, `git diff`, `git log`, `git branch`, and similar read-only/non-destructive operations. Reduces permission prompt fatigue without compromising safety.

### Changed

- **`hooks/settings.json`** — Now includes all four hook categories: PostCompact (from Phase 1), PreToolUse (git enforcement), PostToolUse (auto-format + async test runner), and PermissionRequest (auto-approve). The PostToolUse hooks chain: format runs first (sync), then tests run in background (async).

### How the hooks chain works

```
You edit a file
  → PostToolUse fires
    → auto-format.sh runs (sync) — Prettier + ESLint fix
    → auto-test-runner.sh runs (async, background)
      → Tests pass → systemMessage: "Tests passing after editing src/auth.ts (8 passed)"
      → Tests fail → systemMessage: "TESTS FAILED... Route to test-spec or coder agent"
  → Claude continues working while tests run

You run a git commit
  → PreToolUse fires (conditional: only git commands)
    → enforce-git-conventions.sh checks:
      ✓ Conventional commit message format
      ✓ No force-push
      ✓ No push to main
      ✓ No --no-verify
    → Blocks with explanation if violated, proceeds if valid

You need to run npm test
  → PermissionRequest fires
    → auto-approve-safe-ops.sh matches "npm test"
    → Auto-approved, no dialog shown
```

### Migration Notes (Phase 1 → Phase 2)

1. Copy new hook scripts to `.claude/hooks/`:
   - `auto-test-runner.sh`
   - `enforce-git-conventions.sh`
   - `auto-format.sh`
   - `auto-approve-safe-ops.sh`
2. Make all executable: `chmod +x .claude/hooks/*.sh`
3. Replace your `.claude/settings.json` hooks section with the updated `hooks/settings.json` content (or merge manually).
4. Ensure `jq` is installed (used by all hook scripts for JSON parsing).

---

## [2.2.0] - 2026-03-29

### Phase 3: Agent Teams Integration

This release adds agent teams as an optional parallel execution pattern alongside the existing subagent dispatch. Agent teams enable true peer-to-peer communication between agents working on independent modules.

### Added

- **Agent Teams Guide** (`docs/AGENT_TEAMS_GUIDE.md`) — Comprehensive documentation covering:
  - When to use agent teams vs subagents (decision framework)
  - Four team patterns: parallel module development, multi-perspective review, competing hypotheses (bug investigation), and architecture exploration
  - File domain assignment rules (critical for teams — no worktree isolation)
  - Cost optimization strategies (~7x token cost vs standard sessions)
  - Limitations and risks

- **`/execute-prd` parallel mode** — `/execute-prd` now accepts `mode=parallel` for team-based implementation (merged from former `/team-autopilot`). Uses agent teams for the implementation phase when backend + frontend can be built simultaneously on non-overlapping file domains. Auto-detects when parallel mode is appropriate if not specified.

- **Agent teams environment flag** in `hooks/settings.json` — Enables the experimental agent teams feature:
  ```json
  { "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
  ```

### Changed

- **Orchestrator** (`agents/orchestrator.md`) — Added parallel execution decision framework. The orchestrator now evaluates whether to use subagents (default) or agent teams for each batch of parallel steps. Includes:
  - Decision tree: sequential/gated → subagents, independent modules → consider teams, multi-perspective → teams
  - Team creation template with file domain assignments
  - Critical team rules (non-overlapping domains, 3-5 teammates, verify completion)

- **CLAUDE.md** — Added Pattern B (agent teams) alongside the existing Pattern A (subagents) in the Agent Spawning Patterns section. Added reference to `docs/AGENT_TEAMS_GUIDE.md`.

- **PostCompact hook** (`hooks/reinject-context.sh`) — Added agent team workflow reminders (file domain rule, subagents vs teams).

### Architecture: Subagents vs Agent Teams

```
SUBAGENTS (Hub-and-Spoke) — Default
  Orchestrator
    ├→ backend-coder (worktree isolation)    ←─ results flow back
    ├→ frontend-coder (worktree isolation)   ←─ results flow back
    └→ test-spec                             ←─ results flow back
  ✓ Worktree isolation available
  ✓ Lower token cost
  ✓ Full gating control
  ✗ No peer communication

AGENT TEAMS (Peer-to-Peer) — For parallel independent modules
  Team Lead (orchestrator)
    ├←→ Backend teammate (owns src/backend/)   ←→ peer messages
    ├←→ Frontend teammate (owns src/frontend/) ←→ peer messages
    └←→ Test teammate (owns tests/)            ←→ peer messages
  ✓ Direct peer communication via SendMessage
  ✓ True parallel execution
  ✗ No worktree isolation (must assign file domains)
  ✗ Higher token cost (~7x)
  ✗ Experimental feature
```

### When to use which

| Scenario | Pattern |
|---|---|
| Standard gated workflow (plan → implement → test → review) | Subagents |
| Sequential steps with strict ordering | Subagents |
| Overlapping file changes | Subagents (worktree isolation) |
| 2+ independent modules, separate file domains | Agent teams |
| Multi-perspective review (security + performance + architecture) | Agent teams |
| Bug investigation with multiple hypotheses | Agent teams |
| Architecture exploration with competing designs | Agent teams |

### Migration Notes (Phase 2 → Phase 3)

1. Merge the new `env` section from `hooks/settings.json` into your `.claude/settings.json`.
2. `/team-autopilot` has been merged into `/execute-prd` (use `mode=parallel`).
3. Create the `docs/` directory and copy `docs/AGENT_TEAMS_GUIDE.md`.
4. Replace `agents/orchestrator.md` with the v2.2 version.
5. Update your `CLAUDE.md` with the new Pattern B section.
6. Update `hooks/reinject-context.sh` with the agent teams reminders.
7. **Note:** Agent teams are experimental. The standard subagent workflow remains the default and is unchanged.
