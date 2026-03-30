#!/bin/bash
# PreToolUse hook: Enforce git workflow conventions.
# Triggered on: Bash commands matching git operations.
#
# Enforces:
# 1. Conventional commit messages (feat/fix/refactor/test/docs/chore)
# 2. Branch naming (feature/*, fix/*, refactor/*)
# 3. Block force-push
# 4. Block push to main/master directly
# 5. Block --no-verify

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- Block force push ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force|git\s+push\s+-f\b'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Force push is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
    }
  }'
  exit 0
fi

# --- Block push directly to main/master ---
if echo "$COMMAND" | grep -qE 'git\s+push\s+(origin\s+)?(main|master)\b'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Direct push to main/master is not allowed. Use a feature branch and create a PR."
    }
  }'
  exit 0
fi

# --- Block --no-verify ---
if echo "$COMMAND" | grep -qE 'git\s+(commit|push)\s+.*--no-verify'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Skipping hooks with --no-verify is not allowed. Fix the underlying issue instead."
    }
  }'
  exit 0
fi

# --- Validate conventional commit messages ---
if echo "$COMMAND" | grep -qE 'git\s+commit'; then
  # Extract commit message — try multiple formats:
  # 1. -m "message" or -m 'message'
  COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" | head -1)

  # 2. Heredoc-style: $(cat <<'EOF' ... EOF) — extract first non-blank line after EOF marker
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG=$(echo "$COMMAND" | sed -n "/<<[[:space:]]*['\"]\\{0,1\\}EOF['\"]\\{0,1\\}/,/^[[:space:]]*EOF/{/EOF/d;/^[[:space:]]*$/d;p;}" | head -1 | sed 's/^[[:space:]]*//')
  fi

  if [ -n "$COMMIT_MSG" ]; then
    # Check conventional commit format: type(scope): subject
    if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|refactor|test|docs|chore|ci|perf|build|style|revert)(\([a-zA-Z0-9_-]+\))?(!)?:\s+.+'; then
      jq -n --arg msg "$COMMIT_MSG" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Commit message does not follow conventional commits format.\nGot: \"" + $msg + "\"\nExpected: type(scope): subject\nValid types: feat, fix, refactor, test, docs, chore, ci, perf, build, style, revert")
        }
      }'
      exit 0
    fi
  fi
fi

# --- Validate branch naming on checkout -b ---
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+-b\s+'; then
  BRANCH_NAME=$(echo "$COMMAND" | grep -oP '(?<=checkout\s-b\s)\S+')
  if [ -n "$BRANCH_NAME" ]; then
    if ! echo "$BRANCH_NAME" | grep -qE '^(feature|fix|refactor|hotfix|release)/[a-zA-Z0-9_.-]+$'; then
      jq -n --arg branch "$BRANCH_NAME" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Branch name does not follow naming convention.\nGot: \"" + $branch + "\"\nExpected: feature/*, fix/*, refactor/*, hotfix/*, release/*")
        }
      }'
      exit 0
    fi
  fi
fi

# All checks passed
exit 0
