#!/bin/bash
# Self-contained test suite for poll-pr-reviews.sh.
#
# Stubs `gh` on PATH with a per-call-count fixture dispatcher (no network).
# Every invocation uses poll_interval_sec=1 and max_polls<=4, so the whole
# suite's sleeping is bounded to a few seconds. Owner/repo/PR identifiers are
# derived from $$ so pidfiles never collide with a real polling run or a
# parallel test run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/poll-pr-reviews.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP="$(mktemp -d)"
STUB_BIN="$SUITE_TMP/bin"
mkdir -p "$STUB_BIN"

# Suite-owned TMPDIR, independent of whatever the invoking environment has
# (or doesn't have) set. Without this, an expected-pidfile-path assertion
# computed from ${TMPDIR:-/tmp} would pass by coincidence whenever TMPDIR
# happens to be unset in the ambient environment — a mutant that hardcoded
# /tmp in the script under test would still pass here too. Pinning TMPDIR to
# a suite-owned directory makes the assertion meaningful regardless of the
# invoking shell's environment.
export TMPDIR="$SUITE_TMP/tmp"
mkdir -p "$TMPDIR"

# Stub `gh` — dispatches purely on call order (a counter file in $GH_STUB_DIR),
# never on the query text, per ARCHITECTURE.md's stubbing-seams table. Serves
# "$GH_STUB_DIR/<call_number>.json"; if that exact file is absent, falls back
# to the highest-numbered fixture at or below the current call (so a fixture
# can be "held" across repeated polls, e.g. idle timeout / blocked-on-human).
cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/bin/bash
DIR="${GH_STUB_DIR:?GH_STUB_DIR not set}"
COUNTER_FILE="$DIR/.call_count"
count=0
[ -f "$COUNTER_FILE" ] && count=$(cat "$COUNTER_FILE")
count=$((count + 1))
echo "$count" > "$COUNTER_FILE"
echo "$*" >> "$DIR/.calls.log"

f=""
n="$count"
while [ "$n" -ge 1 ]; do
  if [ -f "$DIR/$n.json" ]; then
    f="$DIR/$n.json"
    break
  fi
  n=$((n - 1))
done

if [ -n "$f" ]; then
  cat "$f"
else
  printf ''
fi
STUBEOF
chmod +x "$STUB_BIN/gh"

# Cleanup: pidfiles live under ${TMPDIR:-/tmp}/poll-$(id -u)/ (per the script
# under test), which is now itself inside SUITE_TMP since TMPDIR is
# suite-owned above; removing SUITE_TMP cleans up everything.
cleanup_suite() {
  rm -rf "$SUITE_TMP"
}
trap cleanup_suite EXIT

# new_case / new_pr are called directly (never via command substitution) so
# their CASE_N/PR_N increments mutate this script's own variables rather than
# a throwaway subshell's copy. Each sets CASE_DIR / PR as a side effect.
CASE_N=0
CASE_DIR=""
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$SUITE_TMP/case_$CASE_N"
  mkdir -p "$CASE_DIR"
}

# Runs poll-pr-reviews.sh with a fresh stub PATH and the given fixture dir.
# Sets RC, OUT (stdout), ERR (stderr contents) as globals.
run_pr() {
  local fixture_dir="$1"; shift
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  set +e
  GH_STUB_DIR="$fixture_dir" PATH="$STUB_BIN:$PATH" "$SCRIPT" "$@" >"$out_file" 2>"$err_file"
  RC=$?
  set -e
  OUT="$(cat "$out_file")"
  ERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"
}

expect_exit() {
  local expected="$1" desc="$2"
  [ "$RC" -eq "$expected" ] || fail "$desc: expected exit $expected, got $RC (stdout=$OUT stderr=$ERR)"
}

expect_json_field() {
  local jq_filter="$1" expected="$2" desc="$3"
  local actual
  actual=$(echo "$OUT" | jq -r "$jq_filter") || fail "$desc: stdout did not parse as JSON: $OUT"
  [ "$actual" = "$expected" ] || fail "$desc: jq '$jq_filter' expected '$expected', got '$actual'"
}

expect_stderr_match() {
  local pattern="$1" desc="$2"
  echo "$ERR" | grep -Eq "$pattern" || fail "$desc: stderr did not match /$pattern/: $ERR"
}

