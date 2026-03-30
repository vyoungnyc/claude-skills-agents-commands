#!/bin/bash
# Poll a GitLab MR for new review discussions, approval, emoji, pipeline, or idle timeout.
#
# Usage: poll-mr-reviews.sh <mr_iid> [poll_interval_sec] [max_polls]
# Requires: glab CLI authenticated and inside a git repo with a GitLab remote.
# Exit codes: see lib/poll-common.sh

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

REMOTE_URL=$(git remote get-url origin 2>/dev/null | sed -E 's|\.git$||')
if [[ "$REMOTE_URL" == *"://"* ]]; then
  PROJECT_SLUG=$(echo "$REMOTE_URL" | sed -E 's|^[a-z]+://[^/]+/||' | tr '/' '-')
else
  PROJECT_SLUG=$(echo "$REMOTE_URL" | sed -E 's|^[^:]+:||' | tr '/' '-')
fi
acquire_pidfile "/tmp/poll-mr-reviews-${PROJECT_SLUG}-${MR_IID}.pid"

BOT_PATTERNS="$BASE_BOT_PATTERNS|^gitlab-duo|^gitlab-code-review"

# Reusable temp dir for parallel API calls — created once, cleaned by trap
POLL_DIR=$(mktemp -d)
register_cleanup "$POLL_DIR"

# Snapshot at startup (parallel)
glab api "projects/:id/merge_requests/$MR_IID/discussions" > "$POLL_DIR/discussions.json" 2>/dev/null &
glab api "projects/:id/merge_requests/$MR_IID/pipelines" > "$POLL_DIR/pipelines.json" 2>/dev/null &
wait

SNAPSHOT_DISCUSSIONS=$(cat "$POLL_DIR/discussions.json" 2>/dev/null)
if [ -z "$SNAPSHOT_DISCUSSIONS" ] || ! echo "$SNAPSHOT_DISCUSSIONS" | jq -e '.' >/dev/null 2>&1; then
  echo '{"error": "Failed to snapshot MR discussions"}' >&2
  exit $EXIT_SNAPSHOT_FAILURE
fi
KNOWN_IDS=$(echo "$SNAPSHOT_DISCUSSIONS" | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | (.id | tostring)] | sort | .[]')
KNOWN_PIPELINE_ID=$(jq -r '.[0].id // "none"' < "$POLL_DIR/pipelines.json" 2>/dev/null || echo "none")

POLL=0
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  sleep "$POLL_INTERVAL"

  # Fetch all endpoints in parallel (reuse POLL_DIR)
  glab api "projects/:id/merge_requests/$MR_IID/approvals" > "$POLL_DIR/approvals.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/award_emoji" > "$POLL_DIR/emoji.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/discussions" > "$POLL_DIR/discussions.json" 2>/dev/null &
  glab api "projects/:id/merge_requests/$MR_IID/pipelines" > "$POLL_DIR/pipelines.json" 2>/dev/null &
  wait

  # Single jq call for approval data
  read -r IS_APPROVED APPROVALS_LEFT < <(jq -r '"\(.approved // false) \(.approvals_left // -1)"' < "$POLL_DIR/approvals.json" 2>/dev/null || echo "false -1")
  if [ "$IS_APPROVED" = "true" ] || [ "$APPROVALS_LEFT" = "0" ]; then
    APPROVED_BY=$(jq '[.approved_by[]? | .user.username]' < "$POLL_DIR/approvals.json")
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"native_approval\", \"approved_by\": $APPROVED_BY}"
    exit $EXIT_APPROVED
  fi

  BOT_APPROVERS=$(jq "[
    .[]?
    | select(.name == \"thumbsup\" or .name == \"white_check_mark\")
    | select(.user.username | test(\"$BOT_PATTERNS\"; \"i\"))
    | {user: .user.username, emoji: .name}
  ]" < "$POLL_DIR/emoji.json" 2>/dev/null || echo '[]')
  if echo "$BOT_APPROVERS" | jq -e 'length > 0' >/dev/null 2>&1; then
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"gate\": \"award_emoji\", \"approvers\": $BOT_APPROVERS}"
    exit $EXIT_APPROVED
  fi

  DISCUSSIONS=$(cat "$POLL_DIR/discussions.json" 2>/dev/null)
  if [ -z "$DISCUSSIONS" ] || ! echo "$DISCUSSIONS" | jq -e '.' >/dev/null 2>&1; then
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: API request failed, retrying next cycle" >&2
    continue
  fi

  ALL_UNRESOLVED_IDS=$(echo "$DISCUSSIONS" | jq -r '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false) | (.id | tostring)] | sort | .[]')
  NEW_IDS=$(find_new_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS")

  if [ "$_NEW_COUNT" -gt 0 ]; then
    NEW_ID_LIST=$(echo "$NEW_IDS" | jq -R '[., inputs]')
    UNRESOLVED=$(echo "$DISCUSSIONS" | jq --argjson ids "$NEW_ID_LIST" '[
      .[]
      | select(.notes[0].resolvable == true and .notes[0].resolved == false)
      | select((.id | tostring) as $did | $ids | index($did))
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
    exit $EXIT_NEW_COMMENTS
  fi

  read -r LATEST_STATUS LATEST_PIPELINE_ID < <(jq -r '"\(.[0].status // "unknown") \(.[0].id // "none")"' < "$POLL_DIR/pipelines.json" 2>/dev/null || echo "unknown none")
  if [ "$LATEST_STATUS" = "failed" ] && [ "$LATEST_PIPELINE_ID" != "$KNOWN_PIPELINE_ID" ]; then
    echo "{\"status\": \"PIPELINE_FAILED\", \"poll\": $POLL, \"pipeline_id\": \"$LATEST_PIPELINE_ID\", \"pipeline_status\": \"$LATEST_STATUS\"}"
    exit $EXIT_PIPELINE_FAILED
  fi

  if has_known_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS"; then
    STALE_POLLS=$((STALE_POLLS + 1))
    if [ "$STALE_POLLS" -ge "$BLOCKED_THRESHOLD" ]; then
      STALE_DISCUSSIONS=$(echo "$DISCUSSIONS" | jq '[
        .[] | select(.notes[0].resolvable == true and .notes[0].resolved == false)
        | { id: .id, author: .notes[0].author.username, body: (.notes[0].body | .[0:200]) }
      ]')
      echo "{\"status\": \"BLOCKED_ON_HUMAN\", \"poll\": $POLL, \"stale_polls\": $STALE_POLLS, \"discussions\": $STALE_DISCUSSIONS}"
      exit $EXIT_BLOCKED_ON_HUMAN
    fi
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: Only stale unresolved discussions ($STALE_POLLS/$BLOCKED_THRESHOLD toward blocked-on-human, pipeline: $LATEST_STATUS)" >&2
  else
    STALE_POLLS=0
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval yet (pipeline: $LATEST_STATUS)" >&2
  fi
done

emit_idle_timeout
