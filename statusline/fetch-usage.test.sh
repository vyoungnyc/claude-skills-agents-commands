#!/bin/bash
# Self-contained test suite for statusline/fetch-usage.sh.
# Style follows scripts/sync-claude-config.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# fetch-usage.sh hardcodes $HOME/.claude/.credentials.json, shells out to
# `curl` and (as a fallback) the macOS `security` CLI, and calls `sleep`
# between retries. Isolation here means `env HOME=... PATH=<stubdir>:...`
# with all three stubbed — no real network call, no real Keychain prompt,
# and no real waiting. The stubbed `security` always fails fast so this
# suite can never trigger a real macOS Keychain access dialog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/fetch-usage.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
SUITE_TMP=$(cd "$SUITE_TMP" && pwd -P)
trap 'rm -rf "$SUITE_TMP"' EXIT

fake_home_with_token() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  mkdir -p "$dir/.claude"
  jq -n '{claudeAiOauth: {accessToken: "fake-token-123"}}' > "$dir/.claude/.credentials.json"
  printf '%s' "$dir"
}

fake_home_no_token() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  mkdir -p "$dir/.claude"
  printf '%s' "$dir"
}

# fake_bindir <state_dir> — a PATH directory with:
#   - `security`: always fails fast (never a real Keychain prompt).
#   - `sleep`: a no-op that logs each invocation to <state_dir>/slept
#     instead of actually waiting.
#   - `curl`: driven by <state_dir>/plan, one line per expected call:
#     "<http_status>:<retry_after_or_empty>:<body>". Each call consumes the
#     next line (repeating the last line once the plan is exhausted),
#     writes any Retry-After to the -D headerfile, and echoes
#     "<body>\n__HTTP_STATUS__<status>\n" the same way real curl's -w would
#     append the status after the body. Every call is counted in
#     <state_dir>/calls (one line appended per invocation).
fake_bindir() {
  local state="$1" dir
  dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  : > "$state/calls"

  cat > "$dir/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  cat > "$dir/sleep" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$state/slept"
exit 0
EOF

  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
STATE="$state"
headerfile=""
stdin_headers=0
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [ "\${args[i]}" = "-D" ]; then
    headerfile="\${args[i+1]}"
  fi
  # \`-H @-\` means real curl reads header lines from stdin; mirror that so the
  # suite can assert WHERE the bearer token travelled (stdin, not argv).
  if [ "\${args[i]}" = "-H" ] && [ "\${args[i+1]}" = "@-" ]; then
    stdin_headers=1
  fi
done
n=\$(( \$(wc -l < "\$STATE/calls" 2>/dev/null || echo 0) + 1 ))
echo "\$n" >> "\$STATE/calls"
# Record argv and (when -H @- was passed) stdin, separately, per call.
printf '%s\0' "\${args[@]}" > "\$STATE/argv.\$n"
if [ "\$stdin_headers" -eq 1 ]; then
  cat > "\$STATE/stdin.\$n"
else
  : > "\$STATE/stdin.\$n"
fi
plan_line=\$(sed -n "\${n}p" "\$STATE/plan")
[ -n "\$plan_line" ] || plan_line=\$(tail -1 "\$STATE/plan")
status=\$(printf '%s' "\$plan_line" | cut -d: -f1)
retry=\$(printf '%s' "\$plan_line" | cut -d: -f2)
body=\$(printf '%s' "\$plan_line" | cut -d: -f3-)
if [ -n "\$headerfile" ]; then
  if [ -n "\$retry" ]; then
    printf 'Retry-After: %s\r\n' "\$retry" > "\$headerfile"
  else
    : > "\$headerfile"
  fi
fi
printf '%s\n__HTTP_STATUS__%s\n' "\$body" "\$status"
EOF
  chmod +x "$dir/security" "$dir/sleep" "$dir/curl"
  printf '%s' "$dir"
}

call_count() { wc -l < "$1/calls" | tr -d ' '; }

# =======================================================================
# No credentials file and no usable Keychain: exits 1 with a clear error,
# never touches the network.
# =======================================================================
NOTOKEN_HOME=$(fake_home_no_token)
NOTOKEN_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '200::ok\n' > "$NOTOKEN_STATE/plan"
STUBDIR=$(fake_bindir "$NOTOKEN_STATE")
set +e
OUT=$(env HOME="$NOTOKEN_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" 2>&1)
EXIT=$?
set -e
[ "$EXIT" -eq 1 ] || fail "missing token should exit 1, got $EXIT"
printf '%s' "$OUT" | grep -q "no OAuth token found" || fail "expected a clear no-token error, got: $OUT"
[ ! -s "$NOTOKEN_STATE/calls" ] || fail "no-token path must never call curl"