expect_stderr_no_match() {
  local pattern="$1" desc="$2"
  if echo "$ERR" | grep -Eiq "$pattern"; then
    fail "$desc: stderr unexpectedly matched /$pattern/ (trap noise?): $ERR"
  fi
}

# Unique synthetic identifiers per case, derived from $$, so pidfiles never
# collide with a real run or another parallel test-suite invocation.
OWNER_BASE="synth$$"
PR_N=1000
PR=""
new_pr() {
  PR_N=$((PR_N + 1))
  PR="$PR_N"
}

pidfile_for() {
  local owner="$1" name="$2" pr="$3"
  echo "${TMPDIR:-/tmp}/poll-$(id -u)/poll-pr-reviews-${owner}-${name}-${pr}.pid"
}

EXERCISED_CODES=""
mark_exercised() {
  case " $EXERCISED_CODES " in
    *" $1 "*) ;;
    *) EXERCISED_CODES="$EXERCISED_CODES $1" ;;
  esac
}

# --- Fixture builders -------------------------------------------------------

fixture_empty_snapshot() {
  cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
JSON
}

fixture_snapshot_with_thread() {
  local tid="$1"
  cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"$tid","isResolved":false}]}}}}}
JSON
}

fixture_poll_empty() {
  cat <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reactions":{"nodes":[]}}}}}
JSON
}

fixture_poll_approval() {
  local login="$1" content="${2:-THUMBS_UP}"
  cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]},"reactions":{"nodes":[{"content":"$content","user":{"login":"$login"}}]}}}}}
JSON
}

fixture_poll_thread_only() {
  local tid="$1"
  cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"$tid","isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"placeholder","author":{"login":"alice"},"path":"a.txt","line":1,"createdAt":"2026-01-01T00:00:00Z"}]}}]},"reactions":{"nodes":[]}}}}}
JSON
}

fixture_poll_two_threads() {
  local old_id="$1" new_id="$2"
  cat <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"$old_id","isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"old thread","author":{"login":"alice"},"path":"a.txt","line":1,"createdAt":"2026-01-01T00:00:00Z"}]}},{"id":"$new_id","isResolved":false,"comments":{"nodes":[{"databaseId":2,"body":"new thread body","author":{"login":"bob"},"path":"b.txt","line":42,"createdAt":"2026-01-02T00:00:00Z"}]}}]},"reactions":{"nodes":[]}}}}}
JSON
}

fixture_error_object() {
  cat <<'JSON'
{"errors":[{"message":"forbidden"}]}
JSON
}

# =============================================================================
# Exit 0 (APPROVED)
# =============================================================================

# [bot]-suffixed login
new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoA" "$PR" 1 4
expect_exit 0 "APPROVED via [bot]-suffixed login"
expect_json_field '.status' "APPROVED" "APPROVED [bot] status"
expect_json_field '.poll' "1" "APPROVED [bot] poll number"
echo "$OUT" | jq -e '.approvers | length > 0' >/dev/null || fail "APPROVED [bot]: approvers should be non-empty"
mark_exercised 0

# cursor-bugbot login
new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "cursor-bugbot" "WHITE_CHECK_MARK" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoA" "$PR" 1 4
expect_exit 0 "APPROVED via cursor-bugbot"
expect_json_field '.status' "APPROVED" "APPROVED cursor-bugbot status"
expect_json_field '.poll' "1" "APPROVED cursor-bugbot poll number"
echo "$OUT" | jq -e '.approvers | length > 0' >/dev/null || fail "APPROVED cursor-bugbot: approvers should be non-empty"

# renovate-bot login — BASE_BOT_PATTERNS' `-bot$` anchor (narrowed from the
# unanchored `-bot-` during round-1 security remediation) must still match a
# login that genuinely ends in "-bot".
new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "renovate-bot" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoA" "$PR" 1 4
expect_exit 0 "APPROVED via renovate-bot (-bot\$ anchor)"
expect_json_field '.status' "APPROVED" "APPROVED renovate-bot status"
echo "$OUT" | jq -e '.approvers | length > 0' >/dev/null || fail "APPROVED renovate-bot: approvers should be non-empty"

