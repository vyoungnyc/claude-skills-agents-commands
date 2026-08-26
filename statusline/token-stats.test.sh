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
[ -f "$STALE_OUT" ] || fail "a stale (>120s) lock should have been reclaimed, allowing the run to complete"
[ ! -d "$STALE_OUT.lock" ] || fail "lock directory should be released (rmdir via trap) after a successful run"

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

echo "token-stats.test.sh: all assertions passed"
