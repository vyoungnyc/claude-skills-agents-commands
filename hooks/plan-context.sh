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

# Extract a plan's unfinished work, capped at 20 lines. Two dialects:
#
#   1. step-based plans with per-step `status: "pending|in_progress|blocked|
#      completed"` lines — the authoritative signal. Acceptance-criteria
#      checkboxes (`- [ ]`) inside a completed step stay unchecked forever,
#      so a bare `[ ]` grep would label every finished plan active. step_id
#      lines are paired with their step's status before the cap: an
#      unconditional step_id match would emit every completed step's ID too,
#      and 20+ completed steps would push the unfinished step past the
#      limit. A held step_id is flushed when an unfinished status follows,
#      cleared when a finished status follows, and — critically — flushed at
#      the next step_id or EOF when NO status line followed at all: a step
#      without a status: field (freshly authored, hand-edited) is treated as
#      unfinished and surfaced, never silently dropped (fail open).
#   2. checkbox-only plans (no status: lines) — there the task-tracking
#      markers `[ ]`/`[⚠️]`/`[⏳]` are the only signal we have.
#
# A plan is active iff this output is non-empty — detection and display use
# the same extraction, so a plan whose only unfinished step is status-less
# is still injected rather than skipped.
active_lines() {
  if grep -qE '^[[:space:]]*status:' "$1" 2>/dev/null; then
    awk '
      # Anchored to the actual field syntax (optional list dash and
      # backticks, then a colon) — bare /step_id/ also matched PROSE
      # mentioning step_id after a completed step, storing it as a
      # phantom status-less step and reinjecting finished plans forever.
      /^[[:space:]]*-?[[:space:]]*`?step_id`?[[:space:]]*:/ { if (held != "") print held; held = $0; next }
      /^[[:space:]]*status:[[:space:]]*"?(pending|in_progress|blocked)/ {
        if (held != "") { print held; held = "" }
        print; next
      }
      /^[[:space:]]*status:/ { held = "" }
      END { if (held != "") print held }
    ' "$1" 2>/dev/null | head -20
  else
    grep -E '\[ \]|\[⚠️\]|\[⏳\]' "$1" 2>/dev/null | head -20
  fi
}

FOUND=0
for f in "${CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  # Skip fully-completed plans: a finished feature's PLAN_steps.md stays in
  # the repo forever, and re-injecting it after every compaction wastes
  # context and can misdirect dispatch toward already-shipped work.
  ACTIVE=$(active_lines "$f")
  [ -n "$ACTIVE" ] || continue
  if [ $FOUND -eq 0 ]; then
    echo "## Post-compaction: active plan state"
    FOUND=1
  fi
  echo ""
  echo "### $f"
  echo "$ACTIVE"
  DONE_COUNT=$(grep -cE 'status:[[:space:]]*"?completed|\[✅\]|\[❌\]' "$f" 2>/dev/null)
  [ "${DONE_COUNT:-0}" -gt 0 ] && echo "(${DONE_COUNT} completed/closed entries omitted)"
done

[ $FOUND -eq 0 ] && exit 0

echo ""
echo "Re-read the relevant PLAN_steps.md in full before dispatching further steps. Check STATUS.md if present."
