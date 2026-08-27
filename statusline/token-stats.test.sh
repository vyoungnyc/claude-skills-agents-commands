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
SUITE_TMP=$(cd "$SUITE_TMP" && pwd -P)  # resolve macOS's /var -> /private/var symlink,
                                        # matching the other suites
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
# Regression: a malformed row MID-FILE must be skipped individually, not
# truncate the tail. Resuming an interrupted session appends valid rows
# AFTER the partial one, so the damaged row ends up in the middle -- a
# whole-stream parse stops there and the session silently stops
# accumulating from that point on, permanently. Only the bad row may be lost.
# =======================================================================
RESUMED="$SUITE_TMP/resumed.jsonl"
cat > "$RESUMED" <<'EOF'
{"message":{"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:00:00.000Z"}
{"message":{"usage":{"input_tokens":2000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:01:00.000Z"}
EOF
# The row torn by the interruption, now followed by post-resume appends.
printf '{"message":{"usage":{"input_tokens":9999,"outp\n' >> "$RESUMED"
cat >> "$RESUMED" <<'EOF'
{"message":{"usage":{"input_tokens":4000,"output_tokens":400,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:03:00.000Z"}
{"message":{"usage":{"input_tokens":8000,"output_tokens":800,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T10:04:00.000Z"}
EOF
RESUMED_OUT="$SUITE_TMP/resumed-out/session.json"
bash "$SCRIPT" "$RESUMED" "$RESUMED_OUT"
[ "$(jq -r '.input' "$RESUMED_OUT")" = "15000" ] \
  || fail "rows after a mid-file malformed row must still count: expected 1000+2000+4000+8000=15000, got $(jq -r '.input' "$RESUMED_OUT")"
[ "$(jq -r '.output' "$RESUMED_OUT")" = "1500" ] \
  || fail "expected output 100+200+400+800=1500, got $(jq -r '.output' "$RESUMED_OUT")"
[ "$(jq -r '.context_length' "$RESUMED_OUT")" = "8000" ] \
  || fail "context_length must come from the newest row AFTER the damaged one, got $(jq -r '.context_length' "$RESUMED_OUT")"
# The malformed row's own numbers must not leak in anywhere in the output.
# (Asserting != 24999 was dead: line above already pins .input == 15000.)
grep -q '9999' "$RESUMED_OUT" && fail "the malformed row's numbers leaked into the output"

# Same for a subagent transcript with a mid-file torn row.
RES_SESSION="$SUITE_TMP/resumed-session"
mkdir -p "$RES_SESSION/mysession/subagents"
echo '{"message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T12:00:00.000Z"}' > "$RES_SESSION/mysession.jsonl"
{
  echo '{"message":{"usage":{"input_tokens":300,"output_tokens":30,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-27T12:01:00.000Z"}'
  printf '{"message":{"usage":{"inp\n'
  echo '{"message":{"usage":{"input_tokens":500,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-27T12:02:00.000Z"}'
} > "$RES_SESSION/mysession/subagents/agent-1.jsonl"
RES_AG_OUT="$SUITE_TMP/resumed-agent-out/session.json"
bash "$SCRIPT" "$RES_SESSION/mysession.jsonl" "$RES_AG_OUT"
[ "$(jq -r '.agents.input' "$RES_AG_OUT")" = "800" ] \
  || fail "a subagent's rows after a mid-file malformed row must still count: expected 300+500=800, got $(jq -r '.agents.input' "$RES_AG_OUT")"

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

# =======================================================================
# SECURITY regression: an <out> path containing `..` must be refused, and
# the cleanup sweep must only ever run inside a token_history directory.
# The caller derives the path from `basename "$(dirname "$transcript")"`,
# which yields `..` for a transcript like /a/b/../s.jsonl -- escaping to
# the Claude home ROOT, where the `find -name '*.json' -mtime +7 -delete`
# sweep would delete the user settings.json and caches.
# =======================================================================
ESC_HOME="$SUITE_TMP/escape-home"
mkdir -p "$ESC_HOME/token_history"
for f in settings.json usage-cache.json .mr-cache.json; do
  echo '{"precious":true}' > "$ESC_HOME/$f"
  set_mtime "$(($(date +%s) - 900000))" "$ESC_HOME/$f"
done
bash "$SCRIPT" "$T1" "$ESC_HOME/token_history/../escaped.json" >/dev/null 2>&1
[ -f "$ESC_HOME/settings.json" ] \
  || fail "a traversing out-path let the cleanup sweep delete settings.json in the Claude home root"
[ -f "$ESC_HOME/usage-cache.json" ] || fail "the sweep deleted usage-cache.json"
[ -f "$ESC_HOME/.mr-cache.json" ] || fail "the sweep deleted .mr-cache.json"
[ ! -f "$ESC_HOME/escaped.json" ] || fail "a traversing out-path should be refused outright, not written"

# The sweep still prunes inside a legitimate token_history project directory.
SWEEP_DIR="$SUITE_TMP/token_history/-sweep-proj"
mkdir -p "$SWEEP_DIR"
echo '{}' > "$SWEEP_DIR/ancient.json"
set_mtime "$(($(date +%s) - 900000))" "$SWEEP_DIR/ancient.json"
bash "$SCRIPT" "$T1" "$SWEEP_DIR/current.json" >/dev/null 2>&1
[ ! -f "$SWEEP_DIR/ancient.json" ] || fail "the legitimate sweep should still prune a >7d cache"
[ -f "$SWEEP_DIR/current.json" ] || fail "the current cache should be written"
# ...and the cache is owner-only.
# GNU stat first, BSD second, and validate numerically -- `stat -f` on a GNU
# host is --file-system and prints a report with exit 0, which is the exact bug
# this suite is testing for in the script.
SWEEP_MODE=$(stat -c %a "$SWEEP_DIR/current.json" 2>/dev/null)
case "$SWEEP_MODE" in ''|*[!0-7]*) SWEEP_MODE=$(stat -f %Lp "$SWEEP_DIR/current.json" 2>/dev/null) ;; esac
case "$SWEEP_MODE" in ''|*[!0-7]*) SWEEP_MODE="?" ;; esac
[ "$SWEEP_MODE" = "600" ] || fail "the token cache should be mode 600, got $SWEEP_MODE"

# =======================================================================
# Regression: the mtime helper must validate that its output is NUMERIC.
# GNU `stat -f` means --file-system: it exits ZERO and prints a multi-line
# filesystem report, so a `|| echo 0` fallback never fires and the caller
# does arithmetic on junk -- which under `set -u` yields an empty age and
# collapses both lock guards, stealing a lock from a live owner.
# =======================================================================
GNUSTAT_DIR=$(mktemp -d "$SUITE_TMP/gnustat.XXXXXX")
cat > "$GNUSTAT_DIR/stat" <<'EOF'
#!/usr/bin/env bash
# Model GNU stat: -c works for an existing path; -f is --file-system and
# prints a report with exit 0 regardless.
if [ "$1" = "-c" ]; then
  [ -e "$3" ] || exit 1
  command stat -f %m "$3" 2>/dev/null || echo 0
  exit 0
fi
if [ "$1" = "-f" ]; then
  printf '  File: "%s"
  Type: apfs
' "${3:-x}"
  exit 0
fi
exit 1
EOF
chmod +x "$GNUSTAT_DIR/stat"
GNUSTAT_OUT="$SUITE_TMP/gnustat-out/session.json"
# A stale, owner-less lock: reclaimable only if the age is a usable number.
mkdir -p "$SUITE_TMP/gnustat-out"
mkdir "$GNUSTAT_OUT.lock"
set_mtime "$(($(date +%s) - 400))" "$GNUSTAT_OUT.lock"
env PATH="$GNUSTAT_DIR:$PATH" bash "$SCRIPT" "$T1" "$GNUSTAT_OUT" >/dev/null 2>&1
[ -f "$GNUSTAT_OUT" ] \
  || fail "with a GNU-style stat on PATH the run should still complete (age must be validated as numeric)"

# =======================================================================
# Regression: a failure must leave a negative-cache marker, or the caller
# relaunches this script on every ~30s render forever.
# =======================================================================
MARKER_OUT="$SUITE_TMP/marker/session.json"
bash "$SCRIPT" "$SUITE_TMP/definitely-not-a-transcript.jsonl" "$MARKER_OUT" >/dev/null 2>&1
[ -f "$MARKER_OUT" ] || fail "a missing transcript must still write a marker so the caller stops respawning us"
[ "$(jq -r '.failed' "$MARKER_OUT")" = "true" ] || fail "the marker should record failed:true"
[ "$(jq -r '.input' "$MARKER_OUT")" = "0" ] || fail "the marker should report zero usage"
# The marker must never overwrite real figures.
REALFIRST_OUT="$SUITE_TMP/realfirst/session.json"
bash "$SCRIPT" "$T1" "$REALFIRST_OUT" >/dev/null 2>&1
REAL_IN=$(jq -r '.input' "$REALFIRST_OUT")
bash "$SCRIPT" "$SUITE_TMP/definitely-not-a-transcript.jsonl" "$REALFIRST_OUT" >/dev/null 2>&1
[ "$(jq -r '.input' "$REALFIRST_OUT")" = "$REAL_IN" ] \
  || fail "the failure marker must not replace a populated cache"

# =======================================================================
# LOCK: the owner-aware single-flight body is duplicated verbatim across
# usage-refresh.sh, mr-refresh.sh and token-stats.sh but was tested only in
# usage-refresh, so a regression in THIS copy was invisible.
#
# Tested deterministically rather than by racing. Racing is a poor fit here:
# token-stats has no under-lock freshness re-check (unlike the two
# refreshers -- its lock is per-session-file, so contention is only
# same-session renders), which means contenders running one-after-another
# is CORRECT and a winner count proves nothing. The invariant that matters
# is that the reclaim decision is serialized and the release is
# ownership-checked, and both can be set up directly.
# =======================================================================

# Reclaim serialization: an abandoned lock is NOT reclaimable while another
# process holds the reclaim lock. Removing the `mkdir "$lock.reclaim"` guard
# lets this contender tear down a lock a winner is about to create.
RSER_OUT="$SUITE_TMP/reclaim-ser/session.json"
mkdir -p "$SUITE_TMP/reclaim-ser"
( : ) &
RSER_DEAD=$!
wait "$RSER_DEAD" 2>/dev/null || true
mkdir "$RSER_OUT.lock"
printf '%s' "$RSER_DEAD" > "$RSER_OUT.lock/owner"   # abandoned: owner is dead
mkdir "$RSER_OUT.lock.reclaim"                      # ...but a reclaim is in flight
bash "$SCRIPT" "$T1" "$RSER_OUT" >/dev/null 2>&1
[ ! -f "$RSER_OUT" ] \
  || fail "a contender reclaimed an abandoned lock while another process held the reclaim lock"
[ -d "$RSER_OUT.lock" ] || fail "the in-flight reclaim's target lock was torn down"
rm -rf "$RSER_OUT.lock" "$RSER_OUT.lock.reclaim"
# With the reclaim lock free, the same abandoned lock IS reclaimed (proving
# the assertion above is not passing for an unrelated reason).
mkdir "$RSER_OUT.lock"
printf '%s' "$RSER_DEAD" > "$RSER_OUT.lock/owner"
bash "$SCRIPT" "$T1" "$RSER_OUT" >/dev/null 2>&1
[ -f "$RSER_OUT" ] || fail "an abandoned lock with no in-flight reclaim should be reclaimed"

# Release side: a process whose lock is taken over mid-run must NOT delete
# the new owner's lock on exit -- doing so admits a third process.
#
# The takeover is performed BY the jq wrapper, i.e. from inside the run while
# it holds the lock, rather than by this suite polling for the lock and
# swapping the owner from outside. The external version is a race: under load
# the run can finish before the poll lands, and the test then fails for a
# reason that has nothing to do with the invariant.
TAKEOVER_OUT="$SUITE_TMP/tstakeover/session.json"
mkdir -p "$SUITE_TMP/tstakeover"
TS_OTHER_PID=$$   # a live pid that is never the script's own
LOCKBIN=$(mktemp -d "$SUITE_TMP/lockbin.XXXXXX")
REAL_JQ=$(command -v jq)
cat > "$LOCKBIN/jq" <<EOF
#!/usr/bin/env bash
# jq is only invoked after the lock is taken, so the first call is inside the
# critical section: swap the owner there, deterministically.
if [ ! -f "$SUITE_TMP/ts-took" ] && [ -d "$TAKEOVER_OUT.lock" ]; then
  : > "$SUITE_TMP/ts-took"
  printf '%s' "$TS_OTHER_PID" > "$TAKEOVER_OUT.lock/owner"
fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$LOCKBIN/jq"
rm -f "$SUITE_TMP/ts-took"
env PATH="$LOCKBIN:$PATH" bash "$SCRIPT" "$T1" "$TAKEOVER_OUT" >/dev/null 2>&1
[ -f "$SUITE_TMP/ts-took" ] || fail "takeover setup: the jq wrapper never ran inside the critical section"
[ -d "$TAKEOVER_OUT.lock" ] \
  || fail "the EXIT trap deleted a lock this process no longer owned -- that lets a third process in"
[ "$(cat "$TAKEOVER_OUT.lock/owner" 2>/dev/null)" = "$TS_OTHER_PID" ] \
  || fail "the new owner's lock content was clobbered"
rm -rf "$TAKEOVER_OUT.lock"

# =======================================================================
# COST MODEL. Every fixture above uses claude-sonnet-5 and the flat
# cache_creation_input_tokens shape, so the 5-way model dispatch, both cache
# multipliers and the 5m/1h TTL split had ZERO coverage -- and est_cost, the
# dollar figure users read, was never asserted numerically anywhere. All of
# these mutations previously survived.
#
# Prices are list-price per 1M tokens, per the table in token-stats.sh.
# =======================================================================
cost_of() {
  # <model> <in> <out> <cache_read> <cache_write_flat> -> est_cost
  local model="$1" tin="$2" tout="$3" tcr="$4" tcw="$5" f out
  f="$SUITE_TMP/cost-$RANDOM.jsonl"
  jq -nc --arg m "$model" --argjson i "$tin" --argjson o "$tout" --argjson r "$tcr" --argjson w "$tcw" \
    '{message:{usage:{input_tokens:$i,output_tokens:$o,cache_read_input_tokens:$r,cache_creation_input_tokens:$w},
      model:$m,stop_reason:"end_turn"},isSidechain:false,timestamp:"2026-08-27T10:00:00.000Z"}' > "$f"
  out="$SUITE_TMP/cost-out-$RANDOM/session.json"
  bash "$SCRIPT" "$f" "$out" >/dev/null 2>&1
  jq -r '.est_cost' "$out"
}
close_to() {
  # <actual> <expected> <label> -- float compare with a small tolerance
  awk -v a="$1" -v e="$2" 'BEGIN{ d=a-e; if (d<0) d=-d; exit !(d < 1e-9) }' \
    || fail "$3: expected ~$2, got $1"
}
# Input-token pricing per model. 1M input tokens => exactly the per-1M price.
close_to "$(cost_of claude-opus-4 1000000 0 0 0)"   5  "opus input price"
close_to "$(cost_of claude-sonnet-5 1000000 0 0 0)" 2  "sonnet-5 input price"
close_to "$(cost_of claude-sonnet-4 1000000 0 0 0)" 3  "sonnet (non-5) input price"
close_to "$(cost_of claude-haiku-4-5 1000000 0 0 0)" 1 "haiku input price"
close_to "$(cost_of claude-fable-5 1000000 0 0 0)"  10 "fable input price"
close_to "$(cost_of some-unknown-model 1000000 0 0 0)" 5 "unknown model falls back to the opus rate"
# Output is priced separately (sonnet-5: 10/1M).
close_to "$(cost_of claude-sonnet-5 0 1000000 0 0)" 10 "sonnet-5 output price"
# Cache reads are 0.1x the input rate.
close_to "$(cost_of claude-sonnet-5 0 0 1000000 0)" 0.2 "cache read is 0.1x input"
# A flat cache_creation_input_tokens is billed at the 5m rate (1.25x input).
close_to "$(cost_of claude-sonnet-5 0 0 0 1000000)" 2.5 "flat cache write is 1.25x input"

# The NESTED cache_creation shape: 5m at 1.25x, 1h at 2x.
NESTED="$SUITE_TMP/nested.jsonl"
jq -nc '{message:{usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,
   cache_creation:{ephemeral_5m_input_tokens:1000000,ephemeral_1h_input_tokens:1000000}},
   model:"claude-sonnet-5",stop_reason:"end_turn"},isSidechain:false,timestamp:"2026-08-27T10:00:00.000Z"}' > "$NESTED"
NESTED_OUT="$SUITE_TMP/nested-out/session.json"
bash "$SCRIPT" "$NESTED" "$NESTED_OUT" >/dev/null 2>&1
# 1M at 1.25x2 = 2.5, plus 1M at 2x2 = 4  =>  6.5
close_to "$(jq -r '.est_cost' "$NESTED_OUT")" 6.5 "nested 5m+1h cache writes"

# Known inconsistency, pinned so it is a deliberate choice rather than a
# surprise: `cache_write` sums only the FLAT field while the cost model
# prefers the nested one, so a nested-shape transcript reports a zero
# cache_write beside a nonzero cost. Documented rather than silently true.
[ "$(jq -r '.cache_write' "$NESTED_OUT")" = "0" ] \
  || fail "cache_write is expected to be 0 for a nested-only transcript (it sums the flat field); update this test if that changes"

# =======================================================================
# The <dir>/subagents/ fallback location: only <dir>/<stem>/subagents was
# covered, so removing this alternative from the search survived.
# =======================================================================
FALLBACK_DIR="$SUITE_TMP/fallback-session"
mkdir -p "$FALLBACK_DIR/subagents"
FB_T="$FALLBACK_DIR/mysession.jsonl"
echo '{"message":{"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":false,"timestamp":"2026-08-27T13:00:00.000Z"}' > "$FB_T"
echo '{"message":{"usage":{"input_tokens":600,"output_tokens":60,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5","stop_reason":"end_turn"},"isSidechain":true,"timestamp":"2026-08-27T13:01:00.000Z"}' > "$FALLBACK_DIR/subagents/agent-1.jsonl"
FB_OUT="$SUITE_TMP/fallback-out/session.json"
bash "$SCRIPT" "$FB_T" "$FB_OUT" >/dev/null 2>&1
[ "$(jq -r '.agents.input' "$FB_OUT")" = "600" ] \
  || fail "the <dir>/subagents/ fallback location should be searched, got $(jq -r '.agents.input' "$FB_OUT")"

echo "token-stats.test.sh: all assertions passed"
