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
# iso2epoch on a real BSD date (no GNU `-d` support). This sandbox's own
# `date` is GNU-compatible (so `date -d` always succeeds and the BSD
# fallback never runs for real), so a `date` stub forces that fallback and
# enforces BSD's actual behavior:
#   - `date -j -f` fails on any input with characters left over after the
#     fixed format is consumed (so a trailing `Z` must be handled, not left
#     in place), AND
#   - a zone-less wall clock is read in the machine's LOCAL timezone unless
#     `-u` is passed. The stub therefore honors `-u` rather than forcing it:
#     forcing it (as this stub used to) hides a missing `-u` in the script.
# The suite runs under a deliberately non-UTC TZ and asserts the exact
# epoch, so a local-time misparse shows up as a concrete offset error
# instead of merely "something non-null was parsed".
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
# Minimal stand-in for BOTH GNU and real BSD date:
#   date -d <val> <fmt>          -> always fail (real BSD date has no -d)
#   [-u] -j -f <fmt> <val> +%s   -> parse, mimicking BSD strptime strictness:
#     succeeds only if <val> exactly matches <fmt>, and interprets a
#     zone-less stamp as LOCAL time unless -u was given (BSD's real rule --
#     NOT silently as UTC). "%...%z" consumes a trailing +HHMM offset.
#   anything else (file_age's date calls, +%Y-%m-01 etc.) -> real date
utc=0
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -u) utc=1; shift ;;
    -d) exit 1 ;;
    -j) shift ;;
    -jf) args+=(-f "\$2"); shift 2 ;;
    -f) args+=(-f "\$2"); shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
# args is now: -f <fmt> <val> +%s   (or an unrelated real-date invocation)
if [ "\${args[0]:-}" = "-f" ]; then
  fmt="\${args[1]}"; val="\${args[2]}"
  case "\$fmt" in
    "%Y-%m-%dT%H:%M:%S")
      printf '%s' "\$val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\$' || {
        echo "date: illegal time format" >&2; exit 1; }
      if [ "\$utc" -eq 1 ]; then exec "$REAL_DATE" -u -d "\$val" +%s
      else exec "$REAL_DATE" -d "\$val" +%s; fi ;;
    "%Y-%m-%dT%H:%M:%S%z")
      printf '%s' "\$val" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\$' || {
        echo "date: illegal time format" >&2; exit 1; }
      exec "$REAL_DATE" -d "\$val" +%s ;;
    *) echo "date: illegal time format" >&2; exit 1 ;;
  esac
fi
exec "$REAL_DATE" "\${args[@]}"
EOF
chmod +x "$DATESTUB_DIR/date"
# A non-UTC TZ: under the bug (no -u), the Z-suffixed stamp parses as local
# wall clock and the epoch comes out shifted by the UTC offset.
export TZ="America/New_York"
env HOME="$DATESTUB_HOME" PATH="$DATESTUB_DIR:$PATH" TZ="$TZ" bash "$SCRIPT" --force
DATESTUB_CACHE="$DATESTUB_HOME/.claude/usage-cache.json"
FIVE_RESETS=$(jq -r '.five.resets' "$DATESTUB_CACHE")
[ -n "$FIVE_RESETS" ] && [ "$FIVE_RESETS" != "null" ] \
  || fail "a Z-suffixed, no-fractional-seconds resets_at should still parse under BSD date (got five.resets=$FIVE_RESETS)"
# SUCCESS_BODY's five_hour.resets_at is 2026-08-26T18:00:00Z -- a UTC instant,
# so the epoch must not depend on the machine's timezone at all.
EXPECT_FIVE=$(date -u -d "2026-08-26T18:00:00" +%s 2>/dev/null || date -ju -f "%Y-%m-%dT%H:%M:%S" "2026-08-26T18:00:00" +%s)
[ "$FIVE_RESETS" = "$EXPECT_FIVE" ] \
  || fail "a Z-suffixed resets_at must be read as UTC, not local wall clock: expected $EXPECT_FIVE, got $FIVE_RESETS (off by $((FIVE_RESETS - EXPECT_FIVE))s = the local UTC offset)"
SEVEN_RESETS=$(jq -r '.seven.resets' "$DATESTUB_CACHE")
EXPECT_SEVEN=$(date -u -d "2026-08-31T18:00:00" +%s 2>/dev/null || date -ju -f "%Y-%m-%dT%H:%M:%S" "2026-08-31T18:00:00" +%s)
[ "$SEVEN_RESETS" = "$EXPECT_SEVEN" ] \
  || fail "seven_day resets_at must be read as UTC: expected $EXPECT_SEVEN, got $SEVEN_RESETS"