# Negative control — the whole point of the `-bot-` -> `-bot$` narrowing.
# "mallory-bot-reviewer" contains "-bot-" but does not END in "-bot", so it
# must NOT satisfy the bot-approval gate: a THUMBS_UP from this login must
# never produce exit 0. This is the regression test that guards the
# auth-bypass vector the round-1 fix closed (an attacker-controlled login
# containing "-bot-" anywhere used to be treated as a trusted bot reviewer).
new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "mallory-bot-reviewer" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoBotNeg" "$PR" 1 4
[ "$RC" -ne 0 ] || fail "bot pattern negative control: mallory-bot-reviewer must NOT satisfy the bot-approval gate, but got exit 0"
expect_exit 2 "bot pattern negative control: run reaches IDLE_TIMEOUT instead of APPROVED"
expect_json_field '.status' "IDLE_TIMEOUT" "bot pattern negative control status"

# =============================================================================
# Exit 1 (NEW_COMMENTS)
# =============================================================================

new_case; new_pr
OLD_ID="thread-old-$PR"
NEW_ID="thread-new-$PR"
fixture_snapshot_with_thread "$OLD_ID" > "$CASE_DIR/1.json"
fixture_poll_thread_only "$OLD_ID" > "$CASE_DIR/2.json"
fixture_poll_two_threads "$OLD_ID" "$NEW_ID" > "$CASE_DIR/3.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoB" "$PR" 1 4
expect_exit 1 "NEW_COMMENTS"
expect_json_field '.status' "NEW_COMMENTS" "NEW_COMMENTS status"
expect_json_field '.count' "1" "NEW_COMMENTS count"
expect_json_field '.poll' "2" "NEW_COMMENTS poll number"
echo "$OUT" | jq -e '.threads | length == 1' >/dev/null || fail "NEW_COMMENTS: expected exactly one thread"
expect_json_field '.threads[0].id' "$NEW_ID" "NEW_COMMENTS thread id is the NEW thread"
expect_json_field '.threads[0].author' "bob" "NEW_COMMENTS thread author"
expect_json_field '.threads[0].path' "b.txt" "NEW_COMMENTS thread path"
expect_json_field '.threads[0].line' "42" "NEW_COMMENTS thread line"
expect_json_field '.threads[0].body' "new thread body" "NEW_COMMENTS thread body"
expect_json_field '.threads[0].created' "2026-01-02T00:00:00Z" "NEW_COMMENTS thread created"
mark_exercised 1

# =============================================================================
# Exit 2 (IDLE_TIMEOUT)
# =============================================================================

new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_empty > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoC" "$PR" 1 4
expect_exit 2 "IDLE_TIMEOUT"
expect_json_field '.status' "IDLE_TIMEOUT" "IDLE_TIMEOUT status"
expect_json_field '.polls_completed' "4" "IDLE_TIMEOUT polls_completed == max_polls"
expect_json_field '.total_seconds' "4" "IDLE_TIMEOUT total_seconds == max_polls * poll_interval"
mark_exercised 2

# =============================================================================
# Exit 3 (BLOCKED_ON_HUMAN) — fires exactly at BLOCKED_THRESHOLD (3), not earlier
# =============================================================================

new_case; new_pr
STALE_ID="thread-stale-$PR"
fixture_snapshot_with_thread "$STALE_ID" > "$CASE_DIR/1.json"
fixture_poll_thread_only "$STALE_ID" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoD" "$PR" 1 4
expect_exit 3 "BLOCKED_ON_HUMAN"
expect_json_field '.status' "BLOCKED_ON_HUMAN" "BLOCKED_ON_HUMAN status"
expect_json_field '.poll' "3" "BLOCKED_ON_HUMAN fires at poll 3 (BLOCKED_THRESHOLD)"
expect_json_field '.stale_polls' "3" "BLOCKED_ON_HUMAN stale_polls == BLOCKED_THRESHOLD"
echo "$OUT" | jq -e '.threads | length > 0' >/dev/null || fail "BLOCKED_ON_HUMAN: threads should be non-empty"
mark_exercised 3

# Boundary check: same repeated-stale-thread fixture but max_polls capped at 2
# (below BLOCKED_THRESHOLD) must NOT reach exit 3 — it hits IDLE_TIMEOUT
# instead, proving the threshold does not fire early.
new_case; new_pr
fixture_snapshot_with_thread "$STALE_ID" > "$CASE_DIR/1.json"
fixture_poll_thread_only "$STALE_ID" > "$CASE_DIR/2.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoD2" "$PR" 1 2
expect_exit 2 "BLOCKED_ON_HUMAN boundary (max_polls=2 < threshold=3 must not fire exit 3 early)"
expect_json_field '.status' "IDLE_TIMEOUT" "BLOCKED_ON_HUMAN boundary status"

