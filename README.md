# Multi-Agent Orchestration for Claude Code

A structured multi-agent workflow system for Claude Code that enforces strict delegation, gated approvals, and traceable software development lifecycle.

**Version:** 2.2.0
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
mkdir -p .claude/agents .claude/skills .claude/commands .claude/hooks
cp -r agents/. .claude/agents/
cp -r skills/. .claude/skills/
cp -r commands/. .claude/commands/
cp hooks/*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh
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

4. Run the autopilot:

```
/feature-autopilot FEATURE_ID spec-file.md
```

Or invoke the orchestrator directly with a task description.

## Architecture

### Agents (10)

| Agent | Model | Key Features | Role |
|---|---|---|---|
| **orchestrator** | opus | memory: project, maxTurns: 50 | Coordinates workflow, never writes code |
| **architect** | opus | memory: project, MCP tools | System design, ADRs, AskUserQuestion |
| **planner** | sonnet | memory: project, AskUserQuestion | PLAN_steps.md tracking, step decomposition |
| **backend-coder** | sonnet | isolation: worktree, memory: project | Backend implementation |
| **frontend-coder** | sonnet | isolation: worktree, memory: project | Frontend implementation |
| **test-spec** | sonnet | memory: project, MCP tools | Test design and implementation |
| **reviewer** | opus | permissionMode: plan, memory: project | Read-only code review |
| **security-researcher** | opus | permissionMode: plan, memory: project | Read-only security audit |
| **documenter** | haiku | memory: project | Docs and changelogs (cost-efficient) |
| **ui-ux** | sonnet | memory: project, AskUserQuestion | UX flows, design system guidance |

### Skills (12)

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

### Commands (5)

| Command | Purpose |
|---|---|
| /feature-autopilot | Full automated workflow from spec to docs (sequential or parallel mode) |
| /pr-fix-loop | Fix review comments (Codex, Cursor BugBot, GitLab Copilot, users) with Category A/B/C triage, push, poll until 👍/✅ or 15 min silence |
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

## Key Design Principles

**Strict delegation** — The orchestrator and autopilot commands MUST NOT write code. All substantive work goes through specialized agents.

**Gated workflow** — Features are not "done" until all gates pass: tests green, security reviewed, code reviewed, docs updated.

**PLAN_steps.md** — Single source of truth for step tracking with step_id, dependencies, status, and definition of done.

**AskUserQuestion routing** — Only architect, ui-ux, and planner can ask the user clarifying questions. Other agents escalate through them.

**Dual parallel patterns** — Subagents (hub-and-spoke, with worktree isolation) for standard workflows. Agent teams (peer-to-peer, with SendMessage) for truly independent parallel modules. The orchestrator chooses based on file domain separability and task characteristics.

**Persistent memory** — Agents accumulate knowledge across sessions, getting better at reviewing your specific codebase over time.

**Deterministic hooks** — Git conventions, test execution, and code formatting are enforced by hooks (100% execution rate), not by prompt instructions (~80% adherence).

## What Changed

See [CHANGELOG.md](CHANGELOG.md) for full details.

**v2.2.0 (Phase 3)** — Agent teams integration:
- Added agent teams as optional peer-to-peer parallel execution pattern
- `/feature-autopilot` now supports `mode=parallel` for team-based feature workflows (merged from `/team-autopilot`)
- Orchestrator now has a decision framework for choosing subagents vs teams
- Agent Teams Guide with 4 patterns: parallel modules, multi-perspective review, competing hypotheses, architecture exploration
- Enabled `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in settings

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
  documenter.md
  frontend-coder.md
  orchestrator.md
  planner.md
  reviewer.md
  security-researcher.md
  test-spec.md
  ui-ux.md
commands/
  backend-test-runner.md
  feature-autopilot.md
  frontend-test-runner.md
  git.md
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
