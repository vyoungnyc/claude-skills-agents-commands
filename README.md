# Multi-Agent Orchestration for Claude Code

A structured multi-agent workflow system for Claude Code that enforces strict delegation, gated approvals, and traceable software development lifecycle.

**Version:** 2.11.2
**Requires:** Claude Code v2.1.76+ (for Tool Search, worktree isolation, agent memory, hooks). Agent teams require v2.1.32+.

## What This Is

A set of agent definitions, skills, commands, and hooks that turn Claude Code into a disciplined development team:

- An **orchestrator** that never writes code — only delegates
- Specialized agents for architecture, implementation, testing, review, security, and documentation
- A **gated workflow** that enforces: plan → implement → test → security review → code review → docs
- **PLAN_steps.md** as the single source of truth for progress tracking

## Quick Start

1. Copy the contents to your project's `.claude/` directory:

```bash
mkdir -p .claude/agents .claude/skills .claude/commands .claude/hooks .claude/rules .claude/scripts/lib
cp -r agents/. .claude/agents/
cp -r skills/. .claude/skills/
cp -r commands/. .claude/commands/
cp -r rules/. .claude/rules/
cp hooks/*.sh .claude/hooks/
cp scripts/lib/*.sh .claude/scripts/lib/
cp scripts/*.sh .claude/scripts/
chmod +x .claude/hooks/*.sh .claude/scripts/*.sh .claude/scripts/lib/*.sh
```

For **global** (all-projects) use, copy to `~/.claude/` instead (`~/.claude/agents/`, `~/.claude/rules/`, etc.). If you deploy the hooks globally, merge the hook config into `~/.claude/settings.json` and change each hook command path from `"$CLAUDE_PROJECT_DIR"/.claude/hooks/` to `~/.claude/hooks/` — `$CLAUDE_PROJECT_DIR` points at the current project, not your home directory.

2. Merge the hook configuration from `hooks/settings.json` into your project's `.claude/settings.json`. For **global** deployment, copy the root `settings.json` to `~/.claude/settings.json` instead — its hook commands already use `$HOME` paths.

3. If your plans live somewhere other than `docs/features/*/PLAN_steps.md` or `plans/*/PLAN_steps.md`, adjust the glob in `hooks/plan-context.sh`.

4. Start building:

```
/discover "user authentication"
```

Or if you already have a PRD:

```
/discover
> "Do you have a PRD?" → Yes, here: spec.md
> Reviews → approves → auto-invokes /execute-prd
```

## Architecture

### Agents (8)

| Agent | Model | Key Features | Role |
|---|---|---|---|
| **orchestrator** | sonnet | memory: project, maxTurns: 50 | Coordinates workflow, never writes code |
| **architect** | opus | memory: project, MCP tools | System design, ADRs, governance |
| **backend-coder** | sonnet | isolation: worktree, memory: project | Backend implementation + tests |
| **frontend-coder** | sonnet | isolation: worktree, memory: project | Frontend implementation + tests |
| **coder** | sonnet | memory: project | General-purpose swarm implementer |
| **ui-ux** | sonnet | memory: project, AskUserQuestion | UX flows, design system, user research |
| **reviewer** | opus | permissionMode: plan, memory: project | Step-level review of implemented work against DoD and acceptance criteria. PR-scale multi-angle review is delegated to `/codereview` (Codex cross-check) or native `/code-review`. Runs in parallel with security-researcher |
| **security-researcher** | opus | permissionMode: plan, memory: project | Read-only security audit, runs in parallel with reviewer |

### Skills (11 — orchestrator invokes directly)

| Skill | Purpose |
|---|---|
| decision-cards | Present user-blocking questions as summary + recommendation-first cards with a per-card discuss loop |
| scan-feature-context | Gather relevant code/docs at feature kickoff |
| propose-architecture-for-feature | Design aligned with existing patterns |
| extract-requirements-from-ticket | Structure requirements from tickets |
| derive-plan-from-spec | Create PLAN_steps.md from specs |
| derive-test-spec-from-requirements | Test plan from requirements |
| summarize-diff-for-agents | Structured diff summaries for review |
| review-changes-structured | Blocking/non-blocking review feedback |
| update-plan-from-review-feedback | Convert review findings to fix tasks and incorporate into plan |
| run-quality-gates-and-triage | Interpret test/lint logs, group failures |
| sync-docs-with-implementation | Identify and update impacted docs |