# =======================================================================
# Credentials file exists and is valid JSON, but has none of the recognized
# token fields: must fall through to the Keychain, not report "no token
# found" (jq exits 0 on a valid-but-fieldless file, which used to short-
# circuit the `&&  return 0` before the Keychain fallback ever ran).
# =======================================================================
EMPTYCREDS_HOME=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
mkdir -p "$EMPTYCREDS_HOME/.claude"
echo '{}' > "$EMPTYCREDS_HOME/.claude/.credentials.json"
EMPTYCREDS_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '200::from-keychain\n' > "$EMPTYCREDS_STATE/plan"
STUBDIR=$(fake_bindir "$EMPTYCREDS_STATE")
cat > "$STUBDIR/security" <<'EOF'
#!/usr/bin/env bash
echo '{"claudeAiOauth":{"accessToken":"keychain-token-456"}}'
EOF
chmod +x "$STUBDIR/security"
OUT=$(env HOME="$EMPTYCREDS_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "an empty-but-valid credentials file should still fall through to the Keychain, got: $OUT"
printf '%s' "$OUT" | grep -q 'from-keychain' || fail "expected the Keychain-sourced token to reach curl successfully"

# =======================================================================
# Immediate 200: body + __HTTP_STATUS__200 emitted, exactly one curl call.
# =======================================================================
OK_HOME=$(fake_home_with_token)
OK_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '200::{"hello":"world"}\n' > "$OK_STATE/plan"
STUBDIR=$(fake_bindir "$OK_STATE")
OUT=$(env HOME="$OK_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "expected a 200 status trailer, got: $OUT"
printf '%s' "$OUT" | grep -q '{"hello":"world"}' || fail "expected the response body in the output, got: $OUT"
[ "$(call_count "$OK_STATE")" -eq 1 ] || fail "a first-try 200 should make exactly one curl call"
[ ! -s "$OK_STATE/slept" ] || fail "a first-try 200 should never sleep"

# =======================================================================
# 429 with Retry-After, then 200: retried once, honoring the header value,
# and sleep is invoked (no real wait, since sleep is stubbed).
# =======================================================================
RETRY_HOME=$(fake_home_with_token)
RETRY_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '429:7:{"error":"throttled"}\n200::{"ok":true}\n' > "$RETRY_STATE/plan"
STUBDIR=$(fake_bindir "$RETRY_STATE")
OUT=$(env HOME="$RETRY_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "expected the retry to eventually surface a 200, got: $OUT"
[ "$(call_count "$RETRY_STATE")" -eq 2 ] || fail "expected exactly 2 curl calls (1 throttled + 1 success)"
[ -s "$RETRY_STATE/slept" ] || fail "a 429 should sleep before retrying"
grep -q '^7$' "$RETRY_STATE/slept" || fail "expected the Retry-After value (7) to be honored, got: $(cat "$RETRY_STATE/slept")"

# =======================================================================
# 429 with no Retry-After header: still retries (falls back to attempt*2,
# capped at 30), without a Retry-After value to key off of.
# =======================================================================
NORETRY_HOME=$(fake_home_with_token)
NORETRY_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '429::{"error":"throttled"}\n200::{"ok":true}\n' > "$NORETRY_STATE/plan"
STUBDIR=$(fake_bindir "$NORETRY_STATE")
OUT=$(env HOME="$NORETRY_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "expected eventual 200 without a Retry-After header"
[ -s "$NORETRY_STATE/slept" ] || fail "a 429 without Retry-After should still sleep (attempt*2 fallback)"

# =======================================================================
# 5xx is retried the same way as 429.
# =======================================================================
FIVEXX_HOME=$(fake_home_with_token)
FIVEXX_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '503::{"error":"unavailable"}\n200::{"ok":true}\n' > "$FIVEXX_STATE/plan"
STUBDIR=$(fake_bindir "$FIVEXX_STATE")
OUT=$(env HOME="$FIVEXX_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "expected eventual 200 after a 503"
[ "$(call_count "$FIVEXX_STATE")" -eq 2 ] || fail "expected exactly 2 curl calls (1x 503 + 1 success)"

# =======================================================================
# Retries are capped at 3 attempts total: persistent 429s stop retrying
# after the 3rd call and surface the last (still-429) response.
# =======================================================================
MAXOUT_HOME=$(fake_home_with_token)
MAXOUT_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '429::{"error":"throttled"}\n' > "$MAXOUT_STATE/plan"
STUBDIR=$(fake_bindir "$MAXOUT_STATE")
OUT=$(env HOME="$MAXOUT_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__429' || fail "expected the final (still-429) response to be surfaced after exhausting retries"
[ "$(call_count "$MAXOUT_STATE")" -eq 3 ] || fail "expected exactly 3 curl calls (max retry attempts), got $(call_count "$MAXOUT_STATE")"

# =======================================================================
# SECURITY regression: the bearer token must never appear in curl's argv --
# a process command line is readable by other users (ps, /proc/<pid>/
# cmdline) and by monitoring agents, so a token there is exposed for the
# lifetime of every request. It must travel on stdin via `-H @-` instead.
# Asserted on BOTH sides so the test cannot pass by the header silently
# not being sent at all: absent from argv AND present on stdin.
# =======================================================================
ARGV_HOME=$(fake_home_with_token)   # accessToken: fake-token-123
ARGV_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '200::{"ok":true}\n' > "$ARGV_STATE/plan"
STUBDIR=$(fake_bindir "$ARGV_STATE")
OUT=$(env HOME="$ARGV_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
printf '%s' "$OUT" | grep -q '__HTTP_STATUS__200' || fail "argv test setup: expected a successful call, got: $OUT"
# argv is NUL-separated; translate for grepping.
ARGV_TEXT=$(tr '\0' '\n' < "$ARGV_STATE/argv.1")
printf '%s' "$ARGV_TEXT" | grep -q 'fake-token-123' \
  && fail "the bearer token appeared in curl's argv -- it is exposed to other users on the host via ps//proc"
printf '%s' "$ARGV_TEXT" | grep -qx -- '-H' \
  || fail "argv test setup: expected -H flags in the recorded argv"
printf '%s' "$ARGV_TEXT" | grep -qx -- '@-' \
  || fail "expected curl to be told to read the auth header from stdin (-H @-)"
# ...and the token really is sent, on stdin.
grep -q '^Authorization: Bearer fake-token-123$' "$ARGV_STATE/stdin.1" \
  || fail "the Authorization header must still reach curl on stdin, got: $(cat "$ARGV_STATE/stdin.1")"
# Non-secret headers stay on the command line where they document the request.
printf '%s' "$ARGV_TEXT" | grep -q 'anthropic-beta: oauth-2025-04-20' \
  || fail "non-secret headers should remain in argv"

# Every retry attempt must also keep the token off argv, not just the first.
RETRYARGV_HOME=$(fake_home_with_token)
RETRYARGV_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '429::{"error":"throttled"}\n200::{"ok":true}\n' > "$RETRYARGV_STATE/plan"
STUBDIR=$(fake_bindir "$RETRYARGV_STATE")
OUT=$(env HOME="$RETRYARGV_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT")
[ "$(call_count "$RETRYARGV_STATE")" -eq 2 ] || fail "retry-argv test setup: expected 2 calls"
for n in 1 2; do
  tr '\0' '\n' < "$RETRYARGV_STATE/argv.$n" | grep -q 'fake-token-123' \
    && fail "the bearer token appeared in curl's argv on attempt $n"
  grep -q '^Authorization: Bearer fake-token-123$' "$RETRYARGV_STATE/stdin.$n" \
    || fail "attempt $n did not receive the auth header on stdin"
done

# =======================================================================
# The response-header temp file must not be a predictable /tmp path (a
# world-writable directory + a guessable PID-derived name is a symlink-
# clobber target), and must not be left behind after the run.
# =======================================================================
HDR_HOME=$(fake_home_with_token)
HDR_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '200::{"ok":true}\n' > "$HDR_STATE/plan"
STUBDIR=$(fake_bindir "$HDR_STATE")
env HOME="$HDR_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" >/dev/null
HDR_ARG=$(tr '\0' '\n' < "$HDR_STATE/argv.1" | grep -A1 -x -- '-D' | tail -1)
printf '%s' "$HDR_ARG" | grep -q '\.usage-hdrs\.[0-9]*$' \
  && fail "the header file is still a predictable PID-derived /tmp path: $HDR_ARG"
[ -n "$HDR_ARG" ] || fail "expected a -D header file argument in curl's argv"
[ ! -e "$HDR_ARG" ] || fail "the response-header temp file was left behind after the run: $HDR_ARG"

# Left behind even when retries are exhausted (the old cleanup only ran on
# the success path, so a give-up or a signal leaked the file).
EXHAUST_HOME=$(fake_home_with_token)
EXHAUST_STATE=$(mktemp -d "$SUITE_TMP/state.XXXXXX")
printf '429::{"error":"throttled"}\n' > "$EXHAUST_STATE/plan"
STUBDIR=$(fake_bindir "$EXHAUST_STATE")
env HOME="$EXHAUST_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" >/dev/null
EXHAUST_HDR=$(tr '\0' '\n' < "$EXHAUST_STATE/argv.1" | grep -A1 -x -- '-D' | tail -1)
[ ! -e "$EXHAUST_HDR" ] || fail "the header temp file leaked after retries were exhausted: $EXHAUST_HDR"

echo "fetch-usage.test.sh: all assertions passed"
