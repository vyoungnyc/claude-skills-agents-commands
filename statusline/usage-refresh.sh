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
FRESH=600            # seconds; matches the status line's staleness gate
BACKOFF_THROTTLE=300 # 429: the server explicitly asked us to slow down
BACKOFF_ERROR=120    # any other failure (401, 5xx, unreachable, no token) — our own
                     # rate limiting, so kept short: bounded enough to stop a
                     # per-render storm, brief enough to recover quickly once fixed
# --force: bypass the FRESHNESS gate only — a login rotates the OAuth token and
# may change plan, so the cached values can be wrong however recently they were
# written. It deliberately does NOT bypass the throttle backoff. Those are two
# different things and conflating them was a real bug: the SessionStart hook
# runs this with --force, and SessionStart fires on every start/resume/clear,
# not just on an OAuth login, so during a 429 cooldown each staggered session
# would immediately drive another full retry cycle against the endpoint that
# just asked us to back off — precisely what the backoff exists to prevent.
# Still single-flight via the lock.
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# The cache exposes plan tier, credit spend/limit and 5h/7d utilization; the
# backoff file exposes throttle state. Keep them owner-only rather than whatever
# the ambient umask yields (observed 0644). Also covers the lock and temp files.
umask 077

now_epoch() { date +%s; }
# mtime age in seconds. The result is validated as NUMERIC rather than trusted
# on exit status: GNU `stat -f` means --file-system, so with GNU coreutils ahead
# of /usr/bin (common on macOS via Homebrew) the fallback exits ZERO and prints a
# multi-line filesystem report to stdout. `|| echo 0` therefore never fires, this
# function returns junk, and under `set -u` the arithmetic aborts and yields an
# EMPTY string -- which makes both lock guards below false and reclaims a lock
# whose owner is still running, defeating single-flight entirely.
file_age() {
    m=$(stat -c %Y "$1" 2>/dev/null)
    case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;; esac
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    echo $(($(now_epoch) - m))
}