# =============================================================================
# Exit 10 (usage errors)
# =============================================================================

new_case
run_pr "$CASE_DIR"
expect_exit 10 "no arguments"
expect_stderr_match "Usage: poll-pr-reviews.sh" "no arguments usage message"
expect_stderr_no_match "unbound variable" "no arguments: clean stderr"

new_case
run_pr "$CASE_DIR" "$OWNER_BASE/repoE"
expect_exit 10 "missing pr_number"
expect_stderr_match "Usage: poll-pr-reviews.sh" "missing pr_number usage message"
expect_stderr_no_match "unbound variable" "missing pr_number: clean stderr"

for bad_interval in 0 -1 abc; do
  new_case; new_pr
  run_pr "$CASE_DIR" "$OWNER_BASE/repoF" "$PR" "$bad_interval" 4
  expect_exit 10 "poll_interval_sec=$bad_interval"
  expect_stderr_match "poll_interval_sec must be a positive integer" "poll_interval_sec=$bad_interval message"
  expect_stderr_no_match "unbound variable" "poll_interval_sec=$bad_interval: clean stderr"
done

for bad_max in 0 -1 abc; do
  new_case; new_pr
  run_pr "$CASE_DIR" "$OWNER_BASE/repoF" "$PR" 1 "$bad_max"
  expect_exit 10 "max_polls=$bad_max"
  expect_stderr_match "max_polls must be a positive integer" "max_polls=$bad_max message"
  expect_stderr_no_match "unbound variable" "max_polls=$bad_max: clean stderr"
done
mark_exercised 10

# GraphQL-injection guard: a crafted pr_number must be rejected as a usage
# error (exit 10) rather than reaching the GraphQL query interpolation, per
# the FINDINGS.md "poll-pr-reviews.sh does not validate PR_NUMBER/OWNER/NAME"
# security-relevant gap.
new_case
run_pr "$CASE_DIR" "$OWNER_BASE/repoInj" "1) {id} } } #" 1 4
expect_exit 10 "GraphQL-injection pr_number"
expect_stderr_match "pr_number must be a positive integer" "GraphQL-injection pr_number message"
expect_stderr_no_match "unbound variable" "GraphQL-injection pr_number: clean stderr"

# owner/name charset guard: values outside ^[A-Za-z0-9._-]+$ must be rejected
# before GraphQL interpolation, not passed through.
for bad_repo in "bad owner/repo" "owner/bad name" "owner/repo;drop"; do
  new_case; new_pr
  run_pr "$CASE_DIR" "$bad_repo" "$PR" 1 4
  expect_exit 10 "invalid owner/name repo='$bad_repo'"
  expect_stderr_match 'owner and name must match' "invalid owner/name repo='$bad_repo' message"
  expect_stderr_no_match "unbound variable" "invalid owner/name repo='$bad_repo': clean stderr"
done

# =============================================================================
# Exit 11 (SNAPSHOT_FAILURE)
# =============================================================================

# Empty output from gh
new_case; new_pr
: > "$CASE_DIR/1.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoG" "$PR" 1 4
expect_exit 11 "SNAPSHOT_FAILURE empty output"
echo "$ERR" | grep -q "Failed to snapshot PR state" || fail "SNAPSHOT_FAILURE empty output: expected error message on stderr"

# GraphQL error object with no .data.repository.pullRequest
new_case; new_pr
fixture_error_object > "$CASE_DIR/1.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoG" "$PR" 1 4
expect_exit 11 "SNAPSHOT_FAILURE error object"
echo "$ERR" | grep -q "Failed to snapshot PR state" || fail "SNAPSHOT_FAILURE error object: expected error message on stderr"
mark_exercised 11

# =============================================================================
# Transient API failure survived (garbage poll 1, valid approval poll 2)
# =============================================================================

new_case; new_pr
fixture_empty_snapshot > "$CASE_DIR/1.json"
printf 'not valid json{{{' > "$CASE_DIR/2.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/3.json"
run_pr "$CASE_DIR" "$OWNER_BASE/repoH" "$PR" 1 4
expect_exit 0 "transient failure survived, then approved"
expect_json_field '.status' "APPROVED" "transient failure: eventual status"
expect_json_field '.poll' "2" "transient failure: approval on poll 2"
echo "$ERR" | grep -q "API request failed, retrying next cycle" || fail "transient failure: expected retry line logged to stderr"

