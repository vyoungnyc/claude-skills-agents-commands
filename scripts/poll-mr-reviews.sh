#!/bin/bash
# Poll a GitLab MR for new review discussions, approval status, award emoji, or idle timeout.
# Used by /mr-fix-loop to avoid generating inline polling scripts.
#
# Usage: poll-mr-reviews.sh <mr_iid> [poll_interval_sec] [max_polls]
#
# Requires: glab CLI authenticated and inside a git repo with a GitLab remote.
#
# Exit codes: see lib/poll-common.sh for constants.
#   0=APPROVED  1=NEW_COMMENTS  2=IDLE_TIMEOUT  3=PIPELINE_FAILED
#   4=BLOCKED_ON_HUMAN  10=USAGE_ERROR  11=SNAPSHOT_FAILURE
#
# Output: JSON on stdout describing the stop condition and relevant details.

set -uo pipefail
source "${BASH_SOURCE[0]%/*}/lib/poll-common.sh"

MR_IID="${1:-}"
POLL_INTERVAL="${2:-60}"
MAX_POLLS="${3:-15}"

if [ -z "$MR_IID" ]; then
  echo '{"error": "Usage: poll-mr-reviews.sh <mr_iid> [poll_interval_sec] [max_polls]"}' >&2
  exit $EXIT_USAGE_ERROR
fi
require_positive_int "$POLL_INTERVAL" "poll_interval_sec"
require_positive_int "$MAX_POLLS" "max_polls"

PROJECT_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's|.*[:/](.+)(\.git)?$|\1|' | tr '/' '-')
acquire_pidfile "/tmp/poll-mr-reviews-${PROJECT_SLUG}-${MR_IID}.pid"

# Bot patterns — anchored to avoid matching human usernames
BOT_PATTERNS="\\[bot\\]$|-bot-|^gitlab-duo|^gitlab-code-review|^cursor-bugbot|^chatgpt-codex"

# Snapshot discussions and pipeline state at startup (parallel)
SNAP_DIR=$(mktemp -d)
register_cleanup "$SNAP_DIR"
glab api "projects/:id/merge_requests/$MR_IID/discussions" > "$SNAP_DIR/discussions.json" 2>/dev/null &
glab api "projects/:id/merge_requests/$MR_IID/pipelines" > "$SNAP_DIR/pipelines.json" 2>/dev/null &
wait

SNAPSHOT_DISCUSSIONS=$(cat "$SNAP_DIR/discussions.json" 2>/dev/null)
if [ -z "$SNAPSHOT_DISCUSSIONS" ] || ! echo "$SNAPSHOT_DISCUSSIONS" | jq -e '.' >/dev/null 2>&1; then
  echo '{"error": "Failed to snapshot MR discussions"}' >&2
  exit $EXIT_SNAPSHOT_FAILURE
fi
KNOWN_IDS=$(echo "$SNAPSHOT_DISCUSSIONS" | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | .id] | sort | .[]')

SNAPSHOT_PIPELINES=$(cat "$SNAP_DIR/pipelines.json" 2>/dev/null || echo '[]')
KNOWN_PIPELINE_ID=$(echo "$SNAPSHOT_PIPELINES" | jq -r '.[0].id // "none"' 2>/dev/null || echo "none")
rm -rf "$SNAP_DIR"

STALE_POLLS=0
BLOCKED_THRESHOLD=3

