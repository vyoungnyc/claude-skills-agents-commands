# Claude Skills, Agents & Commands

A multi-agent orchestration framework for Claude Code that enables automated, coordinated software development workflows. This repository provides a collection of specialized AI agents, reusable skills, and commands that work together to handle complex feature development from specification to deployment.

## Overview

This framework implements a **multi-agent architecture** where specialized agents handle different aspects of software development:

- **Orchestrator** coordinates the workflow
- **Specialist agents** handle architecture, coding, testing, review, and documentation
- **Skills** provide reusable capabilities that agents can invoke
- **Commands** execute specific operations like running tests or managing git

### Repository Structure
```
claude-skills-agents-commands/
├── agents/                     # Agent definitions
├── skills/                     # Custom skill definitions
├── commands/                   # Slash command definitions
├── CLAUDE.md                   # Claude Code project config (needs refactor)
└── README.md                  # This introduction
```

Each folder contains the respective Claude Code artifacts:
- agents/ → Agent descriptors / workflows
- skills/ → Skill definitions & instructions
- commands/ → Slash command markdown files



### Quick Start

1. Copy the contents to your `~/.claude/` folder:
  ```
  cp -r agents skills commands ~/.claude/
  ```
2. Run the orchestrator with a specification file:
   ```bash
   /feature-autopilot @docs/spec.md
   ```

### MCP Dependencies

This framework leverages these MCP (Model Context Protocol) servers:

