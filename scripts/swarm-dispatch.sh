#!/bin/bash
# Launch parallel claude sessions in git worktrees for a swarm feature batch.
#
# Usage: swarm-dispatch.sh <feature_id> <feature_branch> <batch_config_json_file>
#
# batch_config_json format:
# [
#   {
#     "name": "backend",
#     "steps": ["step_01","step_03"],
#     "issues": [43,45],
#     "complexity": "high",
#     "prompt": "Implement backend steps..."
#   },
#   {
#     "name": "frontend",
#     "steps": ["step_02","step_04"],
#     "issues": [44,46],
#     "complexity": "medium",
#     "prompt": "Implement frontend steps..."
#   }
# ]
#
# For each batch:
#   1. Creates a git worktree off the feature branch
#   2. Launches a claude session with the batch prompt
#   3. Runs all sessions in parallel with &, captures PIDs
#   4. Waits for all, captures exit codes
#   5. Parses JSON result (session_id, cost, duration, result)
#   6. Merges each worktree branch back to feature branch
#   7. Cleans up worktrees
#   8. Outputs combined results as JSON to stdout
#
# Model selection from complexity:
#   high   → opus   --max-turns 40
#   medium → sonnet --max-turns 30
#   low    → haiku  --max-turns 20
#
# Exit codes:
#   0 — all sessions merged successfully (some may have failed internally)
#   1 — fatal error (missing args, invalid JSON, git error)
#  10 — usage error

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,Bash,Agent,TaskList,TaskGet,TaskUpdate"

MODEL_HIGH="opus"
MODEL_MEDIUM="sonnet"
MODEL_LOW="haiku"

TURNS_HIGH=40
TURNS_MEDIUM=30
TURNS_LOW=20

EXIT_OK=0
EXIT_FATAL=1
EXIT_USAGE=10

# ---------------------------------------------------------------------------
# Cleanup registry (same pattern as poll-common.sh)
# ---------------------------------------------------------------------------

_CLEANUP_PATHS=()

_cleanup() {
  local p
  for p in "${_CLEANUP_PATHS[@]}"; do
    rm -rf "$p"
  done
}
trap _cleanup EXIT INT TERM

register_cleanup() {
  _CLEANUP_PATHS+=("$1")
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

FEATURE_ID="${1:-}"
FEATURE_BRANCH="${2:-}"
BATCH_CONFIG_FILE="${3:-}"

if [ -z "$FEATURE_ID" ] || [ -z "$FEATURE_BRANCH" ] || [ -z "$BATCH_CONFIG_FILE" ]; then
  echo '{"error": "Usage: swarm-dispatch.sh <feature_id> <feature_branch> <batch_config_json_file>"}' >&2
  exit $EXIT_USAGE
fi

if [ ! -f "$BATCH_CONFIG_FILE" ]; then
  echo "{\"error\": \"Batch config file not found: $BATCH_CONFIG_FILE\"}" >&2
  exit $EXIT_USAGE
fi

BATCH_CONFIG=$(cat "$BATCH_CONFIG_FILE")
if ! echo "$BATCH_CONFIG" | jq -e '.' >/dev/null 2>&1; then
  echo '{"error": "Batch config file is not valid JSON"}' >&2
  exit $EXIT_USAGE
fi

BATCH_COUNT=$(echo "$BATCH_CONFIG" | jq 'length')
if [ "$BATCH_COUNT" -lt 1 ]; then
  echo '{"error": "Batch config must contain at least one batch"}' >&2
  exit $EXIT_USAGE
fi

# ---------------------------------------------------------------------------
# PID file — kill any previous invocation for this feature_id
# ---------------------------------------------------------------------------

PIDFILE="/tmp/swarm-dispatch-${FEATURE_ID}.pid"
register_cleanup "$PIDFILE"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    local_i=0
    while kill -0 "$OLD_PID" 2>/dev/null && [ $local_i -lt 3 ]; do
      sleep 1
      local_i=$((local_i + 1))
    done
    kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null || true
    echo "[$(date +"%H:%M:%S")] Killed previous swarm-dispatch instance (PID $OLD_PID)" >&2
  fi
fi
echo $$ > "$PIDFILE"

# ---------------------------------------------------------------------------
# Working directory — must be inside a git repo
# ---------------------------------------------------------------------------

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo '{"error": "Not inside a git repository"}' >&2
  exit $EXIT_FATAL
fi

# Verify feature branch exists; create local tracking branch if only remote ref exists
if git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$FEATURE_BRANCH" >/dev/null 2>&1; then
  : # Local branch exists
elif git -C "$REPO_ROOT" rev-parse --verify "refs/remotes/origin/$FEATURE_BRANCH" >/dev/null 2>&1; then
  echo "[$(date +"%H:%M:%S")] Creating local tracking branch for 'origin/$FEATURE_BRANCH'" >&2
  git -C "$REPO_ROOT" checkout -b "$FEATURE_BRANCH" "origin/$FEATURE_BRANCH" 2>/dev/null || {
    echo "{\"error\": \"Failed to create local tracking branch for '$FEATURE_BRANCH'\"}" >&2
    exit $EXIT_FATAL
  }
else
  echo "{\"error\": \"Feature branch '$FEATURE_BRANCH' not found locally or on origin\"}" >&2
  exit $EXIT_FATAL
fi

# ---------------------------------------------------------------------------
# Temp directory for per-session output files
# ---------------------------------------------------------------------------

WORK_DIR=$(mktemp -d)
register_cleanup "$WORK_DIR"

echo "[$(date +"%H:%M:%S")] Starting swarm for feature '$FEATURE_ID' on branch '$FEATURE_BRANCH' ($BATCH_COUNT batches)" >&2

# ---------------------------------------------------------------------------
# Model + turns selection
# ---------------------------------------------------------------------------

select_model() {
  local complexity="$1"
  case "$complexity" in
    high)   echo "$MODEL_HIGH" ;;
    low)    echo "$MODEL_LOW" ;;
    *)      echo "$MODEL_MEDIUM" ;;
  esac
}

