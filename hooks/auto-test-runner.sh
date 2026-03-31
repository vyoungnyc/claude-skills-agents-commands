#!/bin/bash
# PostToolUse hook (async): Run tests in background after file edits.
# Replaces the manual test-runner coordination from v1 orchestrator.
#
# Triggered on: Edit, Write (source files only, not docs/config)
# Runs asynchronously — does not block Claude's work.
# Results delivered as a systemMessage on the next turn.
#
# Kill + restart: if a previous test run is still in flight, kill it
# and start fresh so tests always run against the latest code.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Skip non-source files — don't run tests for docs, config, markdown, etc.
case "$FILE_PATH" in
  *.md|*.json|*.yml|*.yaml|*.env*|*.lock|*.log|*.txt)
    exit 0
    ;;
  */docs/*|*/config/*|*/.claude/*|*/node_modules/*|*/dist/*|*/build/*)
    exit 0
    ;;
esac

# Determine test runner (also serves as framework detection — exits if none found)
if [ -f "vitest.config.ts" ] || [ -f "vitest.config.js" ]; then
  TEST_CMD=(npx vitest run --reporter=verbose)
elif [ -f "jest.config.js" ] || [ -f "jest.config.ts" ]; then
  TEST_CMD=(npx jest --verbose)
else
  exit 0
fi

# Kill any previous test run so we always test the latest code
PIDFILE="${TMPDIR:-/tmp}/auto-test-runner.pid"
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

# Capture exit code via pipefail (piping to tail would otherwise lose it)
set -o pipefail
TEST_OUTPUT=$("${TEST_CMD[@]}" 2>&1 | tail -30)
TEST_EXIT=$?
set +o pipefail

# Build result message
if [ $TEST_EXIT -eq 0 ]; then
  PASS_COUNT=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ passed' | head -1)
  jq -n --arg file "$FILE_PATH" --arg passes "$PASS_COUNT" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      systemMessage: ("Tests passing after editing " + $file + " (" + $passes + ")")
    }
  }'
else
  # Truncate output to avoid flooding context
  TRIMMED=$(echo "$TEST_OUTPUT" | tail -20)
  jq -n --arg file "$FILE_PATH" --arg output "$TRIMMED" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      systemMessage: ("TESTS FAILED after editing " + $file + ":\n```\n" + $output + "\n```\nRoute to backend-coder or frontend-coder for fixes.")
    }
  }'
fi
