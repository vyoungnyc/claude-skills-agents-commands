#!/bin/bash
# Create local file-based epic and issues when not in a GitHub repo.
# Fallback for GitLab repos or repos without gh CLI access.
# Files are stored in plans/ (gitignored) to avoid committing tracking artifacts.
#
# Usage: create-local-issues.sh <feature_id> <plan_steps_json_file> [roadmap_phases_json_file]
#
# Same input format as create-github-issues.sh for interchangeability.
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
#   }
# ]
#
# Creates:
#   plans/{feature_id}/issue-0000.md  (epic / tracking issue)
#   plans/{feature_id}/issue-0001.md  (step_01)
#   plans/{feature_id}/issue-0002.md  (step_02)
#   ...
#
# Outputs JSON (same shape as create-github-issues.sh):
#   {"epic": "plans/{feature_id}/issue-0000.md", "issues": {"step_01": "plans/{feature_id}/issue-0001.md", ...}}

set -uo pipefail

EXIT_OK=0
EXIT_FATAL=1
EXIT_USAGE=10

FEATURE_ID="${1:-}"
PLAN_STEPS_FILE="${2:-}"
ROADMAP_FILE="${3:-}"

if [ -z "$FEATURE_ID" ] || [ -z "$PLAN_STEPS_FILE" ]; then
  echo '{"error": "Usage: create-local-issues.sh <feature_id> <plan_steps_json_file> [roadmap_phases_json_file]"}' >&2
  exit $EXIT_USAGE
fi

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required but not installed"}' >&2
  exit $EXIT_FATAL
fi

if [ ! -f "$PLAN_STEPS_FILE" ]; then
  echo "{\"error\": \"Plan steps file not found: $PLAN_STEPS_FILE\"}" >&2
  exit $EXIT_USAGE
fi

# Operate from git repo root so plans/ and .gitignore are in the right place
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$REPO_ROOT" ]; then
  cd "$REPO_ROOT"
fi

# Add plans/ to .gitignore if inside a git repo and not already ignored.
# Set SKIP_GITIGNORE=1 to disable this behavior.
if [ -n "$REPO_ROOT" ] && [ "${SKIP_GITIGNORE:-0}" != "1" ]; then
  if ! git check-ignore -q "plans/" 2>/dev/null; then
    GITIGNORE=".gitignore"
    if [ -f "$GITIGNORE" ]; then
      echo "" >> "$GITIGNORE"
      echo "# Local issue tracking (not committed)" >> "$GITIGNORE"
      echo "plans/" >> "$GITIGNORE"
      echo "[create-local-issues] Added plans/ to .gitignore" >&2
    else
      echo "# Local issue tracking (not committed)" > "$GITIGNORE"
      echo "plans/" >> "$GITIGNORE"
      echo "[create-local-issues] Created .gitignore with plans/" >&2
    fi
  fi
fi

# Create plans directory
PLANS_DIR="plans/${FEATURE_ID}"
mkdir -p "$PLANS_DIR"

# Cache file content to avoid re-reading from disk on every loop iteration
PLAN_STEPS=$(cat "$PLAN_STEPS_FILE")
if ! jq -e '.' <<< "$PLAN_STEPS" >/dev/null 2>&1; then
  echo '{"error": "Plan steps file is not valid JSON"}' >&2
  exit $EXIT_USAGE
fi
STEP_COUNT=$(jq 'length' <<< "$PLAN_STEPS")
ISSUE_MAP_FILE=$(mktemp)
trap 'rm -f "$ISSUE_MAP_FILE"' EXIT
TASK_LIST=""
DATE=$(date +%Y-%m-%d)

# Escape YAML scalars — wrap in single quotes, escape internal single quotes
yaml_escape() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# Refuse to overwrite existing issue files unless FORCE_OVERWRITE=1
if [ "${FORCE_OVERWRITE:-0}" != "1" ] && ls "$PLANS_DIR"/issue-*.md &>/dev/null; then
  echo "{\"error\": \"Issue files already exist in $PLANS_DIR/. Set FORCE_OVERWRITE=1 to overwrite, or delete them first.\"}" >&2
  exit 1
fi