select_turns() {
  local complexity="$1"
  case "$complexity" in
    high)   echo "$TURNS_HIGH" ;;
    low)    echo "$TURNS_LOW" ;;
    *)      echo "$TURNS_MEDIUM" ;;
  esac
}

# ---------------------------------------------------------------------------
# Launch all sessions in parallel
# ---------------------------------------------------------------------------

declare -a SESSION_PIDS=()
declare -a SESSION_NAMES=()
declare -a WORKTREE_PATHS=()
declare -a WORKTREE_BRANCHES=()

for i in $(seq 0 $((BATCH_COUNT - 1))); do
  BATCH=$(echo "$BATCH_CONFIG" | jq ".[$i]")
  BATCH_NAME=$(echo "$BATCH" | jq -r '.name')
  COMPLEXITY=$(echo "$BATCH" | jq -r '.complexity // "medium"')
  PROMPT=$(echo "$BATCH" | jq -r '.prompt')
  STEPS=$(echo "$BATCH" | jq -r '.steps | join(",")')
  ISSUES=$(echo "$BATCH" | jq -r '.issues | join(",")')

  MODEL=$(select_model "$COMPLEXITY")
  TURNS=$(select_turns "$COMPLEXITY")

  WORKTREE_PATH="/tmp/swarm-${FEATURE_ID}-${BATCH_NAME}"
  WORKTREE_BRANCH="swarm/${FEATURE_ID}/${BATCH_NAME}"
  OUTPUT_FILE="${WORK_DIR}/session_${i}_${BATCH_NAME}.json"
  LOG_FILE="${WORK_DIR}/session_${i}_${BATCH_NAME}.log"

  # Register worktree for cleanup on unexpected exit (removed after merge)
  register_cleanup "$WORKTREE_PATH"

  # Remove stale worktree if it exists from a prior run
  if [ -d "$WORKTREE_PATH" ]; then
    echo "[$(date +"%H:%M:%S")] Removing stale worktree at $WORKTREE_PATH" >&2
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || rm -rf "$WORKTREE_PATH"
  fi
  # Remove stale worktree branch if it exists
  git -C "$REPO_ROOT" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true

  # Create worktree off the feature branch
  if ! git -C "$REPO_ROOT" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$FEATURE_BRANCH" 2>&1 | tee -a "$LOG_FILE" >&2; then
    echo "{\"error\": \"Failed to create worktree for batch '$BATCH_NAME'\"}" >> "$OUTPUT_FILE"
    SESSION_PIDS+=(-1)
    SESSION_NAMES+=("$BATCH_NAME")
    WORKTREE_PATHS+=("")
    WORKTREE_BRANCHES+=("")
    continue
  fi

  echo "[$(date +"%H:%M:%S")] Launching session '$BATCH_NAME' (steps: $STEPS, issues: $ISSUES, model: $MODEL, turns: $TURNS)" >&2

  # Launch claude session in background
  (
    cd "$WORKTREE_PATH"
    claude -p "$PROMPT" \
      --output-format json \
      --model "$MODEL" \
      --max-turns "$TURNS" \
      --allowedTools "$ALLOWED_TOOLS" \
      --permission-mode auto \
      > "$OUTPUT_FILE" 2>> "$LOG_FILE"
    echo $? > "${OUTPUT_FILE}.exit"
  ) &

  SESSION_PIDS+=($!)
  SESSION_NAMES+=("$BATCH_NAME")
  WORKTREE_PATHS+=("$WORKTREE_PATH")
  WORKTREE_BRANCHES+=("$WORKTREE_BRANCH")
