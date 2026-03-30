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

# Fast path: skip jq for commands that can't match safe patterns
[[ "$INPUT" == *'"npm '* || "$INPUT" == *'"npx '* || "$INPUT" == *'"git '* ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Define safe patterns (read-only or non-destructive)
SAFE_PATTERNS=(
  "npm test"
  "npm run test"
  "npm run lint"
  "npm run lint:fix"
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

# Reject commands containing shell metacharacters that could chain, pipe, or redirect.
# Regex stored in variable to avoid bash syntax errors with special chars in [[ =~ ]].
_UNSAFE_RE='&&|&|\|\||\||;|`|\$\(|<\(|>\(|>>|>|<'
if [[ "$COMMAND" == *$'\n'* ]] || [[ "$COMMAND" =~ $_UNSAFE_RE ]]; then
  exit 0  # fall through to normal permission dialog
fi

# Destructive flags that should never be auto-approved even with a safe prefix
_DESTRUCTIVE_RE='\s(-D|-d|--delete|-M|--move|--force|--hard|--config|--globalSetup|--plugin|--rulesdir|--require\s)'
if [[ "$COMMAND" =~ $_DESTRUCTIVE_RE ]]; then
  exit 0  # fall through to normal permission dialog
fi

for pattern in "${SAFE_PATTERNS[@]}"; do
  # Exact match OR safe pattern followed only by flags/args
  if [[ "$COMMAND" == "$pattern" ]] || [[ "$COMMAND" == "$pattern "* ]]; then
    echo '{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}'
    exit 0
  fi
done

# Not a safe pattern — fall through to normal permission dialog
exit 0