# =============================================================================
# Pidfile lifecycle
# =============================================================================

# Exists during run, removed on exit.
new_case; new_pr
OWNER_PID="pidowner$$"
NAME_PID="pidrepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF="$(pidfile_for "$OWNER_PID" "$NAME_PID" "$PR")"
rm -f "$PF"
(
  GH_STUB_DIR="$CASE_DIR" PATH="$STUB_BIN:$PATH" "$SCRIPT" "$OWNER_PID/$NAME_PID" "$PR" 1 4 >/dev/null 2>/dev/null
) &
BGPID=$!
sleep 0.3
[ -f "$PF" ] || fail "pidfile lifecycle: expected pidfile $PF to exist during run"
wait "$BGPID" 2>/dev/null || true
[ ! -f "$PF" ] || fail "pidfile lifecycle: expected pidfile $PF to be removed after exit"

# Stale-pidfile, bare-PID format (no "pid:lstart" separator) — asserted only
# against a process the suite itself spawned (never a PID we did not
# create). A colon-less pidfile carries no identity token to verify against,
# and its path is fully predictable from owner/name/pr — on a shared host an
# attacker could pre-create it naming an arbitrary live process, then wait
# for a legitimate run to kill it on their behalf (a same-user DoS). Per the
# FINDINGS.md remediation, acquire_pidfile's back-compat branch no longer
# falls back to unconditional kill-if-alive in this shape: the self-spawned
# process must be left ALIVE and a "no identity token" warning logged
# instead. This flips the prior assertion (kill-if-alive) intentionally —
# it is a DoS closure, not a regression.
new_case; new_pr
OWNER_STALE="staleowner$$"
NAME_STALE="stalerepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_STALE="$(pidfile_for "$OWNER_STALE" "$NAME_STALE" "$PR")"
sleep 30 &
SLEEP_PID=$!
echo "$SLEEP_PID" > "$PF_STALE"
run_pr "$CASE_DIR" "$OWNER_STALE/$NAME_STALE" "$PR" 1 4
expect_exit 0 "stale pidfile, bare-PID format: run still completes normally"
kill -0 "$SLEEP_PID" 2>/dev/null || fail "stale pidfile, bare-PID format: self-spawned sleep should have been left ALIVE (no identity token must block the kill)"
expect_stderr_no_match "Killed previous polling instance" "stale pidfile, bare-PID format: no kill message should be logged"
echo "$ERR" | grep -q "Pidfile has no identity token, not killing (PID $SLEEP_PID)" || fail "stale pidfile, bare-PID format: expected no-identity-token warning logged"
kill "$SLEEP_PID" 2>/dev/null || true
wait "$SLEEP_PID" 2>/dev/null || true
rm -f "$PF_STALE"

# Stale-pidfile identity mismatch ("pid:lstart" format, wrong start time) —
# simulates PID reuse: the pidfile's recorded start time does not match the
# live process currently holding that PID (as if the original process that
# wrote the pidfile had already exited and the OS reassigned its PID to an
# unrelated process — here, our self-spawned sleep). acquire_pidfile must
# refuse to kill it: no kill line logged, process left alive. Proves the
# identity check (poll-common.sh:91-106) actually gates the kill rather than
# merely being present but unused.
new_case; new_pr
OWNER_MISMATCH="mismatchowner$$"
NAME_MISMATCH="mismatchrepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_MISMATCH="$(pidfile_for "$OWNER_MISMATCH" "$NAME_MISMATCH" "$PR")"
sleep 30 &
SLEEP_PID_MISMATCH=$!
echo "$SLEEP_PID_MISMATCH:Thu Jan  1 00:00:00 1970" > "$PF_MISMATCH"
run_pr "$CASE_DIR" "$OWNER_MISMATCH/$NAME_MISMATCH" "$PR" 1 4
expect_exit 0 "stale pidfile identity mismatch: run still completes normally"
kill -0 "$SLEEP_PID_MISMATCH" 2>/dev/null || fail "stale pidfile identity mismatch: self-spawned sleep should have been left ALIVE (mismatched start time must block the kill)"
expect_stderr_no_match "Killed previous polling instance" "stale pidfile identity mismatch: no kill message should be logged"
kill "$SLEEP_PID_MISMATCH" 2>/dev/null || true
wait "$SLEEP_PID_MISMATCH" 2>/dev/null || true
rm -f "$PF_MISMATCH"