done

# ---------------------------------------------------------------------------
# Wait for all sessions
# ---------------------------------------------------------------------------

echo "[$(date +"%H:%M:%S")] Waiting for ${#SESSION_PIDS[@]} session(s) to complete..." >&2

declare -a SESSION_EXIT_CODES=()
for i in "${!SESSION_PIDS[@]}"; do
  PID="${SESSION_PIDS[$i]}"
  NAME="${SESSION_NAMES[$i]}"
  if [ "$PID" -eq -1 ]; then
    SESSION_EXIT_CODES+=(-1)
    echo "[$(date +"%H:%M:%S")] Session '$NAME' was not launched (worktree creation failed)" >&2
    continue
  fi
  wait "$PID"
  CODE=$?
  SESSION_EXIT_CODES+=($CODE)
  echo "[$(date +"%H:%M:%S")] Session '$NAME' (PID $PID) completed with exit code $CODE" >&2
done

# ---------------------------------------------------------------------------
# Merge worktrees back to feature branch
# ---------------------------------------------------------------------------

declare -a MERGE_RESULTS=()

# Require a clean working tree before checkout/merge to avoid stomping local changes
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
  echo "{\"error\": \"Working tree has uncommitted changes — cannot safely merge. Commit or stash before running swarm-dispatch.\"}" >&2
  exit $EXIT_FATAL
fi

# Ensure we're on the feature branch before merging
git -C "$REPO_ROOT" checkout "$FEATURE_BRANCH" 2>/dev/null || {
  echo "{\"error\": \"Failed to checkout feature branch '$FEATURE_BRANCH' before merging\"}" >&2
  exit $EXIT_FATAL
}

for i in "${!WORKTREE_BRANCHES[@]}"; do
  BRANCH="${WORKTREE_BRANCHES[$i]}"
  PATH_WT="${WORKTREE_PATHS[$i]}"
  NAME="${SESSION_NAMES[$i]}"
  EXIT_CODE="${SESSION_EXIT_CODES[$i]}"

  if [ -z "$BRANCH" ] || [ -z "$PATH_WT" ]; then
    MERGE_RESULTS+=("{\"batch\": \"$NAME\", \"merged\": false, \"reason\": \"worktree_not_created\"}")
    continue
  fi

  # Skip merge for failed sessions — don't pull incomplete work into the feature branch
  if [ "$EXIT_CODE" -ne 0 ]; then
    echo "[$(date +"%H:%M:%S")] Skipping merge for '$NAME' — session exited with code $EXIT_CODE" >&2
    MERGE_RESULTS+=("{\"batch\": \"$NAME\", \"merged\": false, \"reason\": \"session_failed\", \"exit_code\": $EXIT_CODE}")
    git -C "$REPO_ROOT" worktree remove --force "$PATH_WT" 2>/dev/null || rm -rf "$PATH_WT"
    continue
  fi

  echo "[$(date +"%H:%M:%S")] Merging '$BRANCH' into '$FEATURE_BRANCH'..." >&2

  MERGE_LOG_FILE="${WORK_DIR}/merge_${i}_${NAME}.log"
  git -C "$REPO_ROOT" merge --no-ff "$BRANCH" -m "swarm(${FEATURE_ID}): merge batch '${NAME}'" > "$MERGE_LOG_FILE" 2>&1
  MERGE_EXIT=$?
  MERGE_OUTPUT=$(cat "$MERGE_LOG_FILE")

  if [ "$MERGE_EXIT" -eq 0 ]; then
    MERGE_RESULTS+=("{\"batch\": \"$NAME\", \"merged\": true, \"conflicts\": false}")
    echo "[$(date +"%H:%M:%S")] Merged '$NAME' successfully" >&2
  else
    # Check for merge conflicts
    CONFLICTS=$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null | jq -R '[., inputs]' || echo '[]')
    git -C "$REPO_ROOT" merge --abort 2>/dev/null || true
    MERGE_RESULTS+=("{\"batch\": \"$NAME\", \"merged\": false, \"conflicts\": true, \"conflict_files\": $CONFLICTS, \"merge_output\": $(echo "$MERGE_OUTPUT" | head -20 | jq -Rs '.')}")
    echo "[$(date +"%H:%M:%S")] Merge conflicts in '$NAME': $CONFLICTS" >&2
  fi

  # Clean up worktree (branch kept for inspection if merge failed)
  git -C "$REPO_ROOT" worktree remove --force "$PATH_WT" 2>/dev/null || rm -rf "$PATH_WT"
  # Remove the cleanup registration since we handled it
  # (bash arrays don't support deletion, so we just leave the path — rm -rf on non-existent dir is a no-op)
