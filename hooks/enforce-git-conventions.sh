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

# Normalize: strip git global options so enforcement matches the subcommand.
# Handles: -c key=val, --no-pager, --git-dir=path, -C path, -p, etc.
# After stripping, NORMALIZED starts with "git <subcommand> ..."
NORMALIZED=$(echo "$COMMAND" | sed -E 's/^(git\s+)((-[a-zA-Z](\s+\S+)?|--[a-zA-Z][a-zA-Z0-9_-]*(=\S+)?)\s+)*/\1/')

# --- Block force push ---
# --force overrides --force-with-lease when both are present, so block
# any command containing --force or -f (bare --force-with-lease without
# --force is allowed as the safer alternative).
HAS_FORCE=false
HAS_LEASE=false
echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*(--force\b|-f\b)' && HAS_FORCE=true
echo "$NORMALIZED" | grep -qE '\-\-force-with-lease' && HAS_LEASE=true

if $HAS_FORCE; then
  if $HAS_LEASE; then
    REASON="Cannot combine --force with --force-with-lease: --force overrides the lease safety. Use --force-with-lease alone."
  else
    REASON="Force push is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
  fi
  jq -n --arg reason "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# --- Block push directly to main/master ---
# Matches any remote (not just origin), plus refspec forms like HEAD:main
if echo "$NORMALIZED" | grep -qE 'git\s+push\s+(\S+\s+)?(main|master)\b' || \
   echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*:(main|master)\b'; then
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
if echo "$NORMALIZED" | grep -qE 'git\s+(commit|push)\s+.*--no-verify'; then
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

# --- Validate branch naming on checkout -b / switch -c ---
if echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  BRANCH_NAME=$(echo "$COMMAND" | sed -n 's/.*\(checkout[[:space:]]*-b\|switch[[:space:]]*-c\)[[:space:]]*\([^[:space:]]*\).*/\2/p')
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
