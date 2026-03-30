#!/bin/bash
# Shared functions for poll-pr-reviews.sh and poll-mr-reviews.sh.
# Source this file: source "${BASH_SOURCE[0]%/*}/lib/poll-common.sh"

# Exit code constants
EXIT_APPROVED=0
EXIT_NEW_COMMENTS=1
EXIT_IDLE_TIMEOUT=2
EXIT_BLOCKED_ON_HUMAN_PR=3
EXIT_PIPELINE_FAILED=3
EXIT_BLOCKED_ON_HUMAN_MR=4
EXIT_USAGE_ERROR=10
EXIT_SNAPSHOT_FAILURE=11

# Global cleanup list
_CLEANUP_FILES=()

_cleanup() {
  for f in "${_CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
}
trap _cleanup EXIT INT TERM

register_cleanup() {
  _CLEANUP_FILES+=("$1")
}

# Validate that a value is a positive integer, exit 10 if not.
# Usage: require_positive_int "$value" "variable_name"
require_positive_int() {
  local val="$1" name="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
    echo "{\"error\": \"$name must be a positive integer\"}" >&2
    exit $EXIT_USAGE_ERROR
  fi
}

# Acquire a PID file, killing any previous holder.
# Usage: acquire_pidfile "/tmp/my-poller.pid"
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

# Compute new IDs: IDs in $1 (one-per-line) that are NOT in $2 (one-per-line).
# Outputs new IDs to stdout (one per line). Returns count via $_NEW_COUNT.
# Usage: NEW_IDS=$(find_new_ids "$all_ids" "$known_ids"); echo "$_NEW_COUNT new"
find_new_ids() {
  local all_ids="$1" known_ids="$2"
  if [ -z "$known_ids" ]; then
    _NEW_COUNT=$(echo "$all_ids" | grep -c . 2>/dev/null || echo 0)
    echo "$all_ids"
    return
  fi
  local result
  result=$(comm -23 <(echo "$all_ids" | sort) <(echo "$known_ids" | sort) 2>/dev/null | grep .)
  _NEW_COUNT=$(echo "$result" | grep -c . 2>/dev/null || echo 0)
  echo "$result"
}

# Check if any ID in $1 also exists in $2 (set intersection is non-empty).
# Returns 0 (true) if intersection exists, 1 (false) otherwise.
has_known_ids() {
  local all_ids="$1" known_ids="$2"
  [ -z "$all_ids" ] && return 1
  [ -z "$known_ids" ] && return 1
  local common
  common=$(comm -12 <(echo "$all_ids" | sort) <(echo "$known_ids" | sort) 2>/dev/null | head -1)
  [ -n "$common" ]
}