1. **[Context7](https://context7.com/)** - For documentation and code graph navigation
2. **[ChunkHound](https://github.com/chunkhound/chunkhound)** - For RAG-based code search

### Tips

- Use individual agents for specific tasks without the full orchestration workflow
- If interrupted (pressing escape), resume with: `continue where you left off`
- If you close the terminal, reopen with `claude --continue` and prompt `continue where you left off`
- Use another LLM (ChatGPT, Claude) in planning mode to create specification markdown files

---

## Agents

Agents are specialized AI personas that handle specific aspects of the development workflow. Each agent has defined responsibilities, tools, and collaboration patterns.

### orchestrator

**Supervisor/orchestrator. Coordinates subagents, advances plan steps, and maintains overall task progress.**

The central coordinator that manages the multi-agent workflow. Routes work to appropriate agents, tracks progress through `PLAN_steps.md`, handles blockers and escalations, and maintains status reporting. Does not write production code—only coordinates.

**Key responsibilities:**
- Initialize and manage `PLAN_steps.md`
- Dispatch steps to appropriate agents
- Coordinate parallel work when dependencies allow
- Handle quality gates and approval flows
- Emit session checkpoints for recovery

---

### architect

**Architecture & codebase cartographer. Designs how features fit into the existing system, captures decisions, and answers clarifications.**

Understands the existing system and designs changes before implementation. Creates `ARCHITECTURE.md` documents covering context, goals, proposed design, impact analysis, and implementation notes.

**Key responsibilities:**
- Discover current architecture, patterns, and utilities
- Design feature integration into existing systems
- Identify impacted areas and risks
- Answer clarifying questions from other agents
- Escalate product/behavior decisions to users

---

### planner

**Task decomposer & planner. Turns architecture into ordered, atomic steps with clear ownership and Definitions of Done.**

Transforms feature-level designs into small, ordered, trackable steps. Owns `PLAN_steps.md` with step definitions including IDs, dependencies, status, and handoff targets.

**Key responsibilities:**
- Decompose features into atomic, executable steps
- Define clear Definition of Done (DoD) for each step
- Identify parallelizable work
- Track step status and handle blockers
- Convert review feedback into plan updates

---

### backend-coder

**Backend feature implementer. Writes and refactors backend code according to the design and plan, coordinating with tests and reviews.**

Implements and refactors backend code following the Architect's design and Planner's steps. Focuses on small, scoped changes that extend existing patterns.

**Key responsibilities:**
- Implement backend code for assigned steps
- Extend existing abstractions over creating new ones
- Run local validation via backend-test-runner
- Coordinate with test-spec on test failures
- Follow git workflow for commits

---

### frontend-coder

**Frontend feature implementer. Builds and refines UI code according to UX guidance, design, and plan, coordinating with tests and reviews.**

Implements and refactors frontend code (components, pages, client-side logic) following UX guidance and architectural contracts. Maintains UI consistency with the design system.

**Key responsibilities:**
- Implement frontend code for assigned steps
- Follow established frontend stack conventions
- Apply accessibility best practices
- Coordinate with ui-ux on ambiguous behaviors
- Run local validation via frontend-test-runner

---

### test-spec

**Test designer & implementer. Defines and implements tests that validate behavior for each plan step.**

Designs and implements tests covering both backend and frontend. Defines what should be tested and how (unit, integration, E2E) without changing core production behavior.

**Key responsibilities:**
- Design test plans covering positive, negative, and edge cases
- Implement tests following repo conventions
- Run and interpret test results
- Classify failures as test issues vs implementation bugs
- Coordinate fixes with appropriate coders

---

### reviewer

**Unified reviewer for code, tests, and pull requests. Ensures alignment with design, UX, patterns, coverage, and basic security expectations.**

Expert at identifying incomplete implementations and validating claims of completion. Handles both step-level and PR-level reviews.

**Key responsibilities:**
- Validate what actually works vs what's claimed
- Analyze gaps between claimed completion and reality
- Assign severity levels to issues (Critical/High/Medium/Low)
- Collaborate with other agents on follow-ups
- Provide actionable, prioritized feedback

---

### security-researcher

**Security review specialist. Analyzes code and architecture for security risks and recommends mitigations.**

Reviews code, configuration, and architecture for security issues. Uses OWASP Top 10 and CWE entries as checklists, performs threat modeling.

**Key responsibilities:**
- Review authentication & authorization flows
- Analyze input validation and output encoding
- Check data protection and access control
- Evaluate error handling and logging
- Provide structured findings with severities

---

### documenter

**Documentation & changelog writer. Records what changed, why, and how to use or operate it.**

Captures outcomes of completed steps in documentation for future developers, operators, and users. Updates docs, READMEs, runbooks, and changelogs.

**Key responsibilities:**
- Update feature-specific documentation
- Maintain operational docs (monitoring, troubleshooting)
- Draft changelog entries
- Ensure docs reflect actual behavior
- Write for audiences who didn't participate in implementation

---

### rag

**RAG orchestrator & knowledge router. Uses code search and knowledge tools to answer scoped questions.**

Provides other agents with the right context at the right time by orchestrating retrieval tools. Other agents should not call low-level retrieval tools directly.

**Key responsibilities:**
- Orchestrate code search and navigation
- Query documentation, ADRs, and wikis
- Synthesize results into actionable summaries
- Handle ambiguity and follow-up queries
- Support context gathering for other skills

---

### ui-ux

**Frontend UX architect. Designs flows, states, and UI structure while keeping the interface consistent with the design system and best practices.**

Defines how the user experiences a feature on the frontend. Creates UX notes, wireframes, and component guidelines.

**Key responsibilities:**
- Design user flows, states, and transitions
- Define layout and hierarchy
- Specify use of the design system
- Handle UX edge cases (errors, loading, empty states)
- Guide frontend-coder on implementation patterns

---

## Commands

Commands are executable operations that can be invoked directly. They handle specific tasks like running tests or managing version control.

### /feature-autopilot

**Kick off a strict, orchestrator-driven multi-agent workflow from one or more spec files.**

The main entry point for automated feature development. Runs the complete workflow from architecture through deployment without requiring step-by-step user approval.

**Usage:**
```bash
/feature-autopilot <feature_id> @<spec_files>
```

**Workflow:**
1. Read specs and assemble context (via RAG)
2. Architecture design (architect agent)
3. Plan creation (planner agent)
4. Implementation (coder agents)
5. Tests (test-spec + coders + test-runners)
6. Security review (security-researcher)
7. Code review and documentation (reviewer + documenter)

---

### /git

**Git workflow helper. Wraps common git operations with safety guidance and coordinates with reviewer/orchestrator when preparing or reacting to changes.**

Manages branches, commits, and PRs safely and consistently. Suggests commands without executing them directly.

**Subcommands:**
- `create-branch <feature_id>` - Create feature branch after planning
- `commit <step_id>` - Commit after a step is approved
- `create-pr` - Prepare PR after all steps complete
- `handle-feedback` - Parse and route PR feedback
- `status` - Show git status and branch info
- `sync-branch` - Rebase/merge from main safely

---

### /backend-test-runner

**Backend test execution helper. Runs backend tests for a given scope and summarizes results for other agents.**

Executes backend tests and provides structured summaries for Test-Spec, Backend-Coder, Reviewer, and Planner.

**Usage:**
```bash
/backend-test-runner [scope]
```

**Scopes:** Service/module name, directory/file pattern, or `backend-all`

**Features:**
- Suggests appropriate test commands for the project
- Groups failures by likely cause
- Ensures lint and TypeScript checks are run
- Provides handoff guidance for other agents

---

### /frontend-test-runner

**Frontend test execution helper. Runs frontend tests (e.g. Vitest, Playwright) and summarizes results for other agents.**

Executes frontend tests and provides structured summaries for Test-Spec, Frontend-Coder, Reviewer, UI/UX, and Planner.

**Usage:**
```bash
/frontend-test-runner [scope]
```

**Scopes:** Page/route name, component, directory/file pattern, or `frontend-all`

**Features:**
- Supports Vitest, Jest, Playwright, and other frameworks
- Identifies visual regressions and flaky tests
- Ensures lint and TypeScript checks are run
- Suggests involving ui-ux for UX ambiguities

---

## Skills

Skills are reusable capabilities that agents can invoke. They provide structured approaches to common tasks and produce consistent output formats.

### scan-feature-context

**Given a feature/task, assemble a concise, structured context: relevant code, docs, prior work, risks, and open questions.**

Helps agents quickly understand where in the repo and docs a feature lives. Used at feature kickoff, before planning/architecture/implementation/review, or when a feature touches unknown areas.

---

### extract-requirements-from-ticket

**Turn messy tickets or specs into structured requirements, constraints, and open questions.**

Converts unstructured product input into a clean requirements baseline. Produces problem statements, must-have vs nice-to-have requirements, constraints, and open questions.

---

### propose-architecture-for-feature

**Propose backend, frontend, and data design for a feature, aligned with existing patterns.**

Drafts concrete but lightweight architecture for features. Used after requirements are extracted but before major implementation, especially when features cross boundaries or introduce new APIs/models.

---

### derive-plan-from-spec

**Turn structured requirements into a phased, dependency-aware implementation plan with clear Definition of Done.**

Generates structured, phased plans for implementing features. Includes implementation, tests, security review, review, and documentation phases.

---

### derive-test-spec-from-requirements

**Turn requirements and architecture into a concrete test plan with unit, integration, and E2E cases.**

Creates test playbooks for features. Covers unit, integration, and E2E test levels with specific test cases, inputs, and expected outcomes.

---

### review-changes-structured

**Perform a structured PR review with blocking issues, non-blocking suggestions, test gaps, and open questions.**

The core review skill that produces consistent review feedback. Outputs overall assessment, blocking issues, non-blocking suggestions, test coverage gaps, and questions.

---

### create-fix-list-from-review-feedback

**Turn structured review feedback into a prioritized list of fix tasks.**

Translates review output into actionable fix tasks for planners and coders. Groups by severity, provides ownership suggestions, and maintains priority ordering.

---

### update-plan-from-review-feedback

**Apply fix tasks to an existing plan, adjusting steps, dependencies, and priorities.**

Modifies existing plans to incorporate review-driven fixes. Adds new steps, updates dependencies, and marks steps requiring rework.

---

### summarize-diff-for-agents

**Turn raw diffs or PRs into structured summaries: modules changed, behavior, APIs, risks, and test impact.**

Provides review-ready summaries of code changes. Used before review, architecture review, or test-spec updates to assess branch/PR impact.

---

### run-quality-gates-and-triage

**Interpret logs from baseline/test/lint commands and produce a structured triage report.**

Interprets output from baseline scripts, test suites, and lint commands (does not run them). Groups failures by subsystem and suggests fix priorities.

---

### fix-lint-and-typescript-errors

**Group and explain lint/TypeScript errors, suggesting minimal, safe fixes without masking issues.**

Helps coders understand and resolve lint/TS issues safely. Groups errors by type, explains root causes, and suggests minimal fixes.

---

### sync-docs-with-implementation

**Identify documentation impacted by code changes and propose concrete updates.**

Keeps documentation aligned with implementation. Identifies impacted docs from diffs and proposes specific updates or new documentation.

---

### session-checkpoint

**Emit and resume SESSION_CHECKPOINT blocks so agents can recover work after session or context limits.**

Enables agents to save and resume progress when sessions end or context shrinks. Critical for long-running workflows that may exceed context limits.

**When to use:**
- After major chunks of work
- When `/context` or `/usage` shows approaching limits
- At session start when resuming from a checkpoint

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        /feature-autopilot                        │
│                         (Entry Point)                            │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                         orchestrator                             │
│              (Coordinates all agents & commands)                 │
└─────────────────────────────────────────────────────────────────┘
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
    ┌──────────┐        ┌──────────┐        ┌──────────┐
    │ architect │        │  ui-ux   │        │   rag    │
    │ (Design)  │◄──────►│  (UX)    │        │(Context) │
    └──────────┘        └──────────┘        └──────────┘
          │                    │
          └────────┬───────────┘
                   ▼
            ┌──────────┐
            │ planner  │
            │ (Steps)  │
            └──────────┘
                   │
     ┌─────────────┼─────────────┐
     ▼             ▼             ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ backend- │ │ frontend-│ │ test-    │
│ coder    │ │ coder    │ │ spec     │
└──────────┘ └──────────┘ └──────────┘
     │             │             │
     └─────────────┼─────────────┘
                   ▼
    ┌─────────────────────────────┐
    │    Test Runner Commands     │
    │ /backend-test-runner        │
    │ /frontend-test-runner       │
    └─────────────────────────────┘
                   │
     ┌─────────────┼─────────────┐
     ▼             ▼             ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ security-│ │ reviewer │ │documenter│
│researcher│ │          │ │          │
└──────────┘ └──────────┘ └──────────┘
```

---

## Key Files

The workflow produces and maintains these key artifacts:

| File | Owner | Purpose |
|------|-------|---------|
| `docs/features/<task_id>/ARCHITECTURE.md` | architect | System design and decisions |
| `docs/features/<task_id>/PLAN_steps.md` | planner | Execution steps and status |
| `docs/features/<task_id>/UX_NOTES.md` | ui-ux | User experience design |
| `SESSION_CHECKPOINT` blocks | all agents | Recovery state for long sessions |

---

## License

MIT

---

## Contributing

Contributions welcome! This is a playground for exploring multi-agent workflows with Claude Code.
