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

# --- Per-invocation validation (round-22 regressions): every git commit
# in a chained command is checked, and quoted mentions are not commits. ---
expect_denied 'git add . && git commit -m "fix: valid first" && git commit -m "not conventional"' "conventional commits format"
expect_allowed 'git commit -m "fix: first" ; git commit -m "feat: second"'
expect_denied 'echo done ; git commit -m "fix: ok" ; git commit' "inline message"
expect_allowed 'echo "run git commit -m something later" && git push origin feature/foo'

# Chained commands no longer bypass ANY check (old fast path required the
# command to START with git).
expect_denied 'cd /tmp && git push --force origin feature/foo' "Force push"
expect_denied 'true && git push origin main' "main/master"
expect_denied 'echo hi ; git commit --no-verify -m "fix: x"' "no-verify"
# Quoted mentions of dangerous commands are content, not commands.
expect_allowed 'echo "git push --force origin main is forbidden"'
expect_allowed 'git commit -m "docs: explain why git push --force is blocked"'

# Quoted REAL arguments are equivalent to unquoted ones (round-24): shell
# quoting is invisible to git.
expect_denied 'git push origin "main"' "main/master"
expect_denied 'git commit "--no-verify" -m "fix: x"' "no-verify"
expect_denied 'git push "--force" origin feature/foo' "Force push"
# ...while dangerous text inside a commit MESSAGE stays plain text.
expect_allowed 'git commit -m "docs: never run git push --force or --no-verify"'

# Environment-assignment and env prefixes do not bypass validation.
expect_denied 'GIT_AUTHOR_DATE=2026-01-01 git commit -m "not conventional"' "conventional commits format"
expect_denied 'env FOO=1 git commit -m "still not conventional"' "conventional commits format"
expect_allowed 'FOO=1 git commit -m "fix(hooks): env-prefixed valid subject"'

# Combined -am messages are masked in the argument view (round-26): free
# text mentioning --no-verify must not false-deny a valid commit.
expect_allowed 'git commit -am "docs: explain --no-verify usage"'
# Quoted multi-word arguments stay single tokens (round-26): a spaced repo
# path cannot camouflage a protected-ref push.
expect_denied 'git push "/tmp/remote repo.git" main' "main/master"
expect_allowed 'git push "/tmp/remote repo.git" feature-branch'

# Shell wrappers do not bypass enforcement (round-25): subshells, brace
# groups, and command-position keywords all still execute git.
expect_denied '(git push origin main)' "main/master"
expect_denied 'if true; then git push --force origin feature/foo; fi' "Force push"
expect_denied 'command git commit -m "not conventional"' "conventional commits format"
expect_denied '{ git push origin main; }' "main/master"
expect_allowed '(git commit -m "fix: subshell valid subject")'

echo "enforce-git-conventions.sh tests passed"
