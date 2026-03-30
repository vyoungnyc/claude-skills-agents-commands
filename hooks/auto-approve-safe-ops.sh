#!/bin/bash
# PermissionRequest hook: Auto-approve known-safe operations.
# Triggered on: Bash commands matching safe patterns.
#
# Auto-approves: npm test, npm run lint, npx jest, npx prettier,
# npx eslint, npx tsc, npx vitest, npx playwright, git status,
# git diff, git log, git branch.
#
# Everything else goes through normal permission flow.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Define safe patterns (read-only or non-destructive)
SAFE_PATTERNS=(
  "npm test"
  "npm run test"
  "npm run lint"
  "npm run lint:fix"
  "npm run build"
  "npm run dev"
  "npx jest"
  "npx vitest"
  "npx playwright test"
  "npx prettier"
  "npx eslint"
  "npx tsc --noEmit"
  "npx tsc -p"
  "git status"
  "git diff"
  "git log"
  "git branch"
  "git show"
  "git stash list"
)

for pattern in "${SAFE_PATTERNS[@]}"; do
  if [[ "$COMMAND" == "$pattern"* ]]; then
    echo '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}'
    exit 0
  fi
done

# Not a safe pattern — fall through to normal permission dialog
exit 0