# Positive control — identity-verified kill path. The two negative cases
# above (bare-PID format, identity mismatch) both prove the kill is
# withheld; neither proves the kill branch actually fires when it SHOULD.
# A mutation that neuters the kill entirely (e.g. `if false && [ "$(...)" =
# "$old_start" ]; then`) would still pass every case above and the whole
# rest of the suite. This case is the only one that fails under that
# mutation: a pidfile whose recorded start time genuinely matches the live
# process's current start time must result in that process being killed.
new_case; new_pr
OWNER_MATCH="matchowner$$"
NAME_MATCH="matchrepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_MATCH="$(pidfile_for "$OWNER_MATCH" "$NAME_MATCH" "$PR")"
sleep 30 &
SLEEP_PID_MATCH=$!
echo "$SLEEP_PID_MATCH:$(ps -o lstart= -p "$SLEEP_PID_MATCH" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" > "$PF_MATCH"
run_pr "$CASE_DIR" "$OWNER_MATCH/$NAME_MATCH" "$PR" 1 4
expect_exit 0 "stale pidfile identity match: run still completes normally"
kill -0 "$SLEEP_PID_MATCH" 2>/dev/null && fail "stale pidfile identity match: self-spawned sleep should have been killed" || true
echo "$ERR" | grep -q "Killed previous polling instance (PID $SLEEP_PID_MATCH)" || fail "stale pidfile identity match: expected kill message logged"
wait "$SLEEP_PID_MATCH" 2>/dev/null || true
rm -f "$PF_MATCH"

# =============================================================================
# Symlinked pidfile path — refused, not followed (CWE-59 closure)
# =============================================================================

# A pidfile path that is a symlink to an arbitrary file must never be
# written through: acquire_pidfile must detect the symlink, log a warning,
# unlink it, and proceed as if no pidfile existed — never follow it and
# clobber whatever it points at.
new_case; new_pr
OWNER_SYMLINK="symlinkowner$$"
NAME_SYMLINK="symlinkrepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_SYMLINK="$(pidfile_for "$OWNER_SYMLINK" "$NAME_SYMLINK" "$PR")"
mkdir -p "$(dirname "$PF_SYMLINK")"
SENTINEL="$SUITE_TMP/sentinel_$PR"
printf 'do not touch me' > "$SENTINEL"
ln -sf "$SENTINEL" "$PF_SYMLINK"
run_pr "$CASE_DIR" "$OWNER_SYMLINK/$NAME_SYMLINK" "$PR" 1 4
expect_exit 0 "symlinked pidfile: run still completes normally"
[ "$(cat "$SENTINEL")" = "do not touch me" ] || fail "symlinked pidfile: sentinel content was modified (symlink followed / clobbered)"
echo "$ERR" | grep -q "Pidfile is a symlink, refusing to follow" || fail "symlinked pidfile: expected symlink-refusal warning logged"
[ ! -L "$PF_SYMLINK" ] || fail "symlinked pidfile: expected the symlink itself to be gone (unlinked, not left in place)"
rm -f "$SENTINEL"

# =============================================================================
# Pidfile directory verification — refused when untrusted (residual gap:
# `mkdir -m 700 -p` is a no-op on a pre-existing directory)
# =============================================================================

