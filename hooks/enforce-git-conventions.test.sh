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
  # jq builds the payload so quotes and literal newlines inside the command
  # are JSON-escaped correctly (printf '%s' into a JSON template breaks on
  # any command containing a double quote — i.e. every commit message case).
  jq -cn --arg cmd "$cmd" '{"tool_input":{"command":$cmd}}' | "$HOOK"
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

# --- Commit-message extraction regressions (all three previously bounced
# valid commits: greedy last--m match, quote-of-either-kind truncation,
# line-based sed missing multiline messages; plus comma multi-scope) ---

# Baseline: simple valid and invalid subjects
expect_allowed 'git commit -m "fix(hooks): simple valid subject"'
expect_denied 'git commit -m "bad message with no type"' "conventional commits format"

# Multi -m: first message is the subject, second is free-text body —
# the old parser validated the SECOND and rejected this.
expect_allowed 'git commit -m "fix(hooks): subject line" -m "body: free text, not format-checked. plan-context.sh pairs step_id lines."'
# Multi -m with an INVALID first subject must still be denied.
expect_denied 'git commit -m "not conventional" -m "fix(hooks): valid-looking body"' "conventional commits format"

# Apostrophe inside a double-quoted subject — old parser truncated at it.
expect_allowed "git commit -m \"fix(hooks): don't truncate on apostrophes\""

# Multiline -m: only the first line (subject) is format-checked.
expect_allowed 'git commit -m "fix(hooks): multiline subject
body line two, free text"'

# Single-quoted message.
expect_allowed "git commit -m 'feat: single-quoted subject'"

# Comma-separated multi-scope — previously rejected by the scope charset.
expect_allowed 'git commit -m "fix(hooks,scripts,commands): multi-scope subject"'

# No inline message still denied.
expect_denied 'git commit' "inline message"

# --- Ordered, quote-aware token parsing (round-18 regressions) ---

# Subject CONTAINING the literal text "--message" must not be mistaken
# for the option — it is inside quotes, i.e. token content.
expect_allowed 'git commit -m "fix(hooks): handle --message option"'

# Argument order wins: an earlier -m is the subject even when a later
# --message exists (git treats them as aliases, constructed in order).
expect_allowed 'git commit -m "fix: subject first" --message "body prose, not format-checked"'
expect_denied 'git commit -m "not conventional" --message "fix: valid-looking later flag"' "conventional commits format"

# --message=value and attached -mvalue forms.
expect_allowed 'git commit --message="feat: equals form subject"'
expect_allowed "git commit -m'feat: attached single-quoted subject'"

# Combined short flags ending in m consume the next token as the message.
expect_allowed 'git commit -am "fix(scripts): combined -am flag"'
expect_denied 'git commit -am "bad combined message"' "conventional commits format"

echo "enforce-git-conventions.sh tests passed"