### Commands (8)

| Command | Purpose |
|---|---|
| /discover | **Main entry point.** Interactive PRD discovery or review existing spec → adversarial review gate → auto-invokes `/execute-prd` on approval |
| /execute-prd | Execute a PRD through the full swarm pipeline: review → plan → issues → swarm → review → PR |
| /codereview | Interactive 7-angle code review — 5 Claude sub-agents + 2 Codex reviewers (standard + adversarial), haiku scoring, cross-source dedup. Surfaces all findings; you decide what to fix. |
| /pr-fix-loop | Fix review comments (Codex, Cursor BugBot, GitLab Copilot, users) with Category A/B/C triage, push, poll until 👍/✅ on PR description (mandatory approval gate) or 15 min silence |
| /mr-fix-loop | Fix review comments on GitLab MRs (GitLab Duo, Cursor BugBot, Codex, users) with Category A/B/C triage, fix pipeline failures locally, push, poll until MR approval or bot emoji gate or 15 min silence |
| /backend-test-runner | Run backend tests, analyze results, route failures |
| /frontend-test-runner | Run frontend tests, analyze results, route failures |
| /git | Branch management, commits, PRs, feedback handling |

### Hooks (7)

| Hook | Event | Purpose |
|---|---|---|
| response-style.sh | UserPromptSubmit | Reinject the Response Style pointer (BLUF, no preamble, epistemic labeling) every turn — CLAUDE.md rules fade under recency pressure over long sessions |
| plan-context.sh | PostCompact | Re-inject active PLAN_steps.md state after compaction (CLAUDE.md survives compaction natively) |
| auto-format.sh | PostToolUse (sync) | Auto-run Prettier + ESLint fix on edited source files |
| auto-test-runner.sh | PostToolUse (async) | Run test suite in background after file edits |
| pr-merge-sync-reminder.sh | PostToolUse | After `gh pr merge --squash`/`-s`, remind the agent to ask whether to run `scripts/sync-claude-config.sh --apply`. Project-scope only (`hooks/settings.json`) — not wired into the global `settings.json`, since it's specific to repos that ship this deploy script |
| enforce-git-conventions.sh | PreToolUse | Enforce conventional commits, branch naming, block force-push |
| auto-approve-safe-ops.sh | PermissionRequest | Auto-approve npm test, lint, tsc, git status, etc. |

### Scripts (6)

| Script | Platform | Purpose |
|---|---|---|
| poll-pr-reviews.sh | GitHub | Poll a PR for new review threads, approval emoji (👍/✅), or idle timeout. Used by `/pr-fix-loop`. |
| poll-mr-reviews.sh | GitLab | Poll an MR for new discussions, native approval, award emoji, pipeline failures, or idle timeout. Used by `/mr-fix-loop`. |
| create-github-issues.sh | GitHub | Create GitHub epic (tracking issue) + child issues from plan steps; output step→issue-number mapping for swarm sessions. |
| create-local-issues.sh | Any | Fallback for non-GitHub repos: create file-based epic + issues in `plans/` (gitignored). Same JSON output shape as GitHub script. Overwrite-protected (`FORCE_OVERWRITE=1` to rerun). |
| sync-claude-config.sh | Any | Deploy this repo's agents/skills/commands/rules/hooks/CLAUDE.md to `~/.claude` (or `$CLAUDE_HOME`). Dry run by default; `--apply` writes, backing up any overwritten file first. `settings.json` is never overwritten wholesale — only `hooks`/`env` are merged in, idempotently, preserving every other live-only key. |
| run-tests.sh | Any | Discovers and runs every `*.test.sh` suite in the repo (no hardcoded list); prints per-suite PASS/FAIL plus a final summary; exits 0 only if every suite passes. |

**Exit codes:** `0` = approved, `1` = new comments, `2` = idle timeout, `3` = blocked on human, `4` = pipeline failed (GitLab only), `10` = usage error, `11` = snapshot failure.