# The pidfile's parent directory lives at a predictable per-uid path
# (${TMPDIR:-/tmp}/poll-$(id -u)), shared by every pidfile this suite writes.
# If an attacker plants a symlink there before acquire_pidfile ever runs
# (simulating a pre-created, untrusted directory — the "mkdir -m is a no-op
# on an existing dir" gap), acquire_pidfile must detect it via the
# post-mkdir verification and refuse outright: log a warning, write nothing
# anywhere, and leave the symlink exactly as found (refuse, don't repair —
# repairing would mean deleting something inside a directory we don't trust).
new_case; new_pr
OWNER_BADDIR="baddirowner$$"
NAME_BADDIR="baddirrepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_BADDIR="$(pidfile_for "$OWNER_BADDIR" "$NAME_BADDIR" "$PR")"
PIDDIR_BADDIR="$(dirname "$PF_BADDIR")"
ELSEWHERE="$SUITE_TMP/elsewhere_$PR"
mkdir -p "$ELSEWHERE"
# Replace the piddir (already created 0700 by earlier cases in this suite)
# with a symlink to an unrelated directory, standing in for an attacker
# having pre-planted it before this user's first run.
rm -rf "$PIDDIR_BADDIR"
ln -s "$ELSEWHERE" "$PIDDIR_BADDIR"
run_pr "$CASE_DIR" "$OWNER_BADDIR/$NAME_BADDIR" "$PR" 1 4
expect_exit 0 "untrusted pidfile directory: run still completes normally (degrades, does not crash)"
echo "$ERR" | grep -q "Pidfile directory is untrusted, refusing" || fail "untrusted pidfile directory: expected refusal message logged"
[ -z "$(ls -A "$ELSEWHERE" 2>/dev/null)" ] || fail "untrusted pidfile directory: nothing should have been written into the attacker-controlled target directory"
[ -L "$PIDDIR_BADDIR" ] || fail "untrusted pidfile directory: symlink should be left exactly as found (refuse, not repair)"
# Restore a legitimate 0700 directory: later suite runs (and the trailing
# cleanup trap) expect the shared piddir to be a real, owned directory.
rm -f "$PIDDIR_BADDIR"
mkdir -m 700 -p "$PIDDIR_BADDIR"

# TOCTOU closure: a symlink planted at the pidfile *path* (not its parent
# directory) mid-run — specifically during the multi-second kill-retry loop
# inside acquire_pidfile, after the initial `[ -L "$pidfile" ]` check has
# already passed — must not be followed by the final write. The identity
# process below ignores SIGTERM (via a trap) so the kill-retry loop is
# forced through its full ~3-second window (1s poll x 3 before SIGKILL),
# giving a background job time to swap the pidfile path for a symlink
# pointing at a sentinel file partway through.
new_case; new_pr
OWNER_TOCTOU="toctouowner$$"
NAME_TOCTOU="toctourepo"
fixture_empty_snapshot > "$CASE_DIR/1.json"
fixture_poll_approval "dependabot[bot]" > "$CASE_DIR/2.json"
PF_TOCTOU="$(pidfile_for "$OWNER_TOCTOU" "$NAME_TOCTOU" "$PR")"
mkdir -p "$(dirname "$PF_TOCTOU")"
bash -c 'trap "" TERM; exec sleep 30' &
TOCTOU_PID=$!
echo "$TOCTOU_PID:$(ps -o lstart= -p "$TOCTOU_PID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" > "$PF_TOCTOU"
TOCTOU_SENTINEL="$SUITE_TMP/toctou_sentinel_$PR"
printf 'do not touch me either' > "$TOCTOU_SENTINEL"
(
  sleep 1.5
  rm -f "$PF_TOCTOU"
  ln -sf "$TOCTOU_SENTINEL" "$PF_TOCTOU"
) &
PLANTER_PID=$!
run_pr "$CASE_DIR" "$OWNER_TOCTOU/$NAME_TOCTOU" "$PR" 1 4
wait "$PLANTER_PID" 2>/dev/null || true
expect_exit 0 "pidfile TOCTOU: run still completes normally"
[ "$(cat "$TOCTOU_SENTINEL")" = "do not touch me either" ] || fail "pidfile TOCTOU: sentinel content was modified (mid-run symlink was followed / clobbered)"
kill -0 "$TOCTOU_PID" 2>/dev/null && kill -9 "$TOCTOU_PID" 2>/dev/null || true
wait "$TOCTOU_PID" 2>/dev/null || true
rm -f "$TOCTOU_SENTINEL" "$PF_TOCTOU"

# =============================================================================
# Exit 4 (PIPELINE_FAILED) — deliberately NOT asserted.
# PIPELINE_FAILED is GitLab-only (poll-mr-reviews.sh); poll-pr-reviews.sh has
# no code path that emits it, so it is not exercised by this suite. This is
# a deliberate omission, not an oversight.
# =============================================================================

echo "Exercised exit codes:$EXERCISED_CODES (exit 4 deliberately omitted — GitLab-only, unreachable here)"
echo "poll-pr-reviews.sh tests passed"
