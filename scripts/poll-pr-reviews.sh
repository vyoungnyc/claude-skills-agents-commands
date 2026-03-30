#!/bin/bash
# Poll a GitHub PR for new review comments, approval emoji, or idle timeout.
# Used by /pr-fix-loop to avoid generating inline polling scripts.
#
# Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]
#
# Exit codes:
#   0 — APPROVED (bot reacted with thumbsup/checkmark on PR description)
#   1 — NEW_COMMENTS (unresolved review threads detected)
#   2 — IDLE_TIMEOUT (no new comments within max polling window)
#   3 — BLOCKED_ON_HUMAN (only disputed threads remain)
#   10 — Usage error
#
# Output: JSON on stdout describing the stop condition and relevant details.

set -euo pipefail

REPO="${1:-}"
PR_NUMBER="${2:-}"
POLL_INTERVAL="${3:-60}"
MAX_POLLS="${4:-15}"

if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
  echo '{"error": "Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]"}' >&2
  exit 10
fi

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# Known bot login patterns (case-insensitive match)
BOT_PATTERNS="bot|codex|cursor|gitlab"

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
                nodes {
                  databaseId
                  body
                  author { login }
                  path
                  line
                  createdAt
                }
              }
            }
          }
          reactions(first: 100) {
            nodes {
              content
              user { login }
            }
          }
        }
      }
    }
  " 2>&1)

  # Check for approval emoji from bots on PR description
  APPROVED_COUNT=$(echo "$RESULT" | jq "[
    .data.repository.pullRequest.reactions.nodes[]
    | select(.content == \"THUMBS_UP\" or .content == \"WHITE_CHECK_MARK\")
    | select(.user.login | test(\"$BOT_PATTERNS\"; \"i\"))
  ] | length")

  if [ "$APPROVED_COUNT" -gt 0 ]; then
    APPROVERS=$(echo "$RESULT" | jq "[
      .data.repository.pullRequest.reactions.nodes[]
      | select(.content == \"THUMBS_UP\" or .content == \"WHITE_CHECK_MARK\")
      | select(.user.login | test(\"$BOT_PATTERNS\"; \"i\"))
    ]")
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"approvers\": $APPROVERS}"
    exit 0
  fi

  # Check for unresolved review threads
  UNRESOLVED=$(echo "$RESULT" | jq '[
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)
    | {
        id: .id,
        author: .comments.nodes[0].author.login,
        path: .comments.nodes[0].path,
        line: .comments.nodes[0].line,
        body: (.comments.nodes[0].body | .[0:200]),
        created: .comments.nodes[0].createdAt
      }
  ]')
  UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | jq 'length')

  if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
    echo "{\"status\": \"NEW_COMMENTS\", \"poll\": $POLL, \"count\": $UNRESOLVED_COUNT, \"threads\": $UNRESOLVED}"
    exit 1
  fi

  echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval emoji yet" >&2
done

echo "{\"status\": \"IDLE_TIMEOUT\", \"polls_completed\": $MAX_POLLS, \"total_seconds\": $((MAX_POLLS * POLL_INTERVAL))}"
exit 2
