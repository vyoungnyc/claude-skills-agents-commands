# CLAUDE.md — Development & Engineering Standards

## 📘 Project Overview
**Tech Stack:**
- **Backend:** Node.js 22 with TypeScript (Fastify/Express)
- **Frontend:** React 18 with Next.js (App Router)
- **Infrastructure:** Terraform + AWS SDK v3
- **Testing:** Jest (unit/integration) + Playwright (UI/e2e)
- **Database:** PostgreSQL + Prisma ORM

**Goal:**
Maintain a clean, type-safe, test-driven, and UI-first codebase emphasizing structured planning, intelligent context gathering, automation, disciplined collaboration, and enterprise-grade security and observability.

---

## 🧭 Core Principles
- **Plan First:** Every major change requires a clear, written, reviewed plan and explicit approval before execution.
- **Think Independently:** Critically evaluate decisions; propose better alternatives when appropriate.
- **Confirm Before Action:** Seek approval before structural or production-impacting work.
- **UI-First & Test-Driven:** Validate UI early; all code must pass Jest + Playwright tests before merge.
- **Context-Driven:** Use MCP tools (Context7 + Chunkhound) for up-to-date docs and architecture context.
- **Security Always:** Never commit secrets or credentials; follow least-privilege and configuration best practices.
- **No Automated Co-Authors:** Do not include “Claude” or any AI as a commit co-author.

---

## 🗂️ Context Hierarchy & Intelligence
Maintain layered, discoverable context so agents and humans retrieve only what’s necessary.

```
CLAUDE.md                 # Project-level standards
/src/CLAUDE.md            # Module/component rules & conventions
/features/<name>/CLAUDE.md# Feature-specific rules, risks, and contracts
/plans/*                  # Phase plans with context intelligence
/docs/*                   # Living docs (API, ADRs, runbooks)
```

### Context Intelligence Checklist
- Architecture Decision Records (ADRs) for major choices
- Dependency manifests with risk ratings and owners
- Performance baselines and SLOs (API P95, Core Web Vitals)
- Data classification and data-flow maps
- Security posture: threat model, secrets map, access patterns
- Integration contracts and schema versions

---

## 🚨 Concurrent Execution & File Management

**ABSOLUTE RULES**
1. All related operations MUST be batched and executed concurrently in a single message.
2. Never save working files, text/mds, or tests to the project root.
3. Use these directories consistently:
   - `/src` — Source code
   - `/tests` — Test files
   - `/docs` — Documentation & markdown
   - `/config` — Configuration
   - `/scripts` — Utility scripts
   - `/examples` — Example code
4. Use Claude Code’s Task tool to spawn parallel agents; MCP coordination, Claude executes.

### ⚡ Enhanced Golden Rule: Intelligent Batching
- **Context-Aware Batching:** Group by domain boundaries, not just operation type.
- **Dependency-Ordered Execution:** Respect logical dependencies within a batch.
- **Error-Resilient Batching:** Include rollback/compensation steps per batch.
- **Performance-Optimized:** Balance batch size vs. execution time and resource limits.

### Claude Code Task Tool Pattern (Authoritative)
```javascript
// Single message: spawn all agents with complete instructions
Task("Research agent",  "Analyze requirements, risks, and patterns", "researcher")
Task("Coder agent",     "Implement core features with tests",      "coder")
Task("Tester agent",    "Generate and execute test suites",        "tester")
Task("Reviewer agent",  "Perform code and security review",         "reviewer")
Task("Architect agent", "Design or validate architecture",          "system-architect")
Task("Code Expert",     "Advanced code analysis & refactoring",     "code-expert")
```

---

## 🤖 AI Development Patterns

### Specification-First Development
- Write executable specifications before implementation.
- Derive test cases from specs; bind coverage to spec items.
- Validate AI-generated code against specification acceptance criteria.

### Progressive Enhancement
- Ship a minimal viable slice first; iterate in safe increments.
- Maintain backward compatibility for public contracts.
- Use feature flags for risky changes; default off until validated.

### AI Code Quality Gates
- AI-assisted code review required for every PR.
- SAST/secret scanning in CI for all changes.
- Performance impact analysis for significant diffs.

### Task tracking in implementation plans and phase plans
- Mark incomplete tasks or tasks that have not started [ ]
- Mark tasks completed with [✅]
- Mark partially complete tasks that requires user action or changes with with [⚠️]
- Mark tasks that cannot be completed or marked as do not do with [❌]
- Mark deferred tasks with [⏳], and specify the phase it will be deferred to.

---

## 🧪 Advanced Testing Framework

### AI-Assisted Test Generation
- Auto-generate unit tests for new/changed functions.
- Produce integration tests from OpenAPI/contract specs.
- Generate edge-case and mutation tests for critical paths.

### Test Quality Metrics
- ≥ 85% branch coverage project-wide.
- 100% coverage for critical paths and security-sensitive code.
- Mutation score thresholds enforced for core domains.

### Continuous Testing Pipeline
- Pre-commit: lint, type-check, unit tests.
- Pre-push: integration tests, SAST/secret scans.
- CI: full tests, performance checks, cross-browser/device (UI).
- CD: smoke tests, health checks, observability validation.

