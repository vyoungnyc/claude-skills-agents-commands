# CLAUDE.md — Global Engineering Standards

<!-- This file deploys to ~/.claude/CLAUDE.md (user scope — loaded in EVERY project).
     Keep it universal. Stack-specific rules live in rules/ (path-scoped, load only
     when matching files are touched). Per-project architecture, commands, and
     conventions belong in each repo's own CLAUDE.md — run /init there. -->

These are cross-project personal standards. Project-specific details (tech stack, build commands, architecture) belong in each project's own `CLAUDE.md`, not here.

## Core Principles

- **Plan first:** Major or structural changes require a written plan and my explicit approval before implementation. Use plan mode for this.
- **Think independently:** Critically evaluate decisions; propose better alternatives when appropriate.
- **Security always:** Never commit secrets or credentials. Least privilege for services and developers.
- **No AI co-authors:** Never add "Claude" or any AI as a commit co-author. No "Generated with" footers in commits or PR bodies.

## File Management

Never save working files, scratch notes/markdown, or tests to a project root. Use the project's structure: `/src`, `/tests`, `/docs`, `/config`, `/scripts`, `/examples`. Phased work goes under `/plans/PHASE_*` with scope, risks, dependencies, and exit criteria.

## Git

- Conventional commits: `type(scope): subject` (feat/fix/refactor/test/docs/chore).
- Feature branches (`feature/<id>`); never commit directly to main; never force-push shared branches.
- Commit and push only when asked, or when an approved workflow step requires it.

## Testing

- New or changed behavior ships with tests in the same change.
- Target ≥ 85% branch coverage; 100% for critical paths and security-sensitive code.
- All tests must pass before merge.

## Task Tracking Markers

- `[ ]` not started · `[✅]` done · `[⚠️]` needs user action · `[❌]` blocked/won't do · `[⏳]` deferred (note target phase)

## Multi-Agent Orchestration

Agents are defined in `~/.claude/agents/` (orchestrator, architect, backend-coder, frontend-coder, coder, ui-ux, reviewer, security-researcher). Dispatch rules:

- 1–2 parallelizable steps → subagents with `isolation: worktree`.
- 3+ parallelizable steps → native swarm: one background `coder` subagent per domain batch, `isolation: worktree`, model by batch complexity; steps pre-assigned inline in the spawn prompt.
- After implementation, run **reviewer** and **security-researcher** in parallel — never sequentially.
- Only **architect** and **ui-ux** may ask the user clarifying questions; other agents escalate through them.
- Agent teams (peer-to-peer) only when teammates must debate or share findings; assign non-overlapping file domains. Full guidance: `docs/AGENT_TEAMS_GUIDE.md`.

## Feature-Work Artifacts

- `docs/features/<task_id>/ARCHITECTURE.md` — design source of truth (owned by architect)
- `docs/features/<task_id>/PLAN_steps.md` — step tracking, single source of progress
- `docs/features/<task_id>/UX_NOTES.md` — UX decisions (owned by ui-ux)
