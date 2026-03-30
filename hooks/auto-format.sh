#!/bin/bash
# PostToolUse hook: Auto-format files after edits.
# Triggered on: Edit, Write (source files only)
# Runs Prettier if available, then ESLint fix.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Skip non-formattable files
case "$FILE_PATH" in
  *.md|*.json|*.lock|*.log|*.env*|*.txt)
    exit 0
    ;;
  */node_modules/*|*/.claude/*|*/dist/*|*/build/*)
    exit 0
    ;;
esac

# Only format TS/JS/TSX/JSX/CSS files
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.css|*.scss)
    ;;
  *)
    exit 0
    ;;
esac

# Run Prettier if available
if [ -f "node_modules/.bin/prettier" ] || command -v prettier &>/dev/null; then
  npx prettier --write "$FILE_PATH" 2>/dev/null
fi

# Run ESLint fix if available
if [ -f "node_modules/.bin/eslint" ] || command -v eslint &>/dev/null; then
  npx eslint --fix "$FILE_PATH" 2>/dev/null
fi

exit 0
