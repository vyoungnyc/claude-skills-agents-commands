#!/bin/bash
# Create a GitHub epic (tracking issue) and child issues from plan steps.
#
# Usage: create-github-issues.sh <feature_id> <plan_steps_json_file> [roadmap_phases_json_file]
#
# plan_steps_json format:
# [
#   {
#     "step_id": "step_01",
#     "title": "Auth API endpoints",
#     "acceptance_criteria": ["JWT refresh returns 200", "Token expiry handled"],
#     "file_domain": ["src/backend/auth/", "src/services/session/"],
#     "complexity": "high",
#     "dependencies": [],
#     "batch_hint": "backend"
#   },
#   ...
# ]
#
# roadmap_phases_json format (optional):
# [
#   {"phase": "v1: Basic Auth", "summary": "Login/logout, JWT sessions"},
#   {"phase": "v2: RBAC", "summary": "Role-based permissions"},
#   ...
# ]
#
# Outputs JSON:
#   {"epic": 42, "issues": {"step_01": 43, "step_02": 44, ...}}
#
# Steps:
#   1. Parse plan steps JSON
#   2. Create child issues first (need numbers for epic task list)
#   3. Create epic with task list referencing child issue numbers
#   4. Output issue number mapping
#
# Requirements:
#   - gh CLI authenticated (gh auth status)
#   - jq installed
#
# Exit codes:
#   0 — success
#   1 — fatal error
#  10 — usage error

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EXIT_OK=0
EXIT_FATAL=1
EXIT_USAGE=10

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

FEATURE_ID="${1:-}"
PLAN_STEPS_FILE="${2:-}"
ROADMAP_FILE="${3:-}"   # optional — empty string if not provided

if [ -z "$FEATURE_ID" ] || [ -z "$PLAN_STEPS_FILE" ]; then
  echo '{"error": "Usage: create-github-issues.sh <feature_id> <plan_steps_json_file> [roadmap_phases_json_file]"}' >&2
  exit $EXIT_USAGE
fi

if [ ! -f "$PLAN_STEPS_FILE" ]; then
  echo "{\"error\": \"Plan steps file not found: $PLAN_STEPS_FILE\"}" >&2
  exit $EXIT_USAGE
fi

PLAN_STEPS=$(cat "$PLAN_STEPS_FILE")
if ! jq -e '.' <<< "$PLAN_STEPS" >/dev/null 2>&1; then
  echo '{"error": "Plan steps file is not valid JSON"}' >&2
  exit $EXIT_USAGE
fi

STEP_COUNT=$(jq 'length' <<< "$PLAN_STEPS")
if [ "$STEP_COUNT" -lt 1 ]; then
  echo '{"error": "Plan steps must contain at least one step"}' >&2
  exit $EXIT_USAGE
fi

# Validate gh CLI is available and authenticated
if ! command -v gh >/dev/null 2>&1; then
  echo '{"error": "gh CLI not found — install GitHub CLI and run gh auth login"}' >&2
  exit $EXIT_FATAL
fi

if ! gh auth status >/dev/null 2>&1; then
  echo '{"error": "gh CLI not authenticated — run gh auth login"}' >&2
  exit $EXIT_FATAL
fi

# Validate jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo '{"error": "jq not found — install jq"}' >&2
  exit $EXIT_FATAL
fi

# ---------------------------------------------------------------------------
# Repo detection — GH_REPO env var, or auto-detect from gh
# ---------------------------------------------------------------------------

REPO="${GH_REPO:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
fi

if [ -z "$REPO" ]; then
  echo '{"error": "Could not determine target repo — set GH_REPO=owner/repo or run from a directory with a GitHub remote"}' >&2
  exit $EXIT_FATAL
fi

echo "[$(date +"%H:%M:%S")] Target repo: $REPO" >&2

# Temp file for capturing gh stderr separately from stdout
GH_STDERR=$(mktemp)
trap 'rm -f "$GH_STDERR" "$ISSUE_MAP_FILE"' EXIT

# ---------------------------------------------------------------------------
# Helper: extract issue number from gh issue create URL output
# ---------------------------------------------------------------------------

parse_issue_number() {
  grep -oE 'issues/[0-9]+' <<< "$1" | head -1 | grep -oE '[0-9]+'
}