done

# ---------------------------------------------------------------------------
# Build combined JSON results output
# ---------------------------------------------------------------------------

RESULTS_JSON="["
for i in "${!SESSION_NAMES[@]}"; do
  NAME="${SESSION_NAMES[$i]}"
  EXIT_CODE="${SESSION_EXIT_CODES[$i]}"
  OUTPUT_FILE="${WORK_DIR}/session_${i}_${NAME}.json"
  EXIT_FILE="${OUTPUT_FILE}.exit"

  # Read actual exit code from subshell file if available
  if [ -f "$EXIT_FILE" ]; then
    ACTUAL_EXIT=$(cat "$EXIT_FILE" 2>/dev/null || echo "$EXIT_CODE")
  else
    ACTUAL_EXIT="$EXIT_CODE"
  fi

  # Parse session JSON output (read once to avoid double I/O)
  SESSION_JSON=""
  if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    RAW_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$RAW_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
      SESSION_JSON="$RAW_OUTPUT"
    else
      SESSION_JSON="{\"raw\": $(echo "$RAW_OUTPUT" | jq -Rs '.')}"
    fi
  else
    SESSION_JSON="{}"
  fi

  SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
  COST=$(echo "$SESSION_JSON" | jq -r '.cost_usd // null' 2>/dev/null || echo "null")
  DURATION=$(echo "$SESSION_JSON" | jq -r '.duration_ms // null' 2>/dev/null || echo "null")
  RESULT=$(echo "$SESSION_JSON" | jq -r '.result // null' 2>/dev/null || echo "null")

  MERGE_RESULT="${MERGE_RESULTS[$i]:-{\"batch\": \"$NAME\", \"merged\": false, \"reason\": \"unknown\"}}"

  ENTRY="{\"batch\": \"$NAME\", \"exit_code\": $ACTUAL_EXIT, \"session_id\": \"$SESSION_ID\", \"cost_usd\": $COST, \"duration_ms\": $DURATION, \"result\": $(echo "$RESULT" | jq -Rs 'if . == "null\n" then null else . end'), \"merge\": $MERGE_RESULT}"

  if [ $i -gt 0 ]; then
    RESULTS_JSON="${RESULTS_JSON},"
  fi
  RESULTS_JSON="${RESULTS_JSON}${ENTRY}"
done
RESULTS_JSON="${RESULTS_JSON}]"

# Count successes and failures
SUCCESS_COUNT=$(echo "$RESULTS_JSON" | jq '[.[] | select(.exit_code == 0)] | length')
FAILURE_COUNT=$(echo "$RESULTS_JSON" | jq '[.[] | select(.exit_code != 0)] | length')
MERGE_CONFLICT_COUNT=$(echo "$RESULTS_JSON" | jq '[.[] | select(.merge.conflicts == true)] | length')

echo "{\"feature_id\": \"$FEATURE_ID\", \"feature_branch\": \"$FEATURE_BRANCH\", \"total\": $BATCH_COUNT, \"succeeded\": $SUCCESS_COUNT, \"failed\": $FAILURE_COUNT, \"merge_conflicts\": $MERGE_CONFLICT_COUNT, \"sessions\": $RESULTS_JSON}"
