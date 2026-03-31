#!/bin/bash
# PostToolUse hook: Auto-format files after edits.
# Triggered on: Edit, Write (source files only)
# Runs Prettier if available, then ESLint fix.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only format TS/JS/TSX/JSX/CSS source files, skip everything else
case "$FILE_PATH" in
  */node_modules/*|*/.claude/*|*/dist/*|*/build/*)
    exit 0
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.css|*.scss)
    ;;
  *)
    exit 0
    ;;
esac

# Track what ran
FORMATTED=""

# Run Prettier (npx handles missing tool gracefully)
if npx prettier --write -- "$FILE_PATH" 2>/dev/null; then
  FORMATTED="prettier"
fi

# Run ESLint fix (npx handles missing tool gracefully)
if npx eslint --fix -- "$FILE_PATH" 2>/dev/null; then
  FORMATTED="${FORMATTED:+$FORMATTED+}eslint"
fi

# Report what happened
if [ -n "$FORMATTED" ]; then
  jq -n --arg file "$FILE_PATH" --arg tools "$FORMATTED" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      systemMessage: ("Auto-formatted " + $file + " (" + $tools + ")")
    }
  }'
fi

exit 0