# ---------------------------------------------------------------------------
# Ensure required labels exist (idempotent — gh label create --force is a no-op if present)
# ---------------------------------------------------------------------------

echo "[$(date +"%H:%M:%S")] Ensuring labels exist on $REPO..." >&2
LABELS_TO_CREATE=("epic" "feature:${FEATURE_ID}")
while IFS= read -r lbl; do
  LABELS_TO_CREATE+=("$lbl")
done < <(jq -r '[.[] | "domain:\(.batch_hint // "general")", "complexity:\(.complexity // "medium")"] | unique | .[]' <<< "$PLAN_STEPS")
# Deduplicate and create
printf '%s\n' "${LABELS_TO_CREATE[@]}" | sort -u | while IFS= read -r label; do
  gh label create "$label" --repo "$REPO" --force 2>/dev/null || true
done

echo "[$(date +"%H:%M:%S")] Creating GitHub issues for feature '$FEATURE_ID' ($STEP_COUNT steps)..." >&2

# ---------------------------------------------------------------------------
# Step 1: Create child issues
# ---------------------------------------------------------------------------

# Accumulate issue map entries (assembled into JSON object after loop)
ISSUE_MAP_FILE=$(mktemp)

# Build task list lines for epic (populated as we create issues)
TASK_LIST_LINES=()