---

## 📚 Documentation as Code

### Automation
- Generate API docs from OpenAPI/GraphQL schemas.
- Update architecture diagrams from code (e.g., TS AST, Prisma ERD).
- Produce changelogs from conventional commits.
- Build onboarding guides from project structure and runbooks.

### Quality Gates
- Lint docs for spelling, grammar, links, and anchors in CI.
- Track documentation coverage (e.g., exported symbols with docstrings).
- Ensure accessibility compliance for docs (WCAG 2.1 AA).

---

## 📊 Performance & Observability

### Budgets & SLOs
- Core Web Vitals: LCP < 2.5s, INP < 200ms, CLS < 0.1 on P75.
- API: P95 < 200ms for critical endpoints; P99 error rate < 0.1%.
- Build: end-to-end pipeline < 5 min; critical path bundles < 250KB gz.

### Observability Requirements
- Structured logging with correlation/trace IDs.
- Distributed tracing for all external calls.
- Metrics and alerting for latency, errors, saturation.
- Performance regression detection on CI-controlled environments.

---

## 🔐 Security Standards (Enterprise)

### Supply Chain & Secrets
- Lockfiles required; run `npm audit --audit-level=moderate` in CI.
- Enable Dependabot/Renovate with weekly grouped upgrades.
- Store secrets in vault; rotate at least quarterly; no secrets in code.

### Access & Data
- Principle of least privilege for services and developers.
- Data classification: public, internal, confidential, restricted.
- Document data flows and apply encryption in-transit and at-rest.
- Enable Row Level Security (RLS) on all tables where applicable.

### Vulnerability Response
- Critical CVEs patched within 24 hours; high within 72 hours.
- Security runbooks for incident triage and communications.
- Mandatory SAST/DAST and dependency scanning on every PR.

---

## 👥 Collaboration & Workflow

### Planning & Phase Files
- Divide work into phases under `/plans/PHASE_*`. Each phase includes:
  - Context Intelligence, scope, risks, dependencies.
  - High-level tasks → subtasks → atomic tasks.
  - Exit criteria and verification plan.

### Commit Strategy
- Commit atomic changes with clear intent and rationale.
- Conventional commits required; no AI co-authors.
- Example: `feat(auth): implement login validation (subtask complete)`

### Pull Requests
- Link phase/TODO files, summarize changes, include verification steps.
- Attach UI evidence for user-facing work.
- Document breaking changes and DB impacts explicitly.

### Reviews
- Address comments with a mini-plan; confirm before major refactors.
- Merge only after approvals and green CI.
- Tag releases by phase completion.

---

## 🎨 UI Standards
- Prototype screens as static components under `UI_prototype/`.
- Use shadcn/ui; prefer composition over forking.
- Keep state minimal and localized; heavy state in hooks/stores.
- Validate key flows with Playwright; include visual regression where useful.

---

## 🧭 Backend, Database & Infra

### Prisma & PostgreSQL
- Keep schema in `prisma/schema.prisma` and commit all migrations.
- Use isolated test DB; reset with `prisma migrate reset --force` in tests.
- Never hardcode connection strings; use `DATABASE_URL` via env.

```
prisma/
 ├─ schema.prisma
 ├─ migrations/
 └─ seed.ts
```

### Terraform & AWS
- Plan → review → apply for infra changes; logs kept for audits.
- Use least privilege IAM; rotate and scope credentials narrowly.
- Maintain runbooks in `/docs/runbooks/*` and keep diagrams up to date.

---

## 🧠 Coding Standards
- TypeScript strict mode; two-space indentation.
- camelCase (variables/functions), PascalCase (components/classes), SCREAMING_SNAKE_CASE (consts).
- Prefer named exports, colocate tests and styles when logical.
- Format on commit: `prettier --write .` and `eslint --fix`.

---

## 🧩 Commands
- Development: `npm run dev` (site), `npm run dev:email` (email preview)
- Build: `npm run build`
- Lint/Format: `npm run lint:fix`
- Tests:
  - Unit/Integration: `npm test` or `npx jest tests/<file>`
  - E2E: `npm run test:e2e` or `npx playwright test tests/<file>`
- Database: `npm run db:migrate`, `npm run db:seed`
- Automate setup with scripts:  
  - `scripts/start.sh` → start dependencies then app.  
  - `scripts/stop.sh` → gracefully stop app then dependencies.  

---

## ✅ Standard Development Lifecycle
1. Plan: gather context (Context7, Chunkhound), define risks and ADRs.
2. Prototype: build and validate UI.
3. Implement: backend + frontend with incremental, tested commits.
4. Verify: green Jest + Playwright + security scans.
5. Review & Merge: structured PR; tag phase completion.

---

## 📌 Important Notes
- All changes must be tested; if tests weren’t run, the code does not work.
- Prefer editing existing files over adding new ones; create files only when necessary.
- Use absolute paths for file operations.
- Keep `files.md` updated as a source-of-truth index.
- Be honest about status; do not overstate progress.
- Never save working files, text/mds, or tests to the root folder.