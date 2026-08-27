#!/usr/bin/env bash
# Refresh the API-usage credit cache read by the status line.
# Calls fetch-usage.sh, parses spend, computes the monthly reset (1st of next month),
# writes ~/.claude/usage-cache.json atomically. Safe to run on a timer or on-demand.
set -uo pipefail
# Which Claude home this script was DEPLOYED into — the cache, backoff, lock,
# and the fetch-usage.sh helper all live beside this script, so an install
# under an alternate CLAUDE_HOME must not read/write the DEFAULT home's files
# (or look for its helper somewhere it was never installed). Same resolution
# order as statusline-command.sh: explicit CLAUDE_HOME, else this script's own
# directory when a sibling settings.json marks it as a deployed Claude home,
# else $HOME/.claude (default install, and the repo checkout).
resolve_claude_home() {
    if [ -n "${CLAUDE_HOME:-}" ]; then printf '%s' "$CLAUDE_HOME"; return; fi
    local d
    d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || d=""
    if [ -n "$d" ] && [ -f "$d/settings.json" ]; then printf '%s' "$d"; return; fi
    printf '%s' "$HOME/.claude"
}
DIR=$(resolve_claude_home)
CACHE="$DIR/usage-cache.json"
BACKOFF="$DIR/.usage-backoff"
LOCK="$DIR/.usage-refresh.lock"
FRESH=600 # seconds; matches the status line's staleness gate
# --force (used on login): bypass the freshness gate and backoff, since login rotates
# the OAuth token / may change plan. Still single-flight via the lock.
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

now_epoch() { date +%s; }
file_age() {
    m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
    echo $(($(now_epoch) - m))
}

# Single-flight across all Claude sessions: mkdir is atomic. If another refresh holds
# the lock, exit quietly. Clear a stale lock (>120s = a crashed/hung refresh).
[ -d "$LOCK" ] && [ "$(file_age "$LOCK")" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Re-check under the lock: another session may have just refreshed, or a throttle backoff
# may be active — in either case do nothing (avoids N sessions each hitting the endpoint).
# --force skips both gates (login), but still honors the lock's single-flight.
if [ "$FORCE" -eq 0 ]; then
    [ -f "$CACHE" ] && [ "$(file_age "$CACHE")" -lt "$FRESH" ] && exit 0
    if [ -f "$BACKOFF" ]; then
        bo=$(cat "$BACKOFF" 2>/dev/null || echo 0)
        [ "$(now_epoch)" -lt "${bo:-0}" ] 2>/dev/null && exit 0
    fi
fi

raw=$("$DIR/fetch-usage.sh" 2>/dev/null) || exit 1
status=$(printf '%s' "$raw" | sed -n 's/^__HTTP_STATUS__//p')
body=$(printf '%s' "$raw" | sed '/^__HTTP_STATUS__/d')
# On failure keep the last-good cache and, if throttled, set a cooldown so the status
# line stops re-triggering refreshes until it passes (avoids worsening the throttle).
if [ "$status" != "200" ]; then
    if [ "$status" = "429" ]; then
        date -d "+5 min" +%s 2>/dev/null >"$BACKOFF" || date -v+5M +%s 2>/dev/null >"$BACKOFF"
    fi
    exit 1
fi
rm -f "$BACKOFF" 2>/dev/null

# credits reset on the 1st of next month (local time)
resets=$(date -d "$(date +%Y-%m-01) +1 month" +%s 2>/dev/null) \
    || resets=$(date -v1d -v+1m -v0H -v0M -v0S +%s 2>/dev/null) \
    || resets=""

# ISO-8601 -> epoch (GNU date first, BSD fallback).
# BSD `date -j -f` requires an exact match against a fixed format, so the zone
# suffix has to come off the string before parsing — but DELETING it is not
# harmless: `date -j -f "%Y-%m-%dT%H:%M:%S"` then reads the remaining wall
# clock in the machine's LOCAL timezone, so on any host outside UTC a
# `...T18:00:00Z` reset lands off by the local UTC offset (4h out in EDT) and
# the status line shows the wrong reset time. Split the zone off and parse it
# explicitly instead: `Z` -> `-u` (read as UTC), a numeric offset -> a matching
# `%z` directive, no zone at all -> local time, which is the correct reading of
# a zone-less stamp. Fractional seconds are stripped only AFTER the zone is
# removed — `${v%%.*}` cuts from the first dot to the END of the string, so
# doing it first would swallow an offset that follows the fraction.
iso2epoch() {
    [ -z "${1:-}" ] && return
    date -d "$1" +%s 2>/dev/null && return
    local raw="$1" zone="" utc=0
    case "$raw" in
    *Z)
        raw="${raw%Z}"; utc=1 ;;
    *[+-][0-9][0-9]:[0-9][0-9])
        zone="${raw: -6}"; raw="${raw%??????}"
        zone="${zone%:*}${zone#*:}" ;;  # +HH:MM -> +HHMM, which %z expects
    esac
    raw="${raw%%.*}"
    if [ "$utc" -eq 1 ]; then
        date -u -j -f "%Y-%m-%dT%H:%M:%S" "$raw" +%s 2>/dev/null && return
    elif [ -n "$zone" ]; then
        date -j -f "%Y-%m-%dT%H:%M:%S%z" "$raw$zone" +%s 2>/dev/null && return
    else
        date -j -f "%Y-%m-%dT%H:%M:%S" "$raw" +%s 2>/dev/null && return
    fi
}

# 5h / 7d rate-limit windows come from the SAME endpoint (null unless on Max/Pro).
# severity ("normal"/"warning"/"critical") lives in the limits[] array keyed by kind
# (session == 5h, weekly_all == 7d); fall back to null when absent.
five_util=$(printf '%s' "$body" | jq -r '.five_hour.utilization // empty')
five_reset=$(iso2epoch "$(printf '%s' "$body" | jq -r '.five_hour.resets_at // empty')")
five_sev=$(printf '%s' "$body" | jq -r '(.limits[]? | select(.kind=="session") | .severity) // empty' | head -1)
seven_util=$(printf '%s' "$body" | jq -r '.seven_day.utilization // empty')
seven_reset=$(iso2epoch "$(printf '%s' "$body" | jq -r '.seven_day.resets_at // empty')")
seven_sev=$(printf '%s' "$body" | jq -r '(.limits[]? | select(.kind=="weekly_all") | .severity) // empty' | head -1)

printf '%s' "$body" | jq \
    --arg resets "$resets" \
    --arg fu "$five_util" --arg fr "$five_reset" --arg fsev "$five_sev" \
    --arg su "$seven_util" --arg sr "$seven_reset" --arg ssev "$seven_sev" '
    def num($s): if $s == "" then null else ($s | tonumber) end;
    def str($s): if $s == "" then null else $s end;
    {
        enabled: (.spend.enabled // (.extra_usage.is_enabled // false)),
        used:  ((.spend.used.amount_minor  // 0) / pow(10; (.spend.used.exponent  // 0))),
        limit: ((.spend.limit.amount_minor // 0) / pow(10; (.spend.limit.exponent // 0))),
        pct:   (.spend.percent // (.extra_usage.utilization // 0) | floor),
        severity: (.spend.severity // null),
        resets: num($resets),
        five:  (if $fu == "" then null else {util: ($fu | tonumber | floor), resets: num($fr), severity: str($fsev)} end),
        seven: (if $su == "" then null else {util: ($su | tonumber | floor), resets: num($sr), severity: str($ssev)} end)
    }' >"$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"
