# CLAUDE.md — Development & Engineering Standards

## Project Overview
**Tech Stack:** Node.js 22 + TypeScript (Fastify/Express), React 18 + Next.js (App Router), Terraform + AWS SDK v3, Jest + Playwright, PostgreSQL + Prisma ORM

## Core Principles
- **Plan First:** Major changes require a written, reviewed plan and explicit approval before execution.
- **Think Independently:** Critically evaluate decisions; propose better alternatives when appropriate.
- **Confirm Before Action:** Seek approval before structural or production-impacting work.
- **UI-First & Test-Driven:** Validate UI early; all code must pass Jest + Playwright tests before merge.
- **Security Always:** Never commit secrets or credentials; follow least-privilege.
- **No Automated Co-Authors:** Do not include "Claude" or any AI as a commit co-author.

## Context Hierarchy
```
CLAUDE.md                 # Project-level standards
/src/CLAUDE.md            # Module/component rules & conventions
/features/<name>/CLAUDE.md# Feature-specific rules, risks, and contracts
/plans/*                  # Phase plans with context intelligence
/docs/*                   # Living docs (API, ADRs, runbooks)
```

## File Management
Never save working files, text/mds, or tests to the project root. Use:
- `/src` — Source code
- `/tests` — Test files
- `/docs` — Documentation & markdown
- `/config` — Configuration
- `/scripts` — Utility scripts
- `/examples` — Example code

## Agent Spawning Patterns

**Pattern A: Subagents (default — hub-and-spoke)**
```
Orchestrator dispatches to named agents in .claude/agents/:
  architect              → design (read-only + MCP tools, opus, memory: project)
  backend-coder         → backend impl + tests (sonnet, isolation: worktree, memory: project)
  frontend-coder        → frontend impl + tests (sonnet, isolation: worktree, memory: project)
  ui-ux                 → UX flows, design system guidance (sonnet, memory: project, AskUserQuestion)
  reviewer              → code review (opus, permissionMode: plan, memory: project)
  security-researcher   → security audit (opus, permissionMode: plan, memory: project)
```

**Pattern B: Parallel review team (reviewer + security-researcher)**
```
After coders finish implementation, reviewer and security-researcher run in parallel:
  - Reviewer checks functionality, style, test coverage, and API contracts
  - Security-researcher audits for vulnerabilities, data flows, and compliance

Both agents run concurrently with no dependencies, then results are merged.
```

## Task Tracking
- [ ] Incomplete or not started
- [✅] Completed
- [⚠️] Partially complete, requires user action
- [❌] Cannot be completed or do not do
- [⏳] Deferred (specify the phase)

## Testing
- ≥ 85% branch coverage project-wide; 100% for critical paths and security-sensitive code.
- Auto-generate unit tests for new/changed functions.
- Generate edge-case and mutation tests for critical paths.

## Security
- No secrets in code; store in vault, rotate quarterly.
- Lockfiles required; `npm audit --audit-level=moderate` in CI.
- Principle of least privilege for services and developers.
- Encryption in-transit and at-rest; RLS on all applicable tables.
- SAST/DAST and dependency scanning on every PR.

## UI Standards
- Use shadcn/ui; prefer composition over forking.
- Keep state minimal and localized; heavy state in hooks/stores.
- Prototype screens as static components under `UI_prototype/`.
- Validate key flows with Playwright.

## Backend, Database & Infra

**Prisma:** Keep schema in `prisma/schema.prisma`, commit all migrations. Use isolated test DB. Never hardcode connection strings — use `DATABASE_URL` via env.

**Terraform:** Plan → review → apply. Least privilege IAM. Runbooks in `/docs/runbooks/*`.

## Coding Standards
- TypeScript strict mode; two-space indentation.
- camelCase (variables/functions), PascalCase (components/classes), SCREAMING_SNAKE_CASE (consts).
- Prefer named exports, colocate tests and styles when logical.

## Commands
- Dev: `npm run dev`, Build: `npm run build`, Lint: `npm run lint:fix`
- Tests: `npm test` or `npx jest tests/<file>`, E2E: `npm run test:e2e`
- Database: `npm run db:migrate`, `npm run db:seed`
- Setup: `scripts/start.sh` (start), `scripts/stop.sh` (stop)

## Workflow
1. Plan: gather context, define risks and ADRs.
2. Prototype: build and validate UI.
3. Implement: backend + frontend with incremental, tested commits.
4. Verify: green tests + security scans.
5. Review & Merge: structured PR; tag phase completion.

Divide work into phases under `/plans/PHASE_*` with scope, risks, dependencies, exit criteria.

## Important
- Never save working files, text/mds, or tests to the root folder.
