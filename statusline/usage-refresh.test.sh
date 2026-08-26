#!/bin/bash
# Self-contained test suite for statusline/usage-refresh.sh.
# Style follows scripts/sync-claude-config.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# usage-refresh.sh hardcodes $HOME/.claude/* paths, so isolation here means
# `env HOME=... bash script.sh` against a throwaway tree, with a stubbed
# $HOME/.claude/fetch-usage.sh standing in for the real network call — the
# real ~/.claude and api.anthropic.com are never touched by this suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/usage-refresh.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
SUITE_TMP=$(cd "$SUITE_TMP" && pwd -P)
trap 'rm -rf "$SUITE_TMP"' EXIT

set_mtime() {
  local epoch="$1" file="$2" stamp
  stamp=$(date -d "@$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null) || stamp=$(date -r "$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null)
  touch -t "$stamp" "$file"
}

SUCCESS_BODY='{
  "spend": {"enabled": true, "used": {"amount_minor": 4250, "exponent": 2}, "limit": {"amount_minor": 10000, "exponent": 2}, "percent": 42, "severity": "normal"},
  "five_hour": {"utilization": 20, "resets_at": "2026-08-26T18:00:00Z"},
  "seven_day": {"utilization": 3, "resets_at": "2026-08-31T18:00:00Z"},
  "limits": [{"kind": "session", "severity": "normal"}, {"kind": "weekly_all", "severity": "warning"}]
}'

# fake_home <fetch_status> <fetch_body> — throwaway $HOME/.claude with a
# stubbed fetch-usage.sh that touches "$home/fetch-called" when invoked and
# emits <fetch_body> + the __HTTP_STATUS__<fetch_status> trailer, exit 0
# (matching the real fetch-usage.sh's always-exit-0 shape).
fake_home() {
  local status="$1" body="$2" dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/fetch-usage.sh" <<EOF
#!/usr/bin/env bash
touch "$dir/fetch-called"
cat <<'BODY'
$body
BODY
printf '__HTTP_STATUS__%s\n' "$status"
EOF
  chmod +x "$dir/.claude/fetch-usage.sh"
  printf '%s' "$dir"
}

fetch_called() { [ -f "$1/fetch-called" ]; }

# =======================================================================
# Fresh cache, no --force: freshness gate skips the refresh entirely.
# =======================================================================
FRESH_HOME=$(fake_home 200 "$SUCCESS_BODY")
echo '{"used":1}' > "$FRESH_HOME/.claude/usage-cache.json"
env HOME="$FRESH_HOME" bash "$SCRIPT" || true
fetch_called "$FRESH_HOME" && fail "fresh cache should have skipped the refresh (fetch-usage.sh was called)"
[ "$(cat "$FRESH_HOME/.claude/usage-cache.json")" = '{"used":1}' ] || fail "fresh-cache cache file should not have been touched"

# =======================================================================
# --force bypasses the freshness gate even with a fresh cache present.
# =======================================================================
FORCE_HOME=$(fake_home 200 "$SUCCESS_BODY")
echo '{"used":1}' > "$FORCE_HOME/.claude/usage-cache.json"
env HOME="$FORCE_HOME" bash "$SCRIPT" --force
fetch_called "$FORCE_HOME" || fail "--force should have called fetch-usage.sh despite a fresh cache"
[ "$(jq -r '.enabled' "$FORCE_HOME/.claude/usage-cache.json")" = "true" ] || fail "--force run should have written the new cache"

# =======================================================================
# Backoff window: a future .usage-backoff blocks a non-force refresh even
# with no cache at all.
# =======================================================================
BACKOFF_HOME=$(fake_home 200 "$SUCCESS_BODY")
echo "9999999999" > "$BACKOFF_HOME/.claude/.usage-backoff"
env HOME="$BACKOFF_HOME" bash "$SCRIPT" || true
fetch_called "$BACKOFF_HOME" && fail "an active backoff window should have skipped the refresh"

# =======================================================================
# Success path: cache is populated correctly from a 200 response --
# spend (enabled/used/limit/pct), five/seven windows with severity, and a
# computed monthly reset.
# =======================================================================
OK_HOME=$(fake_home 200 "$SUCCESS_BODY")
env HOME="$OK_HOME" bash "$SCRIPT" --force
CACHE="$OK_HOME/.claude/usage-cache.json"
[ -f "$CACHE" ] || fail "success path did not write usage-cache.json"
[ "$(jq -r '.enabled' "$CACHE")" = "true" ] || fail "spend.enabled not parsed"
[ "$(jq -r '.used' "$CACHE")" = "42.5" ] || fail "spend.used not parsed (amount_minor/exponent)"
[ "$(jq -r '.limit' "$CACHE")" = "100" ] || fail "spend.limit not parsed (amount_minor/exponent)"
[ "$(jq -r '.pct' "$CACHE")" = "42" ] || fail "spend.percent not parsed"
[ "$(jq -r '.five.util' "$CACHE")" = "20" ] || fail "five_hour.utilization not parsed"
[ "$(jq -r '.five.severity' "$CACHE")" = "normal" ] || fail "five severity (kind=session) not parsed"
[ "$(jq -r '.seven.util' "$CACHE")" = "3" ] || fail "seven_day.utilization not parsed"
[ "$(jq -r '.seven.severity' "$CACHE")" = "warning" ] || fail "seven severity (kind=weekly_all) not parsed"
RESETS=$(jq -r '.resets' "$CACHE")
[ -n "$RESETS" ] && [ "$RESETS" != "null" ] && [ "$RESETS" -gt "$(date +%s)" ] \
  || fail "computed credit reset should be a future epoch, got $RESETS"