**Usage:**
```bash
# GitHub PR polling (60s interval, 15 polls max)
scripts/poll-pr-reviews.sh owner/repo 42 60 15

# GitLab MR polling (run from inside a GitLab repo)
scripts/poll-mr-reviews.sh 42 60 15

# Deploy this repo's config to ~/.claude — dry run first, then apply
scripts/sync-claude-config.sh
scripts/sync-claude-config.sh --apply

# Sync to an alternate target instead of $HOME/.claude
CLAUDE_HOME=/path/to/.claude scripts/sync-claude-config.sh --apply
```

### Testing

Run every test suite in the repo:

```bash
bash scripts/run-tests.sh
```

**Convention:** a shell file's tests live beside it as `<name>.test.sh` (e.g. `scripts/poll-pr-reviews.sh` → `scripts/poll-pr-reviews.test.sh`, `hooks/enforce-git-conventions.sh` → `hooks/enforce-git-conventions.test.sh`). `scripts/run-tests.sh` discovers every `*.test.sh` file under the repo automatically — no file needs to be registered anywhere — and runs each with `bash <file>` so a suite's file mode never affects whether it runs.

**Offline/stub rule:** no suite may reach the network. Suites that need `gh` or `glab` prepend a per-run temp directory containing a stub executable to `PATH`; `jq` is a genuine dependency of both the scripts and their suites, and every suite exits with a clear message if it is missing.

## Platform Support

| Component | GitHub | GitLab | Notes |
|---|---|---|---|
| **Hooks** (all 7) | ✅ | ✅ | Platform-agnostic — operates at the git level (`pr-merge-sync-reminder.sh` matches `gh pr merge`, GitHub-specific but harmless on GitLab repos since it only fires on that exact command) |
| **Agents** (all 8) | ✅ | ✅ | No platform-specific logic |
| **Skills** (all 11) | ✅ | ✅ | No platform-specific logic |
| **/discover** | ✅ | ✅ | Platform-agnostic — produces PRD files |
| **/execute-prd** | ✅ | ✅ | Auto-detects GitHub vs local issue tracking |
| **/backend-test-runner** | ✅ | ✅ | No platform-specific logic |
| **/frontend-test-runner** | ✅ | ✅ | No platform-specific logic |
| **/git** | ✅ | ✅ | No platform-specific logic |
| **/pr-fix-loop** | ✅ | ❌ | GitHub only — uses GitHub GraphQL API |
| **/mr-fix-loop** | ❌ | ✅ | GitLab only — uses GitLab discussions API and `glab` CLI |
| **Issue tracking** | ✅ GitHub Issues | ✅ Local files | Auto-detected: `gh` + GitHub remote → GitHub Issues; otherwise → `plans/` files (gitignored) |
| **Swarm dispatch** | ✅ | ✅ | Platform-agnostic — native background subagents with built-in worktree isolation |

`/pr-fix-loop` is built on GitHub's review thread model. `/mr-fix-loop` is its GitLab counterpart. Issue tracking auto-detects: GitHub repos get epic + child issues via `gh` CLI; non-GitHub repos get file-based tracking in `plans/` (gitignored).

## Key Design Principles

**Strict delegation** — The orchestrator and autopilot commands MUST NOT write code. All substantive work goes through specialized agents.

**Gated workflow** — Features are not "done" until all gates pass: tests green, security reviewed, code reviewed, docs updated.

**PLAN_steps.md** — Single source of truth for step tracking with step_id, dependencies, status, and definition of done.

**AskUserQuestion routing** — Only architect and ui-ux can ask the user clarifying questions. Other agents escalate through them.

**Three parallel patterns** — Subagents (hub-and-spoke, worktree isolation) for 1-2 steps. Agent teams (peer-to-peer, SendMessage, work-stealing) for peer collaboration. Native swarm (one background `coder` subagent per domain batch, `isolation: worktree`, complexity-based model selection) for 3+ steps. The orchestrator auto-selects based on step count and domain separability.

**Persistent memory** — Agents accumulate knowledge across sessions, getting better at reviewing your specific codebase over time.

