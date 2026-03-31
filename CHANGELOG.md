# Changelog

All notable changes to this multi-agent orchestration system are documented in this file.

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
