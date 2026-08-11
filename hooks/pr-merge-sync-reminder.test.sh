#!/bin/bash
# Self-contained test suite for hooks/pr-merge-sync-reminder.sh.
# Style follows hooks/enforce-git-conventions.test.sh: pipe a minimal
# tool_input JSON payload into the hook and assert on its jq output.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/pr-merge-sync-reminder.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_hook() {
  local cmd="$1"
  printf '{"tool_input":{"command":"%s"}}' "$cmd" | "$HOOK"
}

expect_reminder() {
  local cmd="$1"
  local output message

  output=$(run_hook "$cmd")
  [[ -n "$output" ]] || fail "Expected a reminder for '$cmd' but hook produced no output"

  message=$(echo "$output" | jq -r '.hookSpecificOutput.systemMessage // empty')
  echo "$message" | grep -qF "sync-claude-config.sh --apply" \
    || fail "Reminder for '$cmd' did not mention sync-claude-config.sh --apply: $message"
}

expect_silent() {
  local cmd="$1"
  local output

  output=$(run_hook "$cmd")
  [[ -z "$output" ]] || fail "Expected no output for '$cmd' but hook produced: $output"
}

# Squash merges — long and short flag, with and without --delete-branch.
expect_reminder "gh pr merge 33 --squash --delete-branch"
expect_reminder "gh pr merge 33 -s"
expect_reminder "gh pr merge --squash 33"

# Non-squash merges must stay silent.
expect_silent "gh pr merge 33 --merge"
expect_silent "gh pr merge 33 --rebase"
expect_silent "gh pr merge 33"

# Unrelated gh and git commands must stay silent.
expect_silent "gh pr view 33"
expect_silent "gh pr list --search squash"
expect_silent "git commit -m squash-fixup"

echo "pr-merge-sync-reminder.sh tests passed"
