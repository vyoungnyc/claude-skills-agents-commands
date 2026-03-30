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

_CLEANUP_PATHS=()

_cleanup() {
  for p in "${_CLEANUP_PATHS[@]}"; do
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

acquire_pidfile() {
  local pidfile="$1"
  register_cleanup "$pidfile"

  if [ -f "$pidfile" ]; then
    local old_pid
    old_pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
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
  echo $$ > "$pidfile"
}

# Set difference: IDs in $1 not in $2 (both pre-sorted, one per line).
# Sets $_NEW_COUNT. Outputs new IDs to stdout.
find_new_ids() {
  local all_ids="$1" known_ids="$2"
  if [ -z "$known_ids" ]; then
    _NEW_COUNT=$(echo "$all_ids" | grep -c . 2>/dev/null || echo 0)
    echo "$all_ids"
    return
  fi
  local result
  result=$(comm -23 <(echo "$all_ids") <(echo "$known_ids") 2>/dev/null | grep .)
  _NEW_COUNT=$(echo "$result" | grep -c . 2>/dev/null || echo 0)
  echo "$result"
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
