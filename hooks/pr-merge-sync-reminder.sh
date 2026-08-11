#!/bin/bash
# PostToolUse hook: remind to sync ~/.claude after a squash merge in this repo.
# Triggered on: Bash commands running `gh pr merge` with --squash or -s.
#
# scripts/sync-claude-config.sh only reaches the live global config on
# --apply, and that step is easy to forget right after a merge lands. This
# surfaces a reminder so the agent asks the user whether to run it now,
# instead of the drift silently piling up again (see PR #33's motivating
# case: three merged changes never made it to ~/.claude by hand).

INPUT=$(cat)

# Fast path: skip jq parsing for non-gh commands
[[ "$INPUT" == *'"gh '* ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

echo "$COMMAND" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge' || exit 0
echo "$COMMAND" | grep -qE '(^|[[:space:]])(--squash|-s)([[:space:]]|$)' || exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    systemMessage: "PR squash-merged. Ask the user whether to run scripts/sync-claude-config.sh --apply to deploy this change to their live ~/.claude config."
  }
}'
exit 0