[ ! -f "$OK_HOME/.claude/.usage-backoff" ] || fail "a successful refresh should clear any existing backoff"

# =======================================================================
# iso2epoch on a real BSD date (no GNU `-d` support): a resets_at with a
# trailing `Z` and no fractional seconds must still parse. This sandbox's
# own `date` is GNU-compatible (so `date -d` always succeeds and the BSD
# fallback path never runs for real), so a dedicated `date` stub forces
# that fallback and enforces BSD's actual constraint: `date -j -f` fails on
# any input with characters left over after the fixed format is consumed.
# Without stripping a lone trailing `Z` (no `.` present to trigger the
# existing fractional-seconds strip), this reproduces the real bug.
# =======================================================================
DATESTUB_HOME=$(fake_home 200 "$SUCCESS_BODY")
DATESTUB_DIR=$(mktemp -d "$SUITE_TMP/datestub.XXXXXX")
REAL_DATE=$(command -v date)
# REAL_DATE is substituted in below (unquoted heredoc); every other $ must
# stay literal for the stub's own shell to expand at run time, hence the
# backslash-escapes. Calling the stub's own name via PATH would recurse
# into itself forever (PATH still has this stub dir first) -- must invoke
# the real binary by its captured absolute path instead.
cat > "$DATESTUB_DIR/date" <<EOF
#!/usr/bin/env bash
# Minimal stand-in for BOTH GNU and real BSD date, dispatched by flag:
#   date -d <val> <fmt>   -> always fail (real BSD date has no -d at all)
#   date -jf <fmt> <val> +%s -> succeed ONLY if <val> exactly matches
#     "%Y-%m-%dT%H:%M:%S" with nothing left over (BSD's real behavior)
#   anything else (file_age's stat-less date calls, +%Y-%m-01 etc.) ->
#     delegate to the real system date so the rest of the script still works
case "\$1" in
  -d) exit 1 ;;
  -jf)
    fmt="\$2"; val="\$3"
    if [ "\$fmt" = "%Y-%m-%dT%H:%M:%S" ] && printf '%s' "\$val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\$'; then
      exec "$REAL_DATE" -u -d "\$val" +%s
    else
      echo "date: illegal time format" >&2
      exit 1
    fi
    ;;
  *) exec "$REAL_DATE" "\$@" ;;
esac
EOF
chmod +x "$DATESTUB_DIR/date"
env HOME="$DATESTUB_HOME" PATH="$DATESTUB_DIR:$PATH" bash "$SCRIPT" --force
DATESTUB_CACHE="$DATESTUB_HOME/.claude/usage-cache.json"
FIVE_RESETS=$(jq -r '.five.resets' "$DATESTUB_CACHE")
[ -n "$FIVE_RESETS" ] && [ "$FIVE_RESETS" != "null" ] \
  || fail "a Z-suffixed, no-fractional-seconds resets_at should still parse under BSD date (got five.resets=$FIVE_RESETS)"

# =======================================================================
# Throttle (429): backoff file is written with a future epoch, and the run
# exits non-zero without clobbering the prior cache.
# =======================================================================
THROTTLE_HOME=$(fake_home 429 "$SUCCESS_BODY")
echo '{"used":"prior"}' > "$THROTTLE_HOME/.claude/usage-cache.json"
set +e
env HOME="$THROTTLE_HOME" bash "$SCRIPT" --force
THROTTLE_EXIT=$?
set -e
[ "$THROTTLE_EXIT" -ne 0 ] || fail "a 429 response should exit non-zero"
[ "$(cat "$THROTTLE_HOME/.claude/usage-cache.json")" = '{"used":"prior"}' ] || fail "a 429 must leave the last-good cache untouched"
[ -f "$THROTTLE_HOME/.claude/.usage-backoff" ] || fail "a 429 should write a backoff cooldown"
BACKOFF_VAL=$(cat "$THROTTLE_HOME/.claude/.usage-backoff")
[ "$BACKOFF_VAL" -gt "$(date +%s)" ] || fail "backoff cooldown should be a future epoch, got $BACKOFF_VAL"

# =======================================================================
# Single-flight lock: a held (fresh) lock skips the refresh without error.
# =======================================================================
LOCK_HOME=$(fake_home 200 "$SUCCESS_BODY")
mkdir "$LOCK_HOME/.claude/.usage-refresh.lock"
env HOME="$LOCK_HOME" bash "$SCRIPT" --force
fetch_called "$LOCK_HOME" && fail "a held lock should have prevented the refresh from running"
rmdir "$LOCK_HOME/.claude/.usage-refresh.lock"

# =======================================================================
# Stale lock (>120s) is reclaimed rather than blocking forever, and the
# lock is released again after a successful run.
# =======================================================================
STALE_HOME=$(fake_home 200 "$SUCCESS_BODY")
mkdir "$STALE_HOME/.claude/.usage-refresh.lock"
set_mtime "$(($(date +%s) - 200))" "$STALE_HOME/.claude/.usage-refresh.lock"
env HOME="$STALE_HOME" bash "$SCRIPT" --force
fetch_called "$STALE_HOME" || fail "a stale (>120s) lock should have been reclaimed"
[ ! -d "$STALE_HOME/.claude/.usage-refresh.lock" ] || fail "lock should be released after a successful run"

echo "usage-refresh.test.sh: all assertions passed"