# Single-flight across all Claude sessions: mkdir is atomic. The lock directory
# also records the holder's PID in an `owner` file, because a purely
# time-based staleness check is unsafe on BOTH sides of the critical section:
#   - Reclaiming: a refresh that legitimately runs longer than the threshold
#     has its LIVE lock removed, and a second fetch starts concurrently.
#   - Releasing: the original then exits and its unconditional `rmdir` trap
#     deletes whichever NEWER process now holds the lock, letting a third in —
#     and concurrent writers race on the cache temp file.
# So: reclaim only when the recorded owner is gone, and release only while we
# still own it. LOCK_HARD bounds the pathological case where the owner's PID
# was recycled by an unrelated live process, which would otherwise wedge the
# lock permanently. Bounding the fetch itself (curl --max-time below) is what
# keeps a healthy run from ever approaching these thresholds.
LOCK_GRACE=120  # lock exists but no owner recorded (killed between mkdir and write)
LOCK_HARD=3600  # owner looks alive but the lock is impossibly old -> assume PID reuse
lock_owner() { cat "$LOCK/owner" 2>/dev/null; }
lock_acquire() {
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s' "$$" >"$LOCK/owner" 2>/dev/null
        return 0
    fi
    # Held. Deciding "this lock is abandoned" and acting on it must happen under
    # mutual exclusion. Neither a plain `rm -rf` + `mkdir` nor an atomic rename
    # is enough: the lock is identified by PATH, not identity, so a contender
    # that decided "abandoned" a moment ago will happily tear down the BRAND-NEW
    # lock a winner has since created at that same path — putting both inside
    # the critical section. rename(2) only guarantees one rename of one
    # directory instance wins, which does not stop that.
    # So serialize the whole decide-and-reclaim on its own atomic mkdir, and
    # re-read the owner UNDER it: a process that reclaimed while we waited has
    # already recorded itself, so we then correctly see a LIVE owner and back off.
    local reclaim="$LOCK.reclaim"
    if ! mkdir "$reclaim" 2>/dev/null; then
        # Another process is reclaiming right now. It is held for only a few
        # filesystem operations, so anything older was abandoned mid-reclaim;
        # clear that and let the next run retry rather than race this one.
        [ "$(file_age "$reclaim")" -gt 60 ] && rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    local owner age
    owner=$(lock_owner)
    age=$(file_age "$LOCK")
    if { [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$age" -lt "$LOCK_HARD" ]; } \
       || { [ -z "$owner" ] && [ "$age" -lt "$LOCK_GRACE" ]; }; then
        rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    rm -rf "$LOCK" 2>/dev/null
    # A fast-path acquirer can slip in between the rm and this mkdir. If it did,
    # our mkdir fails and it owns the lock -- we must NOT write our own owner
    # over theirs.
    if ! mkdir "$LOCK" 2>/dev/null; then
        rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    printf '%s' "$$" >"$LOCK/owner" 2>/dev/null
    rmdir "$reclaim" 2>/dev/null
    return 0
}
lock_release() {
    [ "$(lock_owner)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
    return 0
}
lock_acquire || exit 0
trap lock_release EXIT

# Re-check under the lock: another session may have just refreshed (freshness gate),
# or the endpoint may have throttled us (backoff gate). Either way, do nothing —
# this is what stops N sessions from each hitting the endpoint.
# --force skips only the freshness gate; see the note on FORCE above for why the
# backoff gate is NOT skippable.
if [ "$FORCE" -eq 0 ]; then
    [ -f "$CACHE" ] && [ "$(file_age "$CACHE")" -lt "$FRESH" ] && exit 0
fi
# The backoff file is "<until_epoch> <kind>", kind being `throttle` (a 429 — the
# server explicitly told us to slow down) or `error` (401/5xx/unreachable/no
# token — our OWN rate limiting, not an instruction from the server). A file with
# no kind was written by an older version; read it as `throttle`, the
# conservative choice.
#
# --force may bypass an `error` cooldown but never a `throttle` one. That split
# is the point: a 429 must be honored no matter who is asking, whereas a login
# is precisely the event that fixes a 401, so making --force wait out an
# error cooldown would leave the status line stale right after the user fixed
# the underlying problem.
if [ -f "$BACKOFF" ]; then
    read -r bo_until bo_kind < "$BACKOFF" 2>/dev/null || true
    [ -z "${bo_kind:-}" ] && bo_kind="throttle"
    if [ "$(now_epoch)" -lt "${bo_until:-0}" ] 2>/dev/null; then
        if [ "$bo_kind" = "throttle" ] || [ "$FORCE" -eq 0 ]; then
            exit 0
        fi
    fi
fi

# set_backoff <seconds> <kind> — plain arithmetic on the epoch rather than
# `date -d "+5 min"` / `date -v+5M`, which needed a GNU/BSD fallback pair.
set_backoff() {
    printf '%s %s\n' "$(( $(now_epoch) + $1 ))" "$2" >"$BACKOFF" 2>/dev/null
}

# A failure must ALWAYS record a cooldown, not just a 429. Otherwise the cache
# stays stale, statusline-command.sh sees it as stale and relaunches this script
# on every ~30s render, and each run drives fetch-usage.sh's full three-attempt
# retry cycle against an endpoint that is already failing. A persistent 401
# (revoked token) or a 5xx outage would be hammered indefinitely.
# fetch-usage.sh exiting nonzero (no token found, curl unusable) is the same
# situation and gets the same treatment.
if ! raw=$("$DIR/fetch-usage.sh" 2>/dev/null); then
    set_backoff "$BACKOFF_ERROR" error
    exit 1
fi
status=$(printf '%s' "$raw" | sed -n 's/^__HTTP_STATUS__//p')
body=$(printf '%s' "$raw" | sed '/^__HTTP_STATUS__/d')
# On failure keep the last-good cache and set a cooldown so the status line stops
# re-triggering refreshes until it passes.
if [ "$status" != "200" ]; then
    if [ "$status" = "429" ]; then
        set_backoff "$BACKOFF_THROTTLE" throttle
    else
        set_backoff "$BACKOFF_ERROR" error
    fi
    exit 1
fi
# NOTE: the backoff is deliberately NOT cleared here. A 200 whose body cannot be
# parsed or written still leaves the cache stale, and clearing the cooldown at
# this point meant statusline-command.sh relaunched the refresh on every ~30s
# render with nothing to stop it. The cooldown is cleared only after the cache
# has actually been written, at the very bottom of this script.

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
five_util=$(printf '%s' "$body" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
five_reset=$(iso2epoch "$(printf '%s' "$body" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)")
five_sev=$(printf '%s' "$body" | jq -r '(.limits[]? | select(.kind=="session") | .severity) // empty' 2>/dev/null | head -1)
seven_util=$(printf '%s' "$body" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
seven_reset=$(iso2epoch "$(printf '%s' "$body" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)")
seven_sev=$(printf '%s' "$body" | jq -r '(.limits[]? | select(.kind=="weekly_all") | .severity) // empty' 2>/dev/null | head -1)

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
    }' >"$CACHE.tmp.$$" 2>/dev/null || {
    # A 200 whose body is malformed, or an unexpected field that makes tonumber
    # fail, lands here. Treat it as an error failure: record a cooldown so the
    # status line stops relaunching us every render, drop the partial temp file,
    # and leave the last-good cache in place.
    rm -f "$CACHE.tmp.$$" 2>/dev/null
    set_backoff "$BACKOFF_ERROR" error
    exit 1
}
mv "$CACHE.tmp.$$" "$CACHE" 2>/dev/null || {
    rm -f "$CACHE.tmp.$$" 2>/dev/null
    set_backoff "$BACKOFF_ERROR" error
    exit 1
}
# Cache written: only now is the endpoint known to be fully healthy, so clear
# any cooldown.
rm -f "$BACKOFF" 2>/dev/null
