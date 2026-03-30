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

# Fast path: skip jq parsing entirely for non-git commands
[[ "$INPUT" == *'"git '* ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Normalize: strip git global options so enforcement matches the subcommand.
# Handles: -c key=val, --no-pager, --git-dir=path, -C path, -p, etc.
# After stripping, NORMALIZED starts with "git <subcommand> ..."
# Note: use POSIX character classes — macOS sed does not support \s / \S in ERE
#
# Global flags that take a mandatory argument (consume next token):
#   -C <path>, -c <key=val>, --git-dir <path>, --work-tree <path>,
#   --namespace <name>, --super-prefix <path>, --config-env <name=envvar>
# Global flags that are standalone (do NOT consume next token):
#   -p/--paginate, -P/--no-pager, --no-replace-objects, --bare,
#   --literal-pathspecs, --glob-pathspecs, --noglob-pathspecs,
#   --no-optional-locks, --no-lazy-fetch, --html-path, --man-path, --info-path
NORMALIZED="$COMMAND"
# Iteratively strip global options from the front (after "git ")
while true; do
  PREV="$NORMALIZED"
  # Strip flags that take a mandatory argument: -C, -c, --git-dir, --work-tree, --namespace, --super-prefix, --config-env
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)(-[Cc]|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)[[:space:]]+[^[:space:]]+[[:space:]]+/\1/')
  # Strip standalone flags: -p, -P, --paginate, --no-pager, --bare, --no-replace-objects, etc.
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)(-[pP]|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--no-optional-locks|--no-lazy-fetch|--html-path|--man-path|--info-path)[[:space:]]+/\1/')
  # Strip long options with = value (e.g. --git-dir=/foo)
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)--[a-zA-Z][a-zA-Z0-9_-]*=[^[:space:]]+[[:space:]]+/\1/')
  [ "$NORMALIZED" = "$PREV" ] && break
done

# --- Push-specific checks (skip for non-push commands) ---
if echo "$NORMALIZED" | grep -qE 'git\s+push(\s|$)'; then

  # Block force push
  HAS_FORCE=false
  HAS_FORCE_FLAG=false
  HAS_PLUS_REFSPEC=false
  HAS_LEASE=false
  echo "$NORMALIZED" | grep -qE '(^|[[:space:]])--force-with-lease([=[:space:]]|$)' && HAS_LEASE=true
  _STRIPPED_LEASE=$(echo "$NORMALIZED" | sed -E 's/--force-with-lease(=[^[:space:]]+)?//g')
  echo "$_STRIPPED_LEASE" | grep -qE 'git\s+push\s+(.*\s)?(--force(\s|=|$)|-[a-zA-Z]*f[a-zA-Z]*(\s|$))' && { HAS_FORCE=true; HAS_FORCE_FLAG=true; }

  # Detect + refspec prefix (per-ref force push)
  _PUSH_ARGS=$(echo "$NORMALIZED" | sed -E 's/^git[[:space:]]+push[[:space:]]*//')
  if echo "$_PUSH_ARGS" | grep -qE '(^|[[:space:]])\+[^[:space:]]+'; then
    HAS_FORCE=true
    HAS_PLUS_REFSPEC=true
  fi

  if $HAS_FORCE; then
    if $HAS_FORCE_FLAG && $HAS_LEASE; then
      REASON="Cannot combine --force with --force-with-lease: --force overrides the lease safety. Use --force-with-lease alone."
    elif $HAS_PLUS_REFSPEC; then
      if $HAS_LEASE; then
        REASON="Force push via + refspec prefix overrides --force-with-lease safety. Remove the + prefix and rely on --force-with-lease instead."
      else
        REASON="Force push via + refspec prefix is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
      fi
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

  # Block push to main/master (including refspecs, --delete, --all, --mirror)
  if echo "$NORMALIZED" | grep -qE 'git\s+push\s+(-\S+\s+)*(\S+\s+)?(refs/heads/)?(main|master)(\s|$)' || \
     echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*:(refs/heads/)?(main|master)(\s|$)' || \
     echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*(-d|--delete)\s+(refs/heads/)?(main|master)(\s|$)' || \
     echo "$NORMALIZED" | grep -qE 'git\s+push\s+.*\s(--all|--mirror)(\s|$)'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Direct push to main/master is not allowed (including --all/--mirror which can update protected branches). Use a feature branch and create a PR."
      }
    }'
    exit 0
  fi

fi

# --- Block --no-verify / -n (commit/push) ---
if echo "$NORMALIZED" | grep -qE 'git\s+(commit|push)(\s|$)'; then
  # --no-verify: check full command (long form can't appear unquoted inside -m "...")
  # -n shorthand: only check options before -m to avoid false positives in message text
  # Note: -n means --no-verify for commit, --dry-run for push — only check commit
  OPTS_BEFORE_MSG=$(echo "$NORMALIZED" | sed -E 's/(-m|--message)[[:space:]]+.*//')
  if echo "$NORMALIZED" | grep -qE 'git\s+(commit|push)\s+.*--no-verify' || \
     echo "$OPTS_BEFORE_MSG" | grep -qE 'git\s+commit\s+.*\s-[a-zA-Z]*n[a-zA-Z]*(\s|$)'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Skipping hooks with --no-verify is not allowed. Fix the underlying issue instead."
      }
    }'
    exit 0
  fi
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
