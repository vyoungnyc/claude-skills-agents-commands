#!/bin/bash
# Self-contained test suite for statusline/token-stats.sh.
# Style follows scripts/sync-claude-config.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# token-stats.sh is pure and network-free (jq over a local JSONL file), so
# every fixture here is a synthetic transcript under this suite's own
# mktemp -d tree — no real transcript or $HOME is ever touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/token-stats.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

# set_mtime <epoch> <file> — GNU date first, BSD fallback (mirrors the
# scripts' own _dfmt/file_age date dance), then touch -t (POSIX, both
# platforms) with the resulting CCYYMMDDhhmm.SS stamp.
set_mtime() {
  local epoch="$1" file="$2" stamp
  stamp=$(date -d "@$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null) || stamp=$(date -r "$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null)
  touch -t "$stamp" "$file"
}

# =======================================================================
# Basic sum + context length: totals sum across all main-chain rows
# (including a sidechain row), but context_length picks the newest
# MAIN-CHAIN row by timestamp — regardless of file order, and excluding
# the sidechain row even though it's the overall-latest timestamp.
# =======================================================================
T1="$SUITE_TMP/basic.jsonl"
cat > "$T1" <<'EOF'
{"message":{"usage":{"input_tokens":5000,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-26T10:04:00.000Z"}
{"message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T10:01:00.000Z"}
{"message":{"usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T10:03:00.000Z"}
{"message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T10:02:00.000Z"}
EOF
OUT1="$SUITE_TMP/out1/session.json"
bash "$SCRIPT" "$T1" "$OUT1"
[ -f "$OUT1" ] || fail "basic sum: cache file was not written"
[ "$(jq -r '.input' "$OUT1")" = "5310" ] || fail "basic sum: input should include the sidechain row (got $(jq -r '.input' "$OUT1"))"
[ "$(jq -r '.output' "$OUT1")" = "136" ] || fail "basic sum: output mismatch (got $(jq -r '.output' "$OUT1"))"
[ "$(jq -r '.cache_read' "$OUT1")" = "1000" ] || fail "basic sum: cache_read mismatch"
[ "$(jq -r '.cache_write' "$OUT1")" = "500" ] || fail "basic sum: cache_write mismatch"
[ "$(jq -r '.context_length' "$OUT1")" = "1700" ] \
  || fail "context_length must be the newest MAIN-CHAIN row (200+1000+500=1700) not the sidechain row or file order (got $(jq -r '.context_length' "$OUT1"))"

# =======================================================================
# Streaming dedup: an intermediate row with stop_reason:null (not the last
# row in the file) is dropped; a finalized row and the still-open trailing
# row are both counted.
# =======================================================================
T2="$SUITE_TMP/streaming.jsonl"
cat > "$T2" <<'EOF'
{"message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T11:00:00.000Z"}
{"message":{"usage":{"input_tokens":999,"output_tokens":999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":null},"isSidechain":false,"timestamp":"2026-08-26T11:01:00.000Z"}
{"message":{"usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T11:02:00.000Z"}
EOF
OUT2="$SUITE_TMP/out2/session.json"
bash "$SCRIPT" "$T2" "$OUT2"
[ "$(jq -r '.input' "$OUT2")" = "30" ] || fail "streaming dedup: expected 10+20=30, got $(jq -r '.input' "$OUT2") (intermediate null row not excluded)"
[ "$(jq -r '.output' "$OUT2")" = "13" ] || fail "streaming dedup: expected 5+8=13, got $(jq -r '.output' "$OUT2")"

# =======================================================================
# Regression: streaming dedup is decided PER ROW, not by a file-level
# `any(has("stop_reason"))` probe. A transcript can mix schemas -- older
# rows with no stop_reason field at all, newer rows carrying it (e.g. a
# session spanning a client upgrade). Under the file-level probe, the mere
# presence of ONE stop_reason row flipped every row into field-aware mode,
# where an ABSENT field reads as null and the row is discarded as a
# streaming intermediate -- silently dropping every fieldless billable row
# except whichever one happened to land last. A row with no stop_reason
# field is finalized (its schema never emitted one) and must be counted.
# =======================================================================
T_MIXED="$SUITE_TMP/mixed-schema.jsonl"
cat > "$T_MIXED" <<'EOF'
{"message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5"},"isSidechain":false,"timestamp":"2026-08-26T15:00:00.000Z"}
{"message":{"usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5"},"isSidechain":false,"timestamp":"2026-08-26T15:01:00.000Z"}
{"message":{"usage":{"input_tokens":400,"output_tokens":40,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T15:02:00.000Z"}
{"message":{"usage":{"input_tokens":999,"output_tokens":999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":null},"isSidechain":false,"timestamp":"2026-08-26T15:03:00.000Z"}
{"message":{"usage":{"input_tokens":800,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T15:04:00.000Z"}
EOF
OUT_MIXED="$SUITE_TMP/out-mixed/session.json"
bash "$SCRIPT" "$T_MIXED" "$OUT_MIXED"
# 100 + 200 (fieldless, finalized) + 400 + 800 (explicitly finalized); the
# mid-file stop_reason:null row (999) is a streaming intermediate and stays out.
[ "$(jq -r '.input' "$OUT_MIXED")" = "1500" ] \
  || fail "mixed-schema: fieldless rows are finalized and must be counted: expected 100+200+400+800=1500, got $(jq -r '.input' "$OUT_MIXED")"
[ "$(jq -r '.output' "$OUT_MIXED")" = "150" ] \
  || fail "mixed-schema: expected 10+20+40+80=150, got $(jq -r '.output' "$OUT_MIXED")"

# A fieldless row must still be counted when it is the file's LAST row and a
# stop_reason-bearing row precedes it (the one case the old probe happened to
# get right -- pinned so the per-row rule does not regress it).
T_MIXED2="$SUITE_TMP/mixed-schema-trailing.jsonl"
cat > "$T_MIXED2" <<'EOF'
{"message":{"usage":{"input_tokens":400,"output_tokens":40,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T16:00:00.000Z"}
{"message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5"},"isSidechain":false,"timestamp":"2026-08-26T16:01:00.000Z"}
EOF
OUT_MIXED2="$SUITE_TMP/out-mixed2/session.json"
bash "$SCRIPT" "$T_MIXED2" "$OUT_MIXED2"
[ "$(jq -r '.input' "$OUT_MIXED2")" = "500" ] \
  || fail "mixed-schema trailing: expected 400+100=500, got $(jq -r '.input' "$OUT_MIXED2")"

# =======================================================================
# isApiErrorMessage rows are skipped entirely, even with a huge usage
# payload and a truthy stop_reason.
# =======================================================================
T3="$SUITE_TMP/apierror.jsonl"
cat > "$T3" <<'EOF'
{"message":{"usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T12:00:00.000Z"}
{"message":{"usage":{"input_tokens":99999,"output_tokens":99999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isApiErrorMessage":true,"isSidechain":false,"timestamp":"2026-08-26T12:01:00.000Z"}
EOF
OUT3="$SUITE_TMP/out3/session.json"
bash "$SCRIPT" "$T3" "$OUT3"
[ "$(jq -r '.input' "$OUT3")" = "50" ] || fail "isApiErrorMessage row was not skipped (got input=$(jq -r '.input' "$OUT3"))"

# =======================================================================
# Subagents: every agent-*.jsonl under <dir>/<stem>/subagents/ is summed
# into `agents`, separately from `main` (which only reads the transcript
# itself).
# =======================================================================
SESSION_DIR="$SUITE_TMP/subagent-session"
mkdir -p "$SESSION_DIR/mysession/subagents"
T4="$SESSION_DIR/mysession.jsonl"
cat > "$T4" <<'EOF'
{"message":{"usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T13:00:00.000Z"}
EOF
cat > "$SESSION_DIR/mysession/subagents/agent-1.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-26T13:01:00.000Z"}
EOF
cat > "$SESSION_DIR/mysession/subagents/agent-2.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-26T13:02:00.000Z"}
EOF
OUT4="$SUITE_TMP/out4/session.json"
bash "$SCRIPT" "$T4" "$OUT4"
[ "$(jq -r '.main.input' "$OUT4")" = "100" ] || fail "subagents: main.input should only reflect the transcript itself"
[ "$(jq -r '.agents.input' "$OUT4")" = "30" ] || fail "subagents: agents.input should sum agent-1 (10) + agent-2 (20) = 30"
[ "$(jq -r '.agents.output' "$OUT4")" = "13" ] || fail "subagents: agents.output should sum agent-1 (5) + agent-2 (8) = 13"
[ "$(jq -r '.input' "$OUT4")" = "130" ] || fail "subagents: top-level input should be main+agents = 100+30=130"

# =======================================================================
# Regression: streaming dedup must run PER SUBAGENT FILE, not once across
# all of them concatenated. Two concurrently-streaming subagents can each
# end their own transcript on a billable stop_reason:null trailing row.
# Feeding every file into one jq invocation makes the "keep a trailing null
# row" rule protect only the file `find` happens to list LAST -- silently
# dropping the OTHER file's pending row. Both files get their own pending
# row here so the assertion is independent of find's (unspecified,
# filesystem-dependent) listing order: under the bug, whichever file lands
# non-last always loses its pending row, so the total is always short by
# one of the two regardless of order; the fix requires the full total.
# =======================================================================
SESSION_DIR2="$SUITE_TMP/subagent-streaming-session"
mkdir -p "$SESSION_DIR2/mysession/subagents"
T5="$SESSION_DIR2/mysession.jsonl"
echo '{"message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-26T14:00:00.000Z"}' > "$T5"
cat > "$SESSION_DIR2/mysession/subagents/agent-1.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-26T14:01:00.000Z"}
{"message":{"usage":{"input_tokens":100,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":null},"isSidechain":true,"timestamp":"2026-08-26T14:01:30.000Z"}
EOF
cat > "$SESSION_DIR2/mysession/subagents/agent-2.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-26T14:02:00.000Z"}
{"message":{"usage":{"input_tokens":200,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":null},"isSidechain":true,"timestamp":"2026-08-26T14:02:30.000Z"}
EOF
OUT5="$SUITE_TMP/out5/session.json"
bash "$SCRIPT" "$T5" "$OUT5"
[ "$(jq -r '.agents.input' "$OUT5")" = "330" ] \
  || fail "both files' own trailing pending rows must survive per-file dedup: expected (10+100)+(20+200)=330, got $(jq -r '.agents.input' "$OUT5")"
[ "$(jq -r '.agents.output' "$OUT5")" = "313" ] \
  || fail "expected (5+100)+(8+200)=313, got $(jq -r '.agents.output' "$OUT5")"

# =======================================================================
# Nested cache path auto-create: the new token_history/<project>/ layout
# means the output directory usually doesn't exist yet — token-stats.sh
# must mkdir -p it rather than assuming ~/.claude already exists.
# =======================================================================
NESTED_OUT="$SUITE_TMP/token_history/-Users-someone-some-project/deadbeef-session.json"
[ ! -d "$(dirname "$NESTED_OUT")" ] || fail "test setup: nested dir should not pre-exist"
bash "$SCRIPT" "$T1" "$NESTED_OUT"
[ -f "$NESTED_OUT" ] || fail "token-stats.sh did not create its nested output directory"

# =======================================================================
# Single-flight lock: a held lock (fresh) makes the script exit without
# writing or clobbering the existing cache file.
# =======================================================================
LOCK_OUT="$SUITE_TMP/lock/session.json"
mkdir -p "$SUITE_TMP/lock"
echo '{"input":999}' > "$LOCK_OUT"
mkdir "$LOCK_OUT.lock"
bash "$SCRIPT" "$T1" "$LOCK_OUT"
[ "$(jq -r '.input' "$LOCK_OUT")" = "999" ] || fail "a held lock must prevent the run from overwriting the cache file"
rmdir "$LOCK_OUT.lock"

# =======================================================================
# Stale lock (>120s old) is reclaimed rather than blocking forever.
# =======================================================================
STALE_OUT="$SUITE_TMP/stale/session.json"
mkdir -p "$SUITE_TMP/stale"
mkdir "$STALE_OUT.lock"
set_mtime "$(($(date +%s) - 200))" "$STALE_OUT.lock"
bash "$SCRIPT" "$T1" "$STALE_OUT"
[ -f "$STALE_OUT" ] || fail "a stale (>120s) lock with no recorded owner should have been reclaimed, allowing the run to complete"
[ ! -d "$STALE_OUT.lock" ] || fail "lock directory should be released via the trap after a successful run"

# =======================================================================
# A lock held by a LIVE process is never reclaimed, however old it is: a
# large transcript plus many subagent files can outlive a fixed staleness
# threshold, and stealing the lock starts a concurrent run whose exit then
# tears down the newer holder's lock, racing them on the output temp file.
# This suite's own pid stands in for the live holder. A dead owner is still
# reclaimed, so a crash cannot deadlock the cache.
# =======================================================================
LIVEOWNER_OUT="$SUITE_TMP/liveowner/session.json"
mkdir -p "$SUITE_TMP/liveowner"
echo '{"input":999}' > "$LIVEOWNER_OUT"
mkdir "$LIVEOWNER_OUT.lock"
printf '%s' "$$" > "$LIVEOWNER_OUT.lock/owner"
set_mtime "$(($(date +%s) - 400))" "$LIVEOWNER_OUT.lock"
bash "$SCRIPT" "$T1" "$LIVEOWNER_OUT"
[ "$(jq -r '.input' "$LIVEOWNER_OUT")" = "999" ] \
  || fail "a lock owned by a LIVE process was reclaimed despite its age -- the cache was overwritten by a concurrent run"
[ -d "$LIVEOWNER_OUT.lock" ] || fail "the live owner's lock must still exist"
[ "$(cat "$LIVEOWNER_OUT.lock/owner")" = "$$" ] || fail "the live owner's lock was taken over"

( : ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
DEADOWNER_OUT="$SUITE_TMP/deadowner/session.json"
mkdir -p "$SUITE_TMP/deadowner"
mkdir "$DEADOWNER_OUT.lock"
printf '%s' "$DEAD_PID" > "$DEADOWNER_OUT.lock/owner"
bash "$SCRIPT" "$T1" "$DEADOWNER_OUT"
[ -f "$DEADOWNER_OUT" ] || fail "a lock whose owner is dead must be reclaimed rather than deadlocking"
[ ! -d "$DEADOWNER_OUT.lock" ] || fail "lock should be released after reclaiming from a dead owner"
LEFTOVER=$(find "$SUITE_TMP/deadowner" -name 'session.json.tmp*' 2>/dev/null)
[ -z "$LEFTOVER" ] || fail "an output temp file was left behind: $LEFTOVER"

# =======================================================================
# Opportunistic cleanup: a cache file untouched for >7 days in the same
# project directory is swept; a fresh one survives.
# =======================================================================
CLEAN_DIR="$SUITE_TMP/token_history/-Users-someone-cleanup-project"
mkdir -p "$CLEAN_DIR"
OLD_SESSION="$CLEAN_DIR/old-session.json"
echo '{"input":1}' > "$OLD_SESSION"
set_mtime "$(($(date +%s) - 900000))" "$OLD_SESSION"  # ~10.4 days old
bash "$SCRIPT" "$T1" "$CLEAN_DIR/new-session.json"
[ ! -f "$OLD_SESSION" ] || fail "a cache file older than 7 days should be swept by the cleanup pass"
[ -f "$CLEAN_DIR/new-session.json" ] || fail "the just-written cache file should survive its own cleanup pass"

# =======================================================================
# Regression: a transcript is appended to LIVE, so its last line is often a
# partially written object. jq aborts the whole parse on that, and the zero
# fallback then replaced every valid row with zeros -- publishing a zeroed
# session to the cache and misreporting cost. Valid rows must survive a torn
# trailing row.
# =======================================================================
TORN="$SUITE_TMP/torn.jsonl"
cat > "$TORN" <<'EOF'
{"message":{"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:00:00.000Z"}
{"message":{"usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:01:00.000Z"}
EOF
# A half-written row, with no trailing newline -- exactly how a live append looks.
printf '{"message":{"usage":{"input_tokens":50,"outp' >> "$TORN"
TORN_OUT="$SUITE_TMP/torn-out/session.json"
bash "$SCRIPT" "$TORN" "$TORN_OUT"
[ "$(jq -r '.input' "$TORN_OUT")" = "3000" ] \
  || fail "a torn trailing row must not discard the valid rows: expected 3000, got $(jq -r '.input' "$TORN_OUT")"
[ "$(jq -r '.output' "$TORN_OUT")" = "500" ] \
  || fail "expected output 500 from the intact rows, got $(jq -r '.output' "$TORN_OUT")"
[ "$(jq -r '.context_length' "$TORN_OUT")" = "2000" ] \
  || fail "context_length should come from the newest INTACT row, got $(jq -r '.context_length' "$TORN_OUT")"

# A torn row in a SUBAGENT transcript likewise must not zero that subagent.
TORN_SESSION="$SUITE_TMP/torn-session"
mkdir -p "$TORN_SESSION/mysession/subagents"
echo '{"message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T11:00:00.000Z"}' > "$TORN_SESSION/mysession.jsonl"
{
  echo '{"message":{"usage":{"input_tokens":700,"output_tokens":70,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-27T11:01:00.000Z"}'
  printf '{"message":{"usage":{"inp'
} > "$TORN_SESSION/mysession/subagents/agent-1.jsonl"
TORN_AG_OUT="$SUITE_TMP/torn-agent-out/session.json"
bash "$SCRIPT" "$TORN_SESSION/mysession.jsonl" "$TORN_AG_OUT"
[ "$(jq -r '.agents.input' "$TORN_AG_OUT")" = "700" ] \
  || fail "a torn row in a subagent transcript must not zero that subagent: expected 700, got $(jq -r '.agents.input' "$TORN_AG_OUT")"

# =======================================================================
# A populated cache is never replaced with an all-zero one: a session's
# cumulative totals only grow, so zeros mean the read failed, not that usage
# really went to zero. Serving the last good figures beats silently
# misreporting cost.
# =======================================================================
ZERO_OUT="$SUITE_TMP/zeroguard/session.json"
mkdir -p "$SUITE_TMP/zeroguard"
cat > "$ZERO_OUT" <<'EOF'
{"input": 5000, "output": 400, "cache_read": 100, "cache_write": 0, "est_cost": 0.02,
 "context_length": 5100,
 "main": {"input": 5000, "output": 400, "cache_read": 100, "cache_write": 0, "est_cost": 0.02},
 "agents": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "est_cost": 0}}
EOF
# A transcript whose every row is unparseable yields zeros.
GARBAGE="$SUITE_TMP/garbage.jsonl"
printf 'not json at all\nstill not json\n' > "$GARBAGE"
bash "$SCRIPT" "$GARBAGE" "$ZERO_OUT"
[ "$(jq -r '.input' "$ZERO_OUT")" = "5000" ] \
  || fail "an all-zero read must not overwrite a populated cache, got input=$(jq -r '.input' "$ZERO_OUT")"

# ...but a genuinely-zero NEW session (no prior cache) still writes, so a fresh
# session is not blocked from ever being created.
FRESHZERO_OUT="$SUITE_TMP/freshzero/session.json"
bash "$SCRIPT" "$GARBAGE" "$FRESHZERO_OUT"
[ -f "$FRESHZERO_OUT" ] || fail "a new session with zero usage should still create its cache file"
[ "$(jq -r '.input' "$FRESHZERO_OUT")" = "0" ] || fail "expected a zeroed cache for a brand-new session"

echo "token-stats.test.sh: all assertions passed"