for i in $(seq 0 $((STEP_COUNT - 1))); do
  # Extract all fields in one jq call (avoids 7 separate jq forks per step)
  eval "$(jq -r --argjson i "$i" '.[$i] | @sh "STEP_ID=\(.step_id) TITLE=\(.title) COMPLEXITY=\(.complexity // "medium") BATCH_HINT=\(.batch_hint // "general") FILE_DOMAIN=\(.file_domain | join(", ")) DEPS_RAW=\(.dependencies // [] | join(", "))"' <<< "$PLAN_STEPS")"

  if [ -z "$DEPS_RAW" ]; then
    DEPS_LINE="_None_"
  else
    DEPS_LINE="$DEPS_RAW"
  fi

  # Build acceptance criteria checkboxes
  AC_CHECKBOXES=$(jq -r --argjson i "$i" '.[$i].acceptance_criteria // [] | .[] | "- [ ] \(.)"' <<< "$PLAN_STEPS")
  if [ -z "$AC_CHECKBOXES" ]; then
    AC_CHECKBOXES="- [ ] No acceptance criteria specified"
  fi

  # Build issue body
  ISSUE_BODY="## Acceptance Criteria
${AC_CHECKBOXES}

## Context
- **File domain:** \`${FILE_DOMAIN}\`
- **Complexity:** ${COMPLEXITY}
- **Dependencies:** ${DEPS_LINE}
- **Step:** ${STEP_ID}
- **Feature:** ${FEATURE_ID}
- **Test spec:** See PLAN_steps.md ${STEP_ID}
- **Architecture:** See ARCHITECTURE.md"

  echo "[$(date +"%H:%M:%S")] Creating child issue for $STEP_ID: $TITLE..." >&2

  ISSUE_URL=$(gh issue create \
    --repo "$REPO" \
    --title "${STEP_ID}: ${TITLE}" \
    --body "$ISSUE_BODY" \
    --label "feature:${FEATURE_ID}" \
    --label "domain:${BATCH_HINT}" \
    --label "complexity:${COMPLEXITY}" \
    2>"$GH_STDERR")
  CREATE_EXIT=$?

  if [ "$CREATE_EXIT" -ne 0 ]; then
    GH_ERR=$(cat "$GH_STDERR")
    echo "[$(date +"%H:%M:%S")] WARNING: Failed to create issue for $STEP_ID — gh error: $GH_ERR" >&2
    echo "\"$STEP_ID\": null" >> "$ISSUE_MAP_FILE"
    TASK_LIST_LINES+=("- [ ] (failed) ${STEP_ID}: ${TITLE}")
    continue
  fi

  ISSUE_NUMBER=$(parse_issue_number "$ISSUE_URL")

  if [ -z "$ISSUE_NUMBER" ]; then
    echo "[$(date +"%H:%M:%S")] WARNING: Could not parse issue number from: $ISSUE_URL" >&2
    echo "\"$STEP_ID\": null" >> "$ISSUE_MAP_FILE"
    TASK_LIST_LINES+=("- [ ] (unknown) ${STEP_ID}: ${TITLE}")
    continue
  fi

  echo "[$(date +"%H:%M:%S")] Created #${ISSUE_NUMBER} for $STEP_ID" >&2
  echo "\"$STEP_ID\": $ISSUE_NUMBER" >> "$ISSUE_MAP_FILE"
  TASK_LIST_LINES+=("- [ ] #${ISSUE_NUMBER} ${STEP_ID}: ${TITLE}")
done

# Build ISSUE_MAP from accumulated entries (avoids O(n^2) jq rebuilding per iteration)
ISSUE_MAP=$(jq -n "{ $(paste -sd',' "$ISSUE_MAP_FILE") }")
rm -f "$ISSUE_MAP_FILE"

# ---------------------------------------------------------------------------
# Step 2: Build epic body
# ---------------------------------------------------------------------------

# Assemble task list block
TASK_LIST_BLOCK=""
for line in "${TASK_LIST_LINES[@]}"; do
  TASK_LIST_BLOCK="${TASK_LIST_BLOCK}
${line}"
done

# Quality gates section
QUALITY_GATES="### Quality Gates
- [ ] Code review passed
- [ ] Security review passed
- [ ] All tests passing
- [ ] Docs updated"

# Roadmap section (optional)
ROADMAP_SECTION=""
if [ -n "$ROADMAP_FILE" ] && [ -f "$ROADMAP_FILE" ]; then
  ROADMAP_DATA=$(cat "$ROADMAP_FILE")
  if jq -e '.' <<< "$ROADMAP_DATA" >/dev/null 2>&1; then
    ROADMAP_ROWS=$(jq -r '.[] | "| \(.phase) | \(.epic // "_Not started_") | \(.status // "⚪ Planned") | \(.summary) |"' <<< "$ROADMAP_DATA")
    ROADMAP_SECTION="
### Roadmap

| Phase | Epic | Status | Summary |
|-------|------|--------|---------|
${ROADMAP_ROWS}"
  else
    echo "[$(date +"%H:%M:%S")] WARNING: Roadmap file is not valid JSON, skipping roadmap section" >&2
  fi
fi

EPIC_BODY="## ${FEATURE_ID}

**Branch:** feature/${FEATURE_ID}
**Spec:** docs/features/${FEATURE_ID}/PRD.md

### Implementation Steps
${TASK_LIST_BLOCK}

${QUALITY_GATES}
${ROADMAP_SECTION}"

# ---------------------------------------------------------------------------
# Step 3: Create epic (tracking issue)
# ---------------------------------------------------------------------------

echo "[$(date +"%H:%M:%S")] Creating epic tracking issue..." >&2

EPIC_URL=$(gh issue create \
  --repo "$REPO" \
  --title "Epic: ${FEATURE_ID}" \
  --body "$EPIC_BODY" \
  --label "epic" \
  --label "feature:${FEATURE_ID}" \
  2>"$GH_STDERR")
EPIC_CREATE_EXIT=$?

if [ "$EPIC_CREATE_EXIT" -ne 0 ]; then
  GH_ERR=$(cat "$GH_STDERR")
  echo "[$(date +"%H:%M:%S")] ERROR: Failed to create epic — $GH_ERR" >&2
  # Output partial results so caller can proceed with child issues
  echo "{\"epic\": null, \"issues\": ${ISSUE_MAP}, \"error\": $(echo "$GH_ERR" | jq -Rs '.')}"
  exit $EXIT_FATAL
fi

EPIC_NUMBER=$(parse_issue_number "$EPIC_URL")

if [ -z "$EPIC_NUMBER" ]; then
  echo "[$(date +"%H:%M:%S")] WARNING: Could not parse epic issue number from: $EPIC_URL" >&2
  echo "{\"epic\": null, \"issues\": ${ISSUE_MAP}, \"epic_url\": $(echo "$EPIC_URL" | jq -Rs '.')}"
  exit $EXIT_OK
fi

echo "[$(date +"%H:%M:%S")] Created epic #${EPIC_NUMBER}" >&2

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

echo "{\"epic\": ${EPIC_NUMBER}, \"issues\": ${ISSUE_MAP}}"
