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
# Note: use POSIX character classes — macOS sed does not support \s / \S in ERE
NORMALIZED=$(echo "$COMMAND" | sed -E 's/^(git[[:space:]]+)((-[a-zA-Z]([[:space:]]+[^[:space:]]+)?|--[a-zA-Z][a-zA-Z0-9_-]*(=[^[:space:]]+)?)[[:space:]]+)*/\1/')

# --- Block force push ---
# --force overrides --force-with-lease when both are present, so block
# any command containing --force or -f (bare --force-with-lease without
# --force is allowed as the safer alternative).
# Use a two-step check: strip --force-with-lease first, then look for --force/-f,
# so that --force-with-lease alone does not trip the force detector.
HAS_FORCE=false
HAS_LEASE=false
echo "$NORMALIZED" | grep -qE '(^|\s)--force-with-lease(\s|$)' && HAS_LEASE=true
_STRIPPED_LEASE=$(echo "$NORMALIZED" | sed 's/--force-with-lease//g')
echo "$_STRIPPED_LEASE" | grep -qE 'git\s+push\s+(.*\s)?(--force(\s|=|$)|-[a-zA-Z]*f[a-zA-Z]*(\s|$))' && HAS_FORCE=true

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
# Matches any remote (not just origin), plus refspec forms like HEAD:main,
# full ref paths like refs/heads/main, and --delete/-d main.
if echo "$NORMALIZED" | grep -qE 'git\s+push\s+(-\S+\s+)*(\S+\s+)?(refs/heads/)?(main|master)(\s|$)' || \
   echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*:(refs/heads/)?(main|master)(\s|$)' || \
   echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*(-d|--delete)\s+(refs/heads/)?(main|master)(\s|$)'; then
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
# Use NORMALIZED so global options (git -C repo commit ...) don't bypass the check
if echo "$NORMALIZED" | grep -qE 'git\s+commit'; then
  # Extract commit message from the original COMMAND (which has the full args):
  # 1. -m "message" or -m 'message'
  COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*[\"']\([^\"']*\)[\"'].*/\1/p" | head -1)

  # 2. Heredoc-style: $(cat <<'EOF' ... EOF) — extract first non-blank line after EOF marker
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG=$(echo "$COMMAND" | sed -n "/<<[[:space:]]*['\"]\\{0,1\\}EOF['\"]\\{0,1\\}/,/^[[:space:]]*EOF/{/EOF/d;/^[[:space:]]*$/d;p;}" | head -1 | sed 's/^[[:space:]]*//')
  fi

  if [ -z "$COMMIT_MSG" ]; then
    # No message extractable — editor-based commit or --amend without -m.
    # Deny so the user provides an inline message we can validate.
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Commit must include an inline message (-m or heredoc) so conventional format can be validated. Use: git commit -m \"type(scope): subject\""
      }
    }'
    exit 0
  fi

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

# --- Validate branch naming on checkout -b / switch -c ---
# Use NORMALIZED so global options (git -C repo checkout -b ...) don't bypass the check
if echo "$NORMALIZED" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  BRANCH_NAME=$(echo "$NORMALIZED" | sed -En 's/.*(checkout[[:space:]]*-b|switch[[:space:]]*-c)[[:space:]]+([^[:space:]]*).*/\2/p')
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