**Deterministic hooks** — Git conventions, test execution, and code formatting are enforced by hooks (100% execution rate), not by prompt instructions (~80% adherence).

## What Changed

See [CHANGELOG.md](CHANGELOG.md) for full details.

**v2.10.1** — Pre-merge checklist codified in CLAUDE.md + `/git`:
- New `## Git` bullet: before every squash-merge, check whether the branch is behind the target and rebase if so, and — if the repo tracks a version (README `**Version:**` + matching `CHANGELOG.md` entry) — verify the bump is still correct against the target branch's current version before merging
- `commands/git.md`'s `sync-branch` guidance extended to match, so the check is visible to anyone running `/git` too
- Deploys with CLAUDE.md via `scripts/sync-claude-config.sh`, so any project using this repo's config picks up the same habit — this version bump is itself the first real exercise of the rule it adds

**v2.10.0** — `pr-merge-sync-reminder.sh`: nudge to sync after a squash merge:
- New PostToolUse hook fires when a `Bash` call runs `gh pr merge` with `--squash`/`-s`, and surfaces a `systemMessage` telling the agent to ask whether to run `scripts/sync-claude-config.sh --apply`
- Project-scope only (`hooks/settings.json`) — deliberately not added to the global `settings.json`, since `gh pr merge` in an unrelated repo has nothing to do with this repo's deploy script
- Hook count 6 → 7

**v2.9.0** — `sync-claude-config.sh`: deploy this repo to `~/.claude`:
- New script closes the gap this repo has always had: agents/skills/commands/rules deploy instructions existed in this README, but nothing automated pushing changes to the live global config, and `settings.json` had to be hand-merged
- Dry run by default (prints planned changes, touches nothing); `--apply` writes. Directories are overlay-copied (never deletes a live-only file); `CLAUDE.md` is fully replaced only when it differs; `settings.json` gets only `hooks`/`env` merged in, idempotently, preserving every other live-only key (`enabledPlugins`, `effortLevel`, etc.)
- Every overwritten file is backed up first under `<CLAUDE_HOME>/backups/sync-<timestamp>/`
- `CLAUDE_HOME` env var overrides the target for testing or an alternate deploy location. Script count 5 → 6

**v2.8.0** — Response Style rules + drift-resistant reinjection:
- New `## Response Style` section in CLAUDE.md: BLUF always (conclusion first, max 5 bullets, then decreasing importance), no preamble/recap, no validation-as-move or reflexive praise, no performed insight, plain language tested by portability, compression rules with exceptions for security/destructive/ordered-instruction content, don't re-suggest declined follow-ups, label epistemic status (known/inferred/guessed)
- New `hooks/response-style.sh` (UserPromptSubmit) reinjects a short pointer to those rules on every turn — CLAUDE.md rules fade under recency pressure over long sessions; the hook fires exactly where recency helps instead of restating the rule set every turn. Wired into both `settings.json` (global, `$HOME` paths) and `hooks/settings.json` (project-scope mirror). Hook count 5 → 6
- Since CLAUDE.md already deploys to `~/.claude/CLAUDE.md` at user scope, both the rules and the reinjection hook apply across every project once deployed, not just this repo

