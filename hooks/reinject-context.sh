#!/bin/bash
# PostCompact hook: re-inject critical context after context compaction.
# Replaces the manual session-checkpoint skill from v1.
#
# This runs automatically whenever Claude Code compacts the context window.
# It ensures critical project standards survive compaction.

cat <<'CONTEXT'
## Post-compaction reminders

### Project standards
- TypeScript strict mode, two-space indentation
- Conventional commits required (feat/fix/refactor/test/docs/chore)
- All code must pass Jest + Playwright tests before merge
- Never commit secrets or credentials

### Workflow
- All structural changes require plan approval via PLAN_steps.md
- Only architect, ui-ux, and planner may ask the user clarifying questions
- Orchestrator never writes code — always delegate to the appropriate agent
- For parallel work: use subagents (default) or agent teams (when file domains are separable)
- Agent teams require non-overlapping file domains — no worktree isolation in teams

### Context hierarchy
- CLAUDE.md → project standards
- docs/features/<task_id>/ARCHITECTURE.md → feature design
- docs/features/<task_id>/PLAN_steps.md → step tracking
- docs/features/<task_id>/UX_NOTES.md → UX decisions

### Active task
Check PLAN_steps.md for current task_id and step status.
CONTEXT
