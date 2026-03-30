#!/bin/bash
# Poll a GitLab MR for new review discussions, approval status, award emoji, or idle timeout.
# Used by /mr-fix-loop to avoid generating inline polling scripts.
#
# Usage: poll-mr-reviews.sh <mr_iid> [poll_interval_sec] [max_polls]
#
# Requires: glab CLI authenticated and inside a git repo with a GitLab remote.
#
# Exit codes:
#   0 — APPROVED (MR formally approved or bot reacted with thumbsup/white_check_mark)
#   1 — NEW_COMMENTS (unresolved resolvable discussions detected)
#   2 — IDLE_TIMEOUT (no new comments within max polling window)
#   3 — PIPELINE_FAILED (pipeline has failed jobs)
#   10 — Usage error
#
# Output: JSON on stdout describing the stop condition and relevant details.

set -euo pipefail

MR_IID="${1:-}"
POLL_INTERVAL="${2:-60}"
MAX_POLLS="${3:-15}"

if [ -z "$MR_IID" ]; then
  echo '{"error": "Usage: poll-mr-reviews.sh <mr_iid> [poll_interval_sec] [max_polls]"}' >&2
  exit 10
fi

# --- PID file: kill any previous polling instance ---
# Derive a project identifier from the git remote for uniqueness
PROJECT_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's|.*[:/](.+)(\.git)?$|\1|' | tr '/' '-')
PIDFILE="/tmp/poll-mr-reviews-${PROJECT_SLUG}-${MR_IID}.pid"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    echo "[$(date +"%H:%M:%S")] Killed previous polling instance (PID $OLD_PID)" >&2
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Known bot username patterns (case-insensitive match)
BOT_PATTERNS="bot|duo|codex|cursor|bugbot"

# Snapshot unresolved discussion IDs at startup so we only report truly NEW discussions.
# Discussions that are already unresolved (e.g. disputed/needs-clarification) are "known".
KNOWN_DISC_IDS=$(glab api "projects/:id/merge_requests/$MR_IID/discussions" 2>/dev/null | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | .id] | sort | join("\n")')

POLL=0
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  sleep "$POLL_INTERVAL"

  # --- Check MR approval status (primary gate) ---
  APPROVALS=$(glab api "projects/:id/merge_requests/$MR_IID/approvals" 2>/dev/null || echo '{}')
  IS_APPROVED=$(echo "$APPROVALS" | jq '.approved // false')
  APPROVALS_LEFT=$(echo "$APPROVALS" | jq '.approvals_left // -1')

  if [ "$IS_APPROVED" = "true" ] || [ "$APPROVALS_LEFT" = "0" ]; then
    APPROVED_BY=$(echo "$APPROVALS" | jq '[.approved_by[]? | .user.username]')
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"native_approval\", \"approved_by\": $APPROVED_BY}"
    exit 0
  fi

  # --- Check award emoji on MR (secondary gate) ---
  EMOJI=$(glab api "projects/:id/merge_requests/$MR_IID/award_emoji" 2>/dev/null || echo '[]')
  BOT_APPROVAL_COUNT=$(echo "$EMOJI" | jq "[
    .[]
    | select(.name == \"thumbsup\" or .name == \"white_check_mark\")
    | select(.user.username | test(\"$BOT_PATTERNS\"; \"i\"))
  ] | length")

  if [ "$BOT_APPROVAL_COUNT" -gt 0 ]; then
    BOT_APPROVERS=$(echo "$EMOJI" | jq "[
      .[]
      | select(.name == \"thumbsup\" or .name == \"white_check_mark\")
      | select(.user.username | test(\"$BOT_PATTERNS\"; \"i\"))
      | {user: .user.username, emoji: .name}
    ]")
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"award_emoji\", \"approvers\": $BOT_APPROVERS}"
    exit 0
  fi

  # --- Check for NEW unresolved resolvable discussions (exclude known/stale ones) ---
  DISCUSSIONS=$(glab api "projects/:id/merge_requests/$MR_IID/discussions" 2>/dev/null || echo '[]')
  ALL_UNRESOLVED_IDS=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | .id] | sort | join("\n")')
  NEW_IDS=""
  while IFS= read -r did; do
    [ -z "$did" ] && continue
    if ! echo "$KNOWN_DISC_IDS" | grep -qF "$did"; then
      NEW_IDS="${NEW_IDS}${did}\n"
    fi
  done <<< "$ALL_UNRESOLVED_IDS"

  if [ -n "$NEW_IDS" ]; then
    NEW_ID_LIST=$(printf '%s' "$NEW_IDS" | sed '/^$/d' | jq -R . | jq -s .)
    UNRESOLVED=$(echo "$DISCUSSIONS" | jq --argjson ids "$NEW_ID_LIST" '[
      .[]
      | select(.notes[0].resolvable == true and .notes[0].resolved == false)
      | select(.id as $did | $ids | index($did))
      | {
          id: .id,
          author: .notes[0].author.username,
          path: (.notes[0].position.new_path // null),
          line: (.notes[0].position.new_line // null),
          body: (.notes[0].body | .[0:200]),
          created: .notes[0].created_at
        }
    ]')
    UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | jq 'length')
    echo "{\"status\": \"NEW_COMMENTS\", \"poll\": $POLL, \"count\": $UNRESOLVED_COUNT, \"discussions\": $UNRESOLVED}"
    exit 1
  fi

  # --- Check pipeline status ---
  PIPELINES=$(glab api "projects/:id/merge_requests/$MR_IID/pipelines" 2>/dev/null || echo '[]')
  LATEST_STATUS=$(echo "$PIPELINES" | jq -r '.[0].status // "unknown"')

  if [ "$LATEST_STATUS" = "failed" ]; then
    PIPELINE_ID=$(echo "$PIPELINES" | jq '.[0].id')
    echo "{\"status\": \"PIPELINE_FAILED\", \"poll\": $POLL, \"pipeline_id\": $PIPELINE_ID, \"pipeline_status\": \"$LATEST_STATUS\"}"
    exit 3
  fi

  echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval yet (pipeline: $LATEST_STATUS)" >&2
done

echo "{\"status\": \"IDLE_TIMEOUT\", \"polls_completed\": $MAX_POLLS, \"total_seconds\": $((MAX_POLLS * POLL_INTERVAL))}"
exit 2