# Create child issues first (issue-0001.md, issue-0002.md, ...)
for i in $(seq 0 $((STEP_COUNT - 1))); do
  ISSUE_NUM=$((i + 1))
  ISSUE_FILE="$PLANS_DIR/issue-$(printf '%04d' $ISSUE_NUM).md"

  # Extract all fields in one jq call (avoids 7 separate jq forks per step)
  eval "$(jq -r --argjson i "$i" '.[$i] | @sh "STEP_ID=\(.step_id) TITLE=\(.title) COMPLEXITY=\(.complexity // "medium") BATCH_HINT=\(.batch_hint // "general") FILE_DOMAIN=\(.file_domain | join(", ")) DEPS=\(.dependencies | if length > 0 then join(", ") else "none" end)"' <<< "$PLAN_STEPS")"

  TITLE_ESCAPED=$(yaml_escape "$TITLE")
  STEP_ID_ESCAPED=$(yaml_escape "$STEP_ID")

  # Build acceptance criteria checkboxes
  AC_LINES=$(jq -r --argjson i "$i" '.[$i].acceptance_criteria[]? | "- [ ] " + .' <<< "$PLAN_STEPS")
  if [ -z "$AC_LINES" ]; then
    AC_LINES="- [ ] (no acceptance criteria defined)"
  fi

  cat > "$ISSUE_FILE" << ISSUE_EOF
---
step_id: ${STEP_ID_ESCAPED}
title: ${TITLE_ESCAPED}
status: open
complexity: ${COMPLEXITY}
domain: ${BATCH_HINT}
feature: ${FEATURE_ID}
created: ${DATE}
---

# ${STEP_ID}: ${TITLE}

## Acceptance Criteria
${AC_LINES}

## Context
- **File domain:** ${FILE_DOMAIN}
- **Complexity:** ${COMPLEXITY}
- **Dependencies:** ${DEPS}
- **Batch hint:** ${BATCH_HINT}

## Notes
_Implementation notes and progress will be added here._
ISSUE_EOF

  # Add to issue map (file-based accumulation avoids O(n²) jq rebuild)
  echo "\"$STEP_ID\": \"$ISSUE_FILE\"" >> "$ISSUE_MAP_FILE"

  # Add to epic task list
  TASK_LIST="${TASK_LIST}
- [ ] [${STEP_ID}: ${TITLE}](${ISSUE_FILE}) — complexity: ${COMPLEXITY}, domain: ${BATCH_HINT}"
done

# Build roadmap section
ROADMAP_SECTION=""
if [ -n "$ROADMAP_FILE" ] && [ -f "$ROADMAP_FILE" ]; then
  ROADMAP_SECTION="
## Roadmap

| Phase | Status | Summary |
|-------|--------|---------|"
  ROADMAP_DATA=$(cat "$ROADMAP_FILE")
  ROADMAP_ROWS=$(jq -r 'to_entries | .[] | "| \(.value.phase) | \(if .key == 0 then "In Progress" else "Planned" end) | \(.value.summary) |"' <<< "$ROADMAP_DATA" 2>/dev/null || true)
  if [ -n "$ROADMAP_ROWS" ]; then
    ROADMAP_SECTION="${ROADMAP_SECTION}
${ROADMAP_ROWS}"
  fi
fi

# Create epic (issue-0000.md)
EPIC_FILE="$PLANS_DIR/issue-0000.md"
cat > "$EPIC_FILE" << EPIC_EOF
---
type: epic
feature: ${FEATURE_ID}
status: open
created: ${DATE}
---

# Epic: ${FEATURE_ID}

**Branch:** feature/${FEATURE_ID}
**Created:** ${DATE}
**Steps:** ${STEP_COUNT}

## Implementation Steps
${TASK_LIST}

## Quality Gates
- [ ] Code review passed
- [ ] Security review passed
- [ ] All tests passing
- [ ] Docs updated
${ROADMAP_SECTION}

## Progress
_Updated automatically as issues are closed._
EPIC_EOF

# Build ISSUE_MAP from accumulated entries (avoids O(n²) jq rebuilding per iteration)
ISSUE_MAP=$(jq -n "{ $(paste -sd',' "$ISSUE_MAP_FILE") }")
rm -f "$ISSUE_MAP_FILE"

# Output JSON (same shape as create-github-issues.sh)
jq -n --arg epic "$EPIC_FILE" --argjson issues "$ISSUE_MAP" '{epic: $epic, issues: $issues}'
