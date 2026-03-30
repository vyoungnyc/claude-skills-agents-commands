#!/bin/bash
# Poll a GitHub PR for new review comments, approval emoji, or idle timeout.
# Used by /pr-fix-loop to avoid generating inline polling scripts.
#
# Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]
#
# Exit codes:
#   0 — APPROVED (bot reacted with thumbsup/checkmark on PR description)
#   1 — NEW_COMMENTS (new unresolved review threads detected)
#   2 — IDLE_TIMEOUT (no new comments within max polling window)
#   3 — BLOCKED_ON_HUMAN (only stale disputed threads remain, no new activity)
#   10 — Usage error
#   11 — Snapshot failure (could not read initial PR state)
#
# Output: JSON on stdout describing the stop condition and relevant details.

set -uo pipefail

REPO="${1:-}"
PR_NUMBER="${2:-}"
POLL_INTERVAL="${3:-60}"
MAX_POLLS="${4:-15}"

if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
  echo '{"error": "Usage: poll-pr-reviews.sh <owner/repo> <pr_number> [poll_interval_sec] [max_polls]"}' >&2
  exit 10
fi

# Validate numeric arguments
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [ "$POLL_INTERVAL" -lt 1 ]; then
  echo '{"error": "poll_interval_sec must be a positive integer"}' >&2
  exit 10
fi
if ! [[ "$MAX_POLLS" =~ ^[0-9]+$ ]] || [ "$MAX_POLLS" -lt 1 ]; then
  echo '{"error": "max_polls must be a positive integer"}' >&2
  exit 10
fi

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# --- PID file: kill any previous polling instance ---
PIDFILE="/tmp/poll-pr-reviews-${OWNER}-${NAME}-${PR_NUMBER}.pid"

cleanup() { rm -f "$PIDFILE"; }
trap cleanup EXIT INT TERM

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    # Wait briefly for the old process to die
    for _ in 1 2 3; do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 1
    done
    # Force kill if still alive
    kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null || true
    echo "[$(date +"%H:%M:%S")] Killed previous polling instance (PID $OLD_PID)" >&2
  fi
fi
echo $$ > "$PIDFILE"

# Known bot login patterns — anchored to avoid matching human usernames like "abbott"
# Matches: chatgpt-codex-connector[bot], cursor-bugbot[bot], gitlab-copilot[bot],
# and any username ending in [bot] or containing -bot-
BOT_PATTERNS="\\[bot\\]$|-bot-|^chatgpt-codex|^cursor-bugbot|^gitlab-copilot"

# Snapshot unresolved thread IDs at startup so we only report truly NEW threads.
SNAPSHOT_RESULT=$(gh api graphql -f query="
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

if [ -z "$SNAPSHOT_RESULT" ] || ! echo "$SNAPSHOT_RESULT" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1; then
  echo '{"error": "Failed to snapshot PR state — cannot determine known thread IDs"}' >&2
  exit 11
fi

KNOWN_THREAD_IDS=$(echo "$SNAPSHOT_RESULT" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id] | sort | .[]')

# Track consecutive polls with no changes for BLOCKED_ON_HUMAN detection.
STALE_POLLS=0
BLOCKED_THRESHOLD=3

POLL=0
while [ "$POLL" -lt "$MAX_POLLS" ]; do
  POLL=$((POLL + 1))
  sleep "$POLL_INTERVAL"

  # Fetch PR data — on API failure, skip this cycle and retry next
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
  " 2>/dev/null)

  if [ -z "$RESULT" ] || ! echo "$RESULT" | jq -e '.data' >/dev/null 2>&1; then
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: API request failed, retrying next cycle" >&2
    continue
  fi

  # Check for approval emoji from bots on PR description
  APPROVED_COUNT=$(echo "$RESULT" | jq "[
    .data.repository.pullRequest.reactions.nodes[]?
    | select(.content == \"THUMBS_UP\" or .content == \"WHITE_CHECK_MARK\")
    | select(.user.login | test(\"$BOT_PATTERNS\"; \"i\"))
  ] | length")

  if [ "$APPROVED_COUNT" -gt 0 ]; then
    APPROVERS=$(echo "$RESULT" | jq "[
      .data.repository.pullRequest.reactions.nodes[]?
      | select(.content == \"THUMBS_UP\" or .content == \"WHITE_CHECK_MARK\")
      | select(.user.login | test(\"$BOT_PATTERNS\"; \"i\"))
    ]")
    echo "{\"status\": \"APPROVED\", \"poll\": $POLL, \"approvers\": $APPROVERS}"
    exit 0
  fi

  # Check for NEW unresolved review threads (exclude known/stale ones)
  # Use jq to output one ID per line (not join), then grep -xF for exact whole-line match
  ALL_UNRESOLVED_IDS=$(echo "$RESULT" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id] | sort | .[]')

  NEW_ID_COUNT=0
  NEW_ID_FILE=$(mktemp)
  trap 'rm -f "$PIDFILE" "$NEW_ID_FILE"' EXIT INT TERM
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    if [ -z "$KNOWN_THREAD_IDS" ] || ! echo "$KNOWN_THREAD_IDS" | grep -qxF "$tid"; then
      echo "$tid" >> "$NEW_ID_FILE"
      NEW_ID_COUNT=$((NEW_ID_COUNT + 1))
    fi
  done <<< "$ALL_UNRESOLVED_IDS"

  if [ "$NEW_ID_COUNT" -gt 0 ]; then
    NEW_ID_LIST=$(jq -R . < "$NEW_ID_FILE" | jq -s .)
    rm -f "$NEW_ID_FILE"
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
    UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | jq 'length')
    echo "{\"status\": \"NEW_COMMENTS\", \"poll\": $POLL, \"count\": $UNRESOLVED_COUNT, \"threads\": $UNRESOLVED}"
    exit 1
  fi
  rm -f "$NEW_ID_FILE"

  # Check if stale (known) unresolved threads exist — track for BLOCKED_ON_HUMAN
  HAS_STALE=false
  if [ -n "$ALL_UNRESOLVED_IDS" ] && [ -n "$KNOWN_THREAD_IDS" ]; then
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      if echo "$KNOWN_THREAD_IDS" | grep -qxF "$tid"; then
        HAS_STALE=true
        break
      fi
    done <<< "$ALL_UNRESOLVED_IDS"
  fi

  if $HAS_STALE; then
    STALE_POLLS=$((STALE_POLLS + 1))
    if [ "$STALE_POLLS" -ge "$BLOCKED_THRESHOLD" ]; then
      STALE_THREADS=$(echo "$RESULT" | jq '[
        .data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | {
            id: .id,
            author: .comments.nodes[0].author.login,
            path: .comments.nodes[0].path,
            body: (.comments.nodes[0].body | .[0:200])
          }
      ]')
      echo "{\"status\": \"BLOCKED_ON_HUMAN\", \"poll\": $POLL, \"stale_polls\": $STALE_POLLS, \"threads\": $STALE_THREADS}"
      exit 3
    fi
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: Only stale unresolved threads ($STALE_POLLS/$BLOCKED_THRESHOLD toward blocked-on-human)" >&2
  else
    STALE_POLLS=0
    echo "[$(date +"%H:%M:%S")] POLL $POLL/$MAX_POLLS: No new comments, no approval emoji yet" >&2
  fi
done

echo "{\"status\": \"IDLE_TIMEOUT\", \"polls_completed\": $MAX_POLLS, \"total_seconds\": $((MAX_POLLS * POLL_INTERVAL))}"
exit 2
