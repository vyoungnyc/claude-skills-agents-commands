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

# A plan is active iff it still has unfinished work. Two plan dialects exist:
#   1. step-based plans with per-step `status: "pending|in_progress|blocked|
#      completed"` lines — the authoritative signal. Acceptance-criteria
#      checkboxes (`- [ ]`) inside a completed step stay unchecked forever,
#      so a bare `[ ]` grep would label every finished plan active.
#   2. checkbox-only plans (no status: lines) — there the task-tracking
#      markers `[ ]`/`[⚠️]`/`[⏳]` are the only signal we have.
plan_is_active() {
  if grep -qE '^[[:space:]]*status:' "$1" 2>/dev/null; then
    grep -qE '^[[:space:]]*status:[[:space:]]*"?(pending|in_progress|blocked)' "$1" 2>/dev/null
  else
    grep -qE '\[ \]|\[⚠️\]|\[⏳\]' "$1" 2>/dev/null
  fi
}

FOUND=0
for f in "${CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  # Skip fully-completed plans: a finished feature's PLAN_steps.md stays in
  # the repo forever, and re-injecting it after every compaction wastes
  # context and can misdirect dispatch toward already-shipped work.
  plan_is_active "$f" || continue
  if [ $FOUND -eq 0 ]; then
    echo "## Post-compaction: active plan state"
    FOUND=1
  fi
  echo ""
  echo "### $f"
  # Unfinished/blocked step and status lines only — a flat head -25 over all
  # status lines truncates in file order, so early completed steps could
  # crowd out the one in_progress step compaction most needs to restore.
  grep -E 'step_id|status:[[:space:]]*"?(pending|in_progress|blocked)|\[ \]|\[⚠️\]|\[⏳\]' "$f" 2>/dev/null | head -20
  DONE_COUNT=$(grep -cE 'status:[[:space:]]*"?completed|\[✅\]|\[❌\]' "$f" 2>/dev/null)
  [ "${DONE_COUNT:-0}" -gt 0 ] && echo "(${DONE_COUNT} completed/closed entries omitted)"
done

[ $FOUND -eq 0 ] && exit 0

echo ""
echo "Re-read the relevant PLAN_steps.md in full before dispatching further steps. Check STATUS.md if present."