**v2.7.0** — Test suites for the four untested scripts + poll-scripts repair:
- Both poll scripts aborted on their first poll iteration, in every configuration, before this release — fixed in `scripts/lib/poll-common.sh` (subshell count loss, invalid jq JSON escape, empty-array trap under `set -u`)
- New `.test.sh` suites for `create-github-issues.sh`, `create-local-issues.sh`, `poll-pr-reviews.sh`, `poll-mr-reviews.sh`, asserting each script's full documented exit-code contract against stubbed `gh`/`glab`
- `scripts/run-tests.sh` added — discovers and runs every `*.test.sh` suite in the repo; script count 4 → 5
- `hooks/auto-test-runner.sh` extended to run the suite on any `*.sh` edit
- `docs/features/script_tests/FINDINGS.md` records repaired and open defects; `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3 exit criterion marked MET — this feature's own 4-batch native swarm run is the evidence

**v2.6.0** — Native swarm dispatch (`swarm-dispatch.sh` retired):
- `scripts/swarm-dispatch.sh` deleted — 533 lines of bash replaced by native background subagents; script count 5 → 4
- 3+ parallelizable steps → one background `coder` subagent per domain batch, `isolation: worktree`, model by batch complexity
- Steps pre-assigned inline in spawn prompts; the `TaskCreate` queue is orchestrator-side progress tracking (workers can't see the Task tools)
- Merge-back is an orchestrator-owned sequence that keeps the script's guards: skip failed/incomplete workers and absent branches, salvage dirty worktrees before removal
- Recovery: `max_turns` → model-upgrade respawn, stalled worker → `SendMessage` continuation while its worktree lives; `launch_failure` and `claude --resume` retired
- Turn budget fixed at `coder.md`'s `maxTurns: 30` for every worker — complexity now selects the model only
- Orchestrator gains `TaskCreate`/`TaskList`/`TaskUpdate`/`SendMessage`; `docs/PHASE_6_NATIVE_PARALLELISM.md` §P6.3 marked superseded

**v2.5.0** — Native-feature modernization (Aug 2026 audit):
- CLAUDE.md rewritten for user scope; stack standards moved to path-scoped `rules/`
- Global hook deployment via root `settings.json` (`$HOME` paths — `$CLAUDE_PROJECT_DIR` doesn't work at user scope)
- `reinject-context.sh` → `plan-context.sh` (CLAUDE.md survives compaction natively; only plan state needs re-injection)
- Reviewer agent slimmed to Step Review Mode; PR-scale review delegated to `/codereview` or native `/code-review`
- Removed `fix-lint-and-typescript-errors` skill (native capability)
- Added `docs/PHASE_6_NATIVE_PARALLELISM.md` — plan to evaluate native background subagents + worktrees vs `swarm-dispatch.sh`

**v2.4.0** — Multi-angle parallel review system:
- Reviewer agent PR Review Mode — 5-angle parallel review with haiku scoring and dedup
- `/codereview` command — 7-angle review (5 Claude + 2 Codex), user decides what to fix
- `/discover` adversarial review gate — inline PRD review before `/execute-prd`
- Codex scope handling, failure threshold clarity, feature ID derivation, branch detection

**v2.3.2** — Hardening, correctness fixes, and tiered failure recovery:
- Fixed critical merge bug: failed sessions were silently merged (subshell exit code masking)
- Tiered failure recovery: `max_turns` → upgrade model, `tool_error` → escalate, `context_overflow` → opus 1M, `infrastructure` → resume
- Cleaned 28 stale references to removed agents (planner, test-spec, documenter)
- Data loss prevention: auto-commit before merge, overwrite protection for local issues, dirty-tree guard
- Preflight dependency checks, remote branch fetch, YAML escaping, model name normalization

**v2.3.1 (Phase 5)** — Swarm architecture, discovery, and issue tracking:
- `/discover` command — interactive PRD creation with codebase analysis, web research, scope management, incremental splits
- Swarm dispatch — parallel claude sessions in worktrees, complexity-based model selection (opus/sonnet/haiku)
- GitHub Issues integration — epic + child issues with acceptance criteria, progress bars, roadmap tables
- Local issue fallback — file-based `plans/` tracking for GitLab/non-GitHub repos (gitignored)
- `coder.md` agent — general-purpose swarm coder with work-stealing and issue validation
- Full pipeline: `/discover` → PRD → `/execute-prd` → Epic+Issues → Swarm → Review → PR
- Agent count: 7 → 8; Command count: 6 → 7; Script count: 3 → 5

**v2.3.0 (Phase 4)** — Agent architecture simplification:
- Removed planner, test-spec, and documenter agents (demoted to skills)
- Orchestrator now invokes `derive-plan-from-spec`, `derive-test-spec-from-requirements`, and `sync-docs-with-implementation` skills directly
- Backend and frontend coders now implement tests alongside code (no separate test-spec agent)
- Reviewer and security-researcher run in parallel (parallel review team)
- `/execute-prd` no longer supports sequential mode, always parallel
- Agent count reduced from 10 to 7
- CLAUDE.md and README.md updated to reflect new architecture

**v2.1.0 (Phase 2)** — Hook automation:
- Auto-run tests in background after file edits
- Auto-format with Prettier + ESLint after edits
- Git convention enforcement (conventional commits, branch naming, block force-push/main push)
- Auto-approve safe operations (npm test, lint, git status, etc.)

**v2.0.0 (Phase 1)** — Modernize for Claude Code v2.1.86:
- Removed RAG agent (agents query MCP tools directly, Tool Search handles token efficiency)
- Removed session-checkpoint skill (replaced by PostCompact hook + auto-memory)
- Added worktree isolation for coders
- Added persistent memory for all agents
- Added read-only permission mode for reviewers
- Added per-agent model tuning (opus/sonnet/haiku)
- Streamlined agent definitions by 40-60%

## Directory Structure

```
agents/
  architect.md
  backend-coder.md
  coder.md
  frontend-coder.md
  orchestrator.md
  reviewer.md
  security-researcher.md
  ui-ux.md
