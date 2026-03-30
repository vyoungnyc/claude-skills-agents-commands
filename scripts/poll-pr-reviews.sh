#!/bin/bash
# Poll a GitHub PR for new review comments, approval emoji, or idle timeout.
#
# Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]
# Exit codes: see lib/poll-common.sh

set -uo pipefail
source "${BASH_SOURCE[0]%/*}/lib/poll-common.sh"

REPO="${1:-}"
PR_NUMBER="${2:-}"
POLL_INTERVAL="${3:-60}"
MAX_POLLS="${4:-15}"

if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
  echo '{"error": "Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]"}' >&2
  exit $EXIT_USAGE_ERROR
fi
require_positive_int "$POLL_INTERVAL" "poll_interval_sec"
require_positive_int "$MAX_POLLS" "max_polls"

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

acquire_pidfile "/tmp/poll-pr-reviews-${OWNER}-${NAME}-${PR_NUMBER}.pid"

BOT_PATTERNS="$BASE_BOT_PATTERNS"

SNAPSHOT=$(gh api graphql -f query="
  query {
    repository(owner: \"$OWNER\", name: \"$NAME\") {
      pullRequest(number: $PR_NUMBER) {
        reviewThreads(first: 100) {
          nodes { id isResolved }
        }
      }
    }
  }
" 2>/dev/null)

if [ -z "$SNAPSHOT" ] || ! echo "$SNAPSHOT" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1; then
  echo '{"error": "Failed to snapshot PR state"}' >&2
  exit $EXIT_SNAPSHOT_FAILURE
fi

KNOWN_IDS=$(echo "$SNAPSHOT" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id] | sort | .[]')

POLL=0
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  sleep "$POLL_INTERVAL"

  RESULT=$(gh api graphql -f query="
    query {
      repository(owner: \"$OWNER\", name: \"$NAME\") {
        pullRequest(number: $PR_NUMBER) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 10) {
                nodes { databaseId body author { login } path line createdAt }
              }
            }
          }
          reactions(first: 100) {
            nodes { content user { login } }
          }
        }
      }
    }
  " 2>/dev/null)

  if [ -z "$RESULT" ] || ! echo "$RESULT" | jq -e '.data' >/dev/null 2>&1; then
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: API request failed, retrying next cycle" >&2
    continue
  fi

  BOT_APPROVERS=$(echo "$RESULT" | jq "[
    .data.repository.pullRequest.reactions.nodes[]?
    | select(.content == \"THUMBS_UP\" or .content == \"WHITE_CHECK_MARK\")
    | select(.user.login | test(\"$BOT_PATTERNS\"; \"i\"))
  ]")
  if echo "$BOT_APPROVERS" | jq -e 'length > 0' >/dev/null 2>&1; then
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"approvers\": $BOT_APPROVERS}"
    exit $EXIT_APPROVED
  fi

  ALL_UNRESOLVED_IDS=$(echo "$RESULT" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id] | sort | .[]')
  NEW_IDS=$(find_new_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS")

  if [ "$_NEW_COUNT" -gt 0 ]; then
    NEW_ID_LIST=$(echo "$NEW_IDS" | jq -R '[., inputs]')
    UNRESOLVED=$(echo "$RESULT" | jq --argjson ids "$NEW_ID_LIST" '[
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | select(.id as $tid | $ids | index($tid))
      | {
          id: .id,
          author: .comments.nodes[0].author.login,
          path: .comments.nodes[0].path,
          line: .comments.nodes[0].line,
          body: (.comments.nodes[0].body | .[0:200]),
          created: .comments.nodes[0].createdAt
        }
    ]')
    echo "{\"status\": \"NEW_COMMENTS\", \"poll\": $POLL, \"count\": $_NEW_COUNT, \"threads\": $UNRESOLVED}"
    exit $EXIT_NEW_COMMENTS
  fi

  if has_known_ids "$ALL_UNRESOLVED_IDS" "$KNOWN_IDS"; then
    STALE_POLLS=$((STALE_POLLS + 1))
    if [ "$STALE_POLLS" -ge "$BLOCKED_THRESHOLD" ]; then
      STALE_THREADS=$(echo "$RESULT" | jq '[
        .data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | { id: .id, author: .comments.nodes[0].author.login, path: .comments.nodes[0].path, body: (.comments.nodes[0].body | .[0:200]) }
      ]')
      echo "{\"status\": \"BLOCKED_ON_HUMAN\", \"poll\": $POLL, \"stale_polls\": $STALE_POLLS, \"threads\": $STALE_THREADS}"
      exit $EXIT_BLOCKED_ON_HUMAN
    fi
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: Only stale unresolved threads ($STALE_POLLS/$BLOCKED_THRESHOLD toward blocked-on-human)" >&2
  else
    STALE_POLLS=0
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval emoji yet" >&2
  fi
done

emit_idle_timeout
