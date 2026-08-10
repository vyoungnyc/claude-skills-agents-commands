#!/bin/bash
# PostCompact hook: re-inject active plan state after context compaction.
#
# Replaces reinject-context.sh. Project-root CLAUDE.md now survives compaction
# natively (Claude Code re-reads it from disk), so re-stating standards here
# would only duplicate CLAUDE.md and drift. The one thing that does NOT survive
# on its own is *where we are in the plan* — so surface that.

shopt -s nullglob
CANDIDATES=( docs/features/*/PLAN_steps.md plans/*/PLAN_steps.md PLAN_steps.md )
shopt -u nullglob

FOUND=0
for f in "${CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  if [ $FOUND -eq 0 ]; then
    echo "## Post-compaction: active plan state"
    FOUND=1
  fi
  echo ""
  echo "### $f"
  # Surface step IDs and status lines without dumping the whole file
  grep -E 'step_id|status|in_progress|pending|blocked|\[ \]|\[✅\]|\[⚠️\]|\[❌\]|\[⏳\]' "$f" 2>/dev/null | head -25
done

[ $FOUND -eq 0 ] && exit 0

echo ""
echo "Re-read the relevant PLAN_steps.md in full before dispatching further steps. Check STATUS.md if present."
