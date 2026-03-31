# Multi-Agent Orchestration for Claude Code

A structured multi-agent workflow system for Claude Code that enforces strict delegation, gated approvals, and traceable software development lifecycle.

**Version:** 2.4.0
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
mkdir -p .claude/agents .claude/skills .claude/commands .claude/hooks .claude/scripts/lib
cp -r agents/. .claude/agents/
cp -r skills/. .claude/skills/
cp -r commands/. .claude/commands/
cp hooks/*.sh .claude/hooks/
cp scripts/lib/*.sh .claude/scripts/lib/
cp scripts/*.sh .claude/scripts/
chmod +x .claude/hooks/*.sh .claude/scripts/*.sh .claude/scripts/lib/*.sh
```

2. Merge the hook configuration into your `.claude/settings.json`:

```json
{
  "hooks": {
    "PostCompact": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/reinject-context.sh",
          "statusMessage": "Re-injecting project context..."
        }]
      }
    ]
  }
}
```

3. Customize `hooks/reinject-context.sh` with your project's specific standards.

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
| **reviewer** | opus | permissionMode: plan, memory: project, Agent (read-only sub-agents only) | Code review with built-in 5-angle parallel PR Review Mode (CLAUDE.md compliance, bug scan, git history, PR comments, code comments). Scores with haiku, deduplicates. Runs in parallel with security-researcher |
| **security-researcher** | opus | permissionMode: plan, memory: project | Read-only security audit, runs in parallel with reviewer |

### Skills (11 — orchestrator invokes directly)

| Skill | Purpose |
|---|---|
| scan-feature-context | Gather relevant code/docs at feature kickoff |
| propose-architecture-for-feature | Design aligned with existing patterns |
| extract-requirements-from-ticket | Structure requirements from tickets |
| derive-plan-from-spec | Create PLAN_steps.md from specs |
| derive-test-spec-from-requirements | Test plan from requirements |
| summarize-diff-for-agents | Structured diff summaries for review |
| review-changes-structured | Blocking/non-blocking review feedback |
| update-plan-from-review-feedback | Convert review findings to fix tasks and incorporate into plan |
| run-quality-gates-and-triage | Interpret test/lint logs, group failures |
| fix-lint-and-typescript-errors | Resolve lint/TS issues safely |
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

### Hooks (5)

| Hook | Event | Purpose |
|---|---|---|
| reinject-context.sh | PostCompact | Re-inject project standards after context compaction |
| auto-format.sh | PostToolUse (sync) | Auto-run Prettier + ESLint fix on edited source files |
| auto-test-runner.sh | PostToolUse (async) | Run test suite in background after file edits |
| enforce-git-conventions.sh | PreToolUse | Enforce conventional commits, branch naming, block force-push |
| auto-approve-safe-ops.sh | PermissionRequest | Auto-approve npm test, lint, tsc, git status, etc. |

### Scripts (5)

| Script | Platform | Purpose |
|---|---|---|
| poll-pr-reviews.sh | GitHub | Poll a PR for new review threads, approval emoji (👍/✅), or idle timeout. Used by `/pr-fix-loop`. |
| poll-mr-reviews.sh | GitLab | Poll an MR for new discussions, native approval, award emoji, pipeline failures, or idle timeout. Used by `/mr-fix-loop`. |
| swarm-dispatch.sh | Any | Launch N parallel claude sessions in git worktrees with complexity-based model selection, failure classification (`max_turns`/`tool_error`/`context_overflow`/`infrastructure`/`launch_failure`), safe merge with auto-commit and dirty-tree guards. Used by orchestrator for 3+ step swarms. |
| create-github-issues.sh | GitHub | Create GitHub epic (tracking issue) + child issues from plan steps; output step→issue-number mapping for swarm sessions. |
| create-local-issues.sh | Any | Fallback for non-GitHub repos: create file-based epic + issues in `plans/` (gitignored). Same JSON output shape as GitHub script. Overwrite-protected (`FORCE_OVERWRITE=1` to rerun). |

**Exit codes:** `0` = approved, `1` = new comments, `2` = idle timeout, `3` = blocked on human, `4` = pipeline failed (GitLab only), `10` = usage error, `11` = snapshot failure.

**Usage:**
```bash
# GitHub PR polling (60s interval, 15 polls max)
scripts/poll-pr-reviews.sh owner/repo 42 60 15

# GitLab MR polling (run from inside a GitLab repo)
scripts/poll-mr-reviews.sh 42 60 15
```

## Platform Support

| Component | GitHub | GitLab | Notes |
|---|---|---|---|
| **Hooks** (all 5) | ✅ | ✅ | Platform-agnostic — operates at the git level |
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
| **Swarm dispatch** | ✅ | ✅ | Platform-agnostic — uses git worktrees and `claude` CLI |

`/pr-fix-loop` is built on GitHub's review thread model. `/mr-fix-loop` is its GitLab counterpart. Issue tracking auto-detects: GitHub repos get epic + child issues via `gh` CLI; non-GitHub repos get file-based tracking in `plans/` (gitignored).

## Key Design Principles

**Strict delegation** — The orchestrator and autopilot commands MUST NOT write code. All substantive work goes through specialized agents.

**Gated workflow** — Features are not "done" until all gates pass: tests green, security reviewed, code reviewed, docs updated.

**PLAN_steps.md** — Single source of truth for step tracking with step_id, dependencies, status, and definition of done.

**AskUserQuestion routing** — Only architect and ui-ux can ask the user clarifying questions. Other agents escalate through them.

**Three parallel patterns** — Subagents (hub-and-spoke, worktree isolation) for 1-2 steps. Agent teams (peer-to-peer, SendMessage, work-stealing) for peer collaboration. Swarm (parallel claude sessions in worktrees, complexity-based model selection) for 3+ steps. The orchestrator auto-selects based on step count and domain separability.

**Persistent memory** — Agents accumulate knowledge across sessions, getting better at reviewing your specific codebase over time.

**Deterministic hooks** — Git conventions, test execution, and code formatting are enforced by hooks (100% execution rate), not by prompt instructions (~80% adherence).

## What Changed

See [CHANGELOG.md](CHANGELOG.md) for full details.

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
skills/
  derive-plan-from-spec/
  derive-test-spec-from-requirements/
  extract-requirements-from-ticket/
  fix-lint-and-typescript-errors/
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
  poll-mr-reviews.sh         # GitLab MR polling for /mr-fix-loop
  swarm-dispatch.sh          # Parallel claude sessions in worktrees for /execute-prd swarm
  create-github-issues.sh    # GitHub epic + child issues from plan steps
  create-local-issues.sh     # Non-GitHub fallback: file-based issues in plans/
hooks/
  reinject-context.sh        # PostCompact: re-inject standards
  auto-format.sh             # PostToolUse: Prettier + ESLint
  auto-test-runner.sh        # PostToolUse: background tests
  enforce-git-conventions.sh # PreToolUse: commit/branch/push rules
  auto-approve-safe-ops.sh   # PermissionRequest: skip dialog for safe ops
  settings.json              # Hook configuration (merge into .claude/settings.json)
CLAUDE.md
CHANGELOG.md
README.md
```

## License

MIT
