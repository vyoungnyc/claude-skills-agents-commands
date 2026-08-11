#!/bin/bash
# Shared functions for poll-pr-reviews.sh and poll-mr-reviews.sh.
# Source this file: source "${BASH_SOURCE[0]%/*}/lib/poll-common.sh"

# Exit codes — no collisions across scripts
EXIT_APPROVED=0
EXIT_NEW_COMMENTS=1
EXIT_IDLE_TIMEOUT=2
EXIT_BLOCKED_ON_HUMAN=3
EXIT_PIPELINE_FAILED=4
EXIT_USAGE_ERROR=10
EXIT_SNAPSHOT_FAILURE=11

STALE_POLLS=0
BLOCKED_THRESHOLD=3

# Base bot patterns shared across platforms. Scripts append platform-specific entries.
# Bracket literals are written as character classes ([[] and []]) rather than
# backslash escapes: this string is interpolated into a jq program inside a JSON
# string literal, where \[ is not a valid escape and fails to compile.
#
# `-bot$` (end-anchored) rather than the previous unanchored `-bot-`: the
# unanchored form matched any login containing "-bot-" anywhere, so a
# malicious or spoofed login like "mallory-bot-reviewer" would satisfy the
# bot-approval gate. End-anchoring restricts it to logins that actually end
# in "-bot" (e.g. "dependabot-bot"-style names), matching the intent of the
# other anchored patterns in this list.
BASE_BOT_PATTERNS="[[]bot[]]$|-bot$|^chatgpt-codex|^cursor-bugbot"

_CLEANUP_PATHS=()

_cleanup() {
  # ${arr[@]+"${arr[@]}"} — expands to nothing when the array is empty. A bare
  # "${arr[@]}" on an empty array is an unbound-variable error under bash 3.2 +
  # set -u, which fires from the EXIT trap on every pre-register_cleanup exit.
  for p in ${_CLEANUP_PATHS[@]+"${_CLEANUP_PATHS[@]}"}; do
    rm -rf "$p"
  done
}
trap _cleanup EXIT INT TERM

register_cleanup() {
  _CLEANUP_PATHS+=("$1")
}

require_positive_int() {
  local val="$1" name="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
    echo "{\"error\": \"$name must be a positive integer\"}" >&2
    exit $EXIT_USAGE_ERROR
  fi
}

# Process start time as reported by `ps`, used as a cheap identity token
# alongside a PID: the OS recycles PIDs, so a bare PID read back from a
# pidfile is not enough to know it still names the same process instance.
# Pairing it with the start time it had when we recorded it is the standard
# PID-reuse-safe identity check (same technique used by pidfile-based
# supervisors); no /proc parsing needed since `ps -o lstart=` works
# identically on this repo's macOS/bash-3.2 target and on Linux.
_pid_start_time() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

acquire_pidfile() {
  local pidfile="$1"
  register_cleanup "$pidfile"

  if [ -f "$pidfile" ]; then
    local raw old_pid old_start
    raw=$(cat "$pidfile" 2>/dev/null || true)
    old_pid="${raw%%:*}"
    if [ "$raw" = "$old_pid" ]; then
      # No "pid:start_time" separator — a pidfile from before this identity
      # check existed, or one written by something other than this function
      # (including one pre-created by an attacker on a shared host, since the
      # path is fully predictable from owner/name/pr). With no start time to
      # verify identity against, treat it as untrusted rather than falling
      # back to an unconditional kill: a colon-less pidfile no longer has a
      # legitimate source going forward, since every write from this function
      # uses the "pid:start_time" format. Do not kill; just warn and move on
      # to overwrite it with a fresh identity-tagged pidfile below.
      old_start=""
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[$(date +"%H:%M:%S")] Pidfile has no identity token, not killing (PID $old_pid)" >&2
      fi
    else
      old_start="${raw#*:}"

      # Before signaling a PID read from a pidfile, confirm it's still the
      # same process instance rather than blindly killing whatever now holds
      # that PID — PIDs are recycled by the OS, so a stale pidfile can point
      # at an unrelated process by the time we get around to reading it. An
      # unrelated process that happens to have been assigned the same PID
      # will almost certainly have a different start time and is left alone.
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        if [ "$(_pid_start_time "$old_pid")" = "$old_start" ]; then
          kill "$old_pid" 2>/dev/null || true
          local i
          for i in 1 2 3; do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 1
          done
          kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null || true
          echo "[$(date +"%H:%M:%S")] Killed previous polling instance (PID $old_pid)" >&2
        fi
      fi
    fi
  fi
  echo "$$:$(_pid_start_time "$$")" > "$pidfile"
}

# Set difference: IDs in $1 not in $2 (both pre-sorted, one per line).
# Pure: outputs the new IDs to stdout and sets nothing. Callers capture the
# output and derive the count with count_ids — an assignment made here would be
# lost, since every call site is a command substitution (its own subshell).
find_new_ids() {
  local all_ids="$1" known_ids="$2"
  if [ -z "$all_ids" ]; then
    return
  fi
  if [ -z "$known_ids" ]; then
    echo "$all_ids"
    return
  fi
  comm -23 <(echo "$all_ids") <(echo "$known_ids") 2>/dev/null | grep . || true
}

# Count non-empty lines in $1. Echoes 0 for empty input.
# grep -c exits 1 when nothing matches, hence the || true.
count_ids() {
  printf '%s' "$1" | grep -c . 2>/dev/null || true
}

# Returns 0 if any ID in $1 also exists in $2 (both pre-sorted).
has_known_ids() {
  local all_ids="$1" known_ids="$2"
  [ -z "$all_ids" ] && return 1
  [ -z "$known_ids" ] && return 1
  local common
  common=$(comm -12 <(echo "$all_ids") <(echo "$known_ids") 2>/dev/null | head -1)
  [ -n "$common" ]
}

emit_idle_timeout() {
  echo "{\"status\": \"IDLE_TIMEOUT\", \"polls_completed\": $MAX_POLLS, \"total_seconds\": $((MAX_POLLS * POLL_INTERVAL))}"
  exit $EXIT_IDLE_TIMEOUT
}
