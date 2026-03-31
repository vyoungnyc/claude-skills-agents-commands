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
if ! echo "$PLAN_STEPS" | jq -e '.' >/dev/null 2>&1; then
  echo '{"error": "Plan steps file is not valid JSON"}' >&2
  exit $EXIT_USAGE
fi

STEP_COUNT=$(echo "$PLAN_STEPS" | jq 'length')
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

echo "[$(date +"%H:%M:%S")] Creating GitHub issues for feature '$FEATURE_ID' ($STEP_COUNT steps)..." >&2

# ---------------------------------------------------------------------------
# Step 1: Create child issues
# ---------------------------------------------------------------------------

# Accumulate {"step_id": issue_number, ...} mapping
ISSUE_MAP="{}"

# Build task list lines for epic (populated as we create issues)
TASK_LIST_LINES=()

for i in $(seq 0 $((STEP_COUNT - 1))); do
  STEP=$(echo "$PLAN_STEPS" | jq ".[$i]")
  STEP_ID=$(echo "$STEP" | jq -r '.step_id')
  TITLE=$(echo "$STEP" | jq -r '.title')
  COMPLEXITY=$(echo "$STEP" | jq -r '.complexity // "medium"')
  BATCH_HINT=$(echo "$STEP" | jq -r '.batch_hint // "general"')
  FILE_DOMAIN=$(echo "$STEP" | jq -r '.file_domain | join(", ")')
  DEPS_RAW=$(echo "$STEP" | jq -r '.dependencies // [] | join(", ")')

  if [ -z "$DEPS_RAW" ]; then
    DEPS_LINE="_None_"
  else
    DEPS_LINE="$DEPS_RAW"
  fi

  # Build acceptance criteria checkboxes
  AC_CHECKBOXES=$(echo "$STEP" | jq -r '.acceptance_criteria // [] | .[] | "- [ ] \(.)"' | sed 's/^//')
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

  LABELS="feature:${FEATURE_ID},domain:${BATCH_HINT},complexity:${COMPLEXITY}"

  echo "[$(date +"%H:%M:%S")] Creating child issue for $STEP_ID: $TITLE..." >&2

  ISSUE_URL=$(gh issue create \
    --title "${STEP_ID}: ${TITLE}" \
    --body "$ISSUE_BODY" \
    --label "$LABELS" \
    2>&1)

  if [ $? -ne 0 ]; then
    echo "[$(date +"%H:%M:%S")] WARNING: Failed to create issue for $STEP_ID — gh error: $ISSUE_URL" >&2
    # Continue; we'll note the failure in the mapping
    ISSUE_MAP=$(echo "$ISSUE_MAP" | jq --arg sid "$STEP_ID" --argjson num "null" '. + {($sid): $num}')
    TASK_LIST_LINES+=("- [ ] (failed) ${STEP_ID}: ${TITLE}")
    continue
  fi

  ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || true)
  if [ -z "$ISSUE_NUMBER" ]; then
    # Try extracting from URL format https://github.com/owner/repo/issues/123
    ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || true)
  fi

  if [ -z "$ISSUE_NUMBER" ]; then
    echo "[$(date +"%H:%M:%S")] WARNING: Could not parse issue number from: $ISSUE_URL" >&2
    ISSUE_MAP=$(echo "$ISSUE_MAP" | jq --arg sid "$STEP_ID" --argjson num "null" '. + {($sid): $num}')
    TASK_LIST_LINES+=("- [ ] (unknown) ${STEP_ID}: ${TITLE}")
    continue
  fi

  echo "[$(date +"%H:%M:%S")] Created #${ISSUE_NUMBER} for $STEP_ID" >&2
  ISSUE_MAP=$(echo "$ISSUE_MAP" | jq --arg sid "$STEP_ID" --argjson num "$ISSUE_NUMBER" '. + {($sid): $num}')
  TASK_LIST_LINES+=("- [ ] #${ISSUE_NUMBER} ${STEP_ID}: ${TITLE}")
done

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
  if echo "$ROADMAP_DATA" | jq -e '.' >/dev/null 2>&1; then
    ROADMAP_ROWS=$(echo "$ROADMAP_DATA" | jq -r '.[] | "| \(.phase) | \(.epic // "_Not started_") | \(.status // "⚪ Planned") | \(.summary) |"')
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
  --title "Epic: ${FEATURE_ID}" \
  --body "$EPIC_BODY" \
  --label "epic,feature:${FEATURE_ID}" \
  2>&1)

EPIC_CREATE_EXIT=$?

if [ "$EPIC_CREATE_EXIT" -ne 0 ]; then
  echo "[$(date +"%H:%M:%S")] ERROR: Failed to create epic — $EPIC_URL" >&2
  # Output partial results so caller can proceed with child issues
  echo "{\"epic\": null, \"issues\": ${ISSUE_MAP}, \"error\": $(echo "$EPIC_URL" | jq -Rs '.')}"
  exit $EXIT_FATAL
fi

EPIC_NUMBER=$(echo "$EPIC_URL" | grep -oE '[0-9]+$' || true)
if [ -z "$EPIC_NUMBER" ]; then
  EPIC_NUMBER=$(echo "$EPIC_URL" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || true)
fi

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