unset TZ

# A resets_at carrying a NUMERIC offset (not Z) must keep that offset's
# meaning too, rather than being parsed as local wall clock.
OFFSET_BODY='{
  "spend": {"enabled": true, "used": {"amount_minor": 0, "exponent": 2}, "limit": {"amount_minor": 100, "exponent": 2}, "percent": 0, "severity": "normal"},
  "five_hour": {"utilization": 20, "resets_at": "2026-08-26T20:00:00+02:00"},
  "seven_day": {"utilization": 3, "resets_at": "2026-08-31T18:00:00Z"},
  "limits": []
}'
OFFSET_HOME=$(fake_home 200 "$OFFSET_BODY")
export TZ="America/New_York"
env HOME="$OFFSET_HOME" PATH="$DATESTUB_DIR:$PATH" TZ="$TZ" bash "$SCRIPT" --force
OFFSET_FIVE=$(jq -r '.five.resets' "$OFFSET_HOME/.claude/usage-cache.json")
# 20:00+02:00 is the same instant as 18:00Z.
[ "$OFFSET_FIVE" = "$EXPECT_FIVE" ] \
  || fail "a numeric-offset resets_at must preserve its offset (20:00+02:00 == 18:00Z): expected $EXPECT_FIVE, got $OFFSET_FIVE"
unset TZ

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

# =======================================================================
# Regression: an install under an alternate CLAUDE_HOME must invoke the
# fetch-usage.sh deployed BESIDE IT and write its cache there -- not reach
# into the default $HOME/.claude, where an alternate-only install has no
# helper at all (so usage never refreshed). Both homes get a stub helper
# here, each tagging its own marker file, so the assertion proves which
# one actually ran.
# =======================================================================
ALT_DEPLOY=$(mktemp -d "$SUITE_TMP/alt-deploy.XXXXXX")
cp "$SCRIPT" "$ALT_DEPLOY/usage-refresh.sh"
echo '{}' > "$ALT_DEPLOY/settings.json"   # the marker that says "deployed Claude home"
cat > "$ALT_DEPLOY/fetch-usage.sh" <<EOF
#!/usr/bin/env bash
touch "$ALT_DEPLOY/alt-fetch-called"
cat <<'BODY'
$SUCCESS_BODY
BODY
printf '__HTTP_STATUS__%s\n' 200
EOF
chmod +x "$ALT_DEPLOY/fetch-usage.sh"
ALTDEFAULT_HOME=$(fake_home 200 "$SUCCESS_BODY")
env HOME="$ALTDEFAULT_HOME" bash "$ALT_DEPLOY/usage-refresh.sh" --force
[ -f "$ALT_DEPLOY/alt-fetch-called" ] || fail "an alternate-home install must invoke the fetch-usage.sh deployed beside it"
fetch_called "$ALTDEFAULT_HOME" && fail "an alternate-home install must NOT invoke the default \$HOME/.claude helper"
[ -f "$ALT_DEPLOY/usage-cache.json" ] || fail "an alternate-home install must write its cache beside itself"
[ "$(jq -r '.pct' "$ALT_DEPLOY/usage-cache.json")" = "42" ] || fail "alternate-home cache content mismatch"
[ ! -f "$ALTDEFAULT_HOME/.claude/usage-cache.json" ] || fail "an alternate-home install must not write into the default \$HOME/.claude"

# Without a sibling settings.json the copied script is not a deployed Claude
# home and must fall back to $HOME/.claude (the repo-checkout case).
NOMARKER_DEPLOY=$(mktemp -d "$SUITE_TMP/nomarker.XXXXXX")
cp "$SCRIPT" "$NOMARKER_DEPLOY/usage-refresh.sh"
NOMARKER_HOME=$(fake_home 200 "$SUCCESS_BODY")
env HOME="$NOMARKER_HOME" bash "$NOMARKER_DEPLOY/usage-refresh.sh" --force
fetch_called "$NOMARKER_HOME" || fail "without a sibling settings.json the script must fall back to \$HOME/.claude"
[ -f "$NOMARKER_HOME/.claude/usage-cache.json" ] || fail "fallback run should have written the default-home cache"

echo "usage-refresh.test.sh: all assertions passed"