commands/
  backend-test-runner.md
  codereview.md
  discover.md
  execute-prd.md
  frontend-test-runner.md
  git.md
  mr-fix-loop.md
  pr-fix-loop.md
docs/
  AGENT_TEAMS_GUIDE.md
  CI_DISPATCH.md             # Headless implementation-phase dispatch from GitHub Actions
  REMOTE_DISPATCH_NOTES.md   # Research note: remote (cloud) workers vs local worktrees
  PHASE_6_NATIVE_PARALLELISM.md  # Decision record (historical; §P6.3 superseded)
skills/
  decision-cards/            # User-blocking questions: summary + cards + discuss loop
  derive-plan-from-spec/
  derive-test-spec-from-requirements/
  extract-requirements-from-ticket/
  propose-architecture-for-feature/
  review-changes-structured/
  run-quality-gates-and-triage/
  scan-feature-context/
  summarize-diff-for-agents/
  sync-docs-with-implementation/
  update-plan-from-review-feedback/
scripts/
  lib/poll-common.sh         # Shared functions: PID file, validation, set-diff
  poll-pr-reviews.sh         # GitHub PR polling for /pr-fix-loop
  poll-pr-reviews.test.sh    # Test suite for poll-pr-reviews.sh
  poll-mr-reviews.sh         # GitLab MR polling for /mr-fix-loop
  poll-mr-reviews.test.sh    # Test suite for poll-mr-reviews.sh
  create-github-issues.sh    # GitHub epic + child issues from plan steps
  create-github-issues.test.sh  # Test suite for create-github-issues.sh
  create-local-issues.sh     # Non-GitHub fallback: file-based issues in plans/
  create-local-issues.test.sh   # Test suite for create-local-issues.sh
  sync-claude-config.sh      # Deploy agents/skills/commands/rules/hooks/CLAUDE.md to ~/.claude
  sync-claude-config.test.sh    # Test suite for sync-claude-config.sh
  run-tests.sh                # Discovers and runs every *.test.sh suite in the repo
rules/
  typescript.md              # Path-scoped: TS/React standards (loads only for *.ts/*.tsx)
  infra.md                   # Path-scoped: Prisma/Terraform standards (loads only for matching files)
hooks/
  response-style.sh          # UserPromptSubmit: reinject BLUF/response-style pointer
  plan-context.sh            # PostCompact: re-inject active plan state
  pr-merge-sync-reminder.sh  # PostToolUse: remind to run sync-claude-config.sh after a squash merge
  pr-merge-sync-reminder.test.sh  # Test suite for pr-merge-sync-reminder.sh
  auto-format.sh             # PostToolUse: Prettier + ESLint
  auto-test-runner.sh        # PostToolUse: background tests
  enforce-git-conventions.sh # PreToolUse: commit/branch/push rules
  auto-approve-safe-ops.sh   # PermissionRequest: skip dialog for safe ops
  settings.json              # Project-scope hook config (merge into .claude/settings.json)
settings.json                # Global settings incl. hooks ($HOME paths) — deploy to ~/.claude/settings.json
CLAUDE.md                    # Global (user-scope) standards — stack specifics live in rules/
CHANGELOG.md
README.md
```

## License

MIT
