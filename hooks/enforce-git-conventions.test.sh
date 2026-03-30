#!/bin/bash
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/enforce-git-conventions.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_hook() {
  local cmd="$1"
  printf '{"tool_input":{"command":"%s"}}' "$cmd" | "$HOOK"
}

expect_denied() {
  local cmd="$1"
  local reason_pattern="$2"
  local output decision reason

  output=$(run_hook "$cmd")
  [[ -n "$output" ]] || fail "Expected denial for '$cmd' but hook allowed it"

  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  [[ "$decision" == "deny" ]] || fail "Expected 'deny' decision for '$cmd', got '$decision'"

  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  echo "$reason" | grep -Eq "$reason_pattern" || fail "Reason for '$cmd' did not match /$reason_pattern/: $reason"
}

expect_allowed() {
  local cmd="$1"
  local output

  output=$(run_hook "$cmd")
  [[ -z "$output" ]] || fail "Expected allow for '$cmd' but hook responded: $output"
}

expect_denied "git push origin +HEAD:feature/foo" "\\+ refspec prefix"
expect_denied "git push --force-with-lease origin +HEAD:feature/foo" "overrides --force-with-lease safety"
expect_allowed "git push --force-with-lease origin feature/foo"
expect_allowed "git push origin feature/foo"

echo "enforce-git-conventions.sh tests passed"