POLL=0
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  sleep "$POLL_INTERVAL"

  # Fetch all four API endpoints in parallel
  POLL_DIR=$(mktemp -d)
  register_cleanup "$POLL_DIR"
  glab api "projects/:id/merge_requests/$MR_IID/approvals" > "$POLL_DIR/approvals.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/award_emoji" > "$POLL_DIR/emoji.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/discussions" > "$POLL_DIR/discussions.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/pipelines" > "$POLL_DIR/pipelines.json" 2>/dev/null &
  wait

  # --- Check MR approval status (primary gate) ---
  APPROVALS=$(cat "$POLL_DIR/approvals.json" 2>/dev/null || echo '{}')
  APPROVAL_DATA=$(echo "$APPROVALS" | jq '{approved: (.approved // false), left: (.approvals_left // -1), by: [.approved_by[]? | .user.username]}' 2>/dev/null || echo '{"approved":false,"left":-1,"by":[]}')
  IS_APPROVED=$(echo "$APPROVAL_DATA" | jq -r '.approved')
  APPROVALS_LEFT=$(echo "$APPROVAL_DATA" | jq -r '.left')

  if [ "$IS_APPROVED" = "true" ] || [ "$APPROVALS_LEFT" = "0" ]; then
    APPROVED_BY=$(echo "$APPROVAL_DATA" | jq '.by')
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"native_approval\", \"approved_by\": $APPROVED_BY}"
    rm -rf "$POLL_DIR"
    exit $EXIT_APPROVED
  fi

  # --- Check award emoji on MR (secondary gate) — single jq call ---
  EMOJI=$(cat "$POLL_DIR/emoji.json" 2>/dev/null || echo '[]')
  BOT_APPROVERS=$(echo "$EMOJI" | jq "[
    .[]?
    | select(.name == \"thumbsup\" or .name == \"white_check_mark\")
    | select(.user.username | test(\"$BOT_PATTERNS\"; \"i\"))
    | {user: .user.username, emoji: .name}
  ]" 2>/dev/null || echo '[]')
  BOT_APPROVAL_COUNT=$(echo "$BOT_APPROVERS" | jq 'length')

  if [ "$BOT_APPROVAL_COUNT" -gt 0 ]; then
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"award_emoji\", \"approvers\": $BOT_APPROVERS}"
    rm -rf "$POLL_DIR"
    exit $EXIT_APPROVED
  fi

  # --- Check for NEW unresolved resolvable discussions ---
  DISCUSSIONS=$(cat "$POLL_DIR/discussions.json" 2>/dev/null)
  if [ -z "$DISCUSSIONS" ] || ! echo "$DISCUSSIONS" | jq -e '.' >/dev/null 2>&1; then
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: API request failed, retrying next cycle" >&2
    rm -rf "$POLL_DIR"
    continue
  fi

  ALL_UNRESOLVED_IDS=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | .id] | sort | .[]')
  NEW_IDS=$(find_new_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS")

  if [ "$_NEW_COUNT" -gt 0 ]; then
    NEW_ID_LIST=$(echo "$NEW_IDS" | jq -R . | jq -s .)
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
    echo "{\"status\": \"NEW_COMMENTS\", \"poll\": $POLL, \"count\": $_NEW_COUNT, \"discussions\": $UNRESOLVED}"
    rm -rf "$POLL_DIR"
    exit $EXIT_NEW_COMMENTS
  fi

  # --- Check pipeline status (only report NEW failures) ---
  PIPELINES=$(cat "$POLL_DIR/pipelines.json" 2>/dev/null || echo '[]')
  read -r LATEST_STATUS LATEST_PIPELINE_ID < <(echo "$PIPELINES" | jq -r '"\\(.[0].status // "unknown") \\(.[0].id // "none")"')

  if [ "$LATEST_STATUS" = "failed" ] && [ "$LATEST_PIPELINE_ID" != "$KNOWN_PIPELINE_ID" ]; then
    echo "{\"status\": \"PIPELINE_FAILED\", \"poll\": $POLL, \"pipeline_id\": \"$LATEST_PIPELINE_ID\", \"pipeline_status\": \"$LATEST_STATUS\"}"
    rm -rf "$POLL_DIR"
    exit $EXIT_PIPELINE_FAILED
  fi

  rm -rf "$POLL_DIR"

  # Track stale discussions for BLOCKED_ON_HUMAN
  if has_known_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS"; then
    STALE_POLLS=$((STALE_POLLS + 1))
    if [ "$STALE_POLLS" -ge "$BLOCKED_THRESHOLD" ]; then
      STALE_DISCUSSIONS=$(echo "$DISCUSSIONS" | jq '[
        .[] | select(.notes[0].resolvable == true and .notes[0].resolved == false)
        | { id: .id, author: .notes[0].author.username, body: (.notes[0].body | .[0:200]) }
      ]')
      echo "{\"status\": \"BLOCKED_ON_HUMAN\", \"poll\": $POLL, \"stale_polls\": $STALE_POLLS, \"discussions\": $STALE_DISCUSSIONS}"
      exit $EXIT_BLOCKED_ON_HUMAN_MR
    fi
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: Only stale unresolved discussions ($STALE_POLLS/$BLOCKED_THRESHOLD toward blocked-on-human, pipeline: $LATEST_STATUS)" >&2
  else
    STALE_POLLS=0
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval yet (pipeline: $LATEST_STATUS)" >&2
  fi
done

echo "{\"status\": \"IDLE_TIMEOUT\", \"polls_completed\": $MAX_POLLS, \"total_seconds\": $((MAX_POLLS * POLL_INTERVAL))}"
exit $EXIT_IDLE_TIMEOUT
