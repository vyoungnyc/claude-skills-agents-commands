#!/bin/bash
# PostToolUse hook (async): Run tests in background after file edits.
# Replaces the manual test-runner coordination from v1 orchestrator.
#
# Triggered on: Edit, Write (source files only, not docs/config)
# Runs asynchronously — does not block Claude's work.
# Results delivered as a systemMessage on the next turn.
#
# Concurrency model (per suite kind — shell and JS coordinate separately):
#
#   marker  — a published "please run the tests" request. Every invocation
#             touches it first, unconditionally. Multiple edits coalesce:
#             touch is idempotent, and one run over current disk contents
#             satisfies every request published before it launched.
#   lock    — runner ownership: a symlink whose target is the holder's PID.
#             `ln -s` creates the link and records the owner in ONE atomic
#             syscall, so there is no instant at which the lock exists
#             without an owner recorded (a mkdir-then-write-pid protocol
#             has exactly that window, and a contender reading the empty
#             record would misjudge the lock stale and reclaim it into dual
#             ownership). Exactly one invocation holds it at a time;
#             everyone else exits immediately after publishing their
#             marker, trusting the holder to consume it.
#
# The lock is held across liveness reasoning, launch, and every rerun —
# closing the claim-to-launch window pidfile-based liveness checking could
# not. Handoff at the end of a runner's life is a release-then-recheck
# loop: after the final failed claim the runner releases the lock and then
# looks at the marker again — a publisher that saw our lock in the gap
# between that final claim and the release has left a marker nobody owns,
# so the runner retakes the lock and consumes it (or a newer invocation
# already has). Release is guarded (only the recorded owner unlinks), so
# no exit path can remove a lock some newer runner now holds.
#
# A crashed runner (kill -9, no trap) cannot wedge testing: an acquirer
# that finds the lock held by a dead PID removes and retakes it, with
# contenders racing on the atomic ln — one winner.

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

# Per-user 0700 state directory for locks and rerun markers. Fully
# predictable names directly in the shared, world-writable ${TMPDIR:-/tmp}
# would let another local user (or a stale root-owned file) pre-create an
# entry this hook cannot delete. Same hardening as scripts/lib/
# poll-common.sh's pidfile directory: create with mode 700, then refuse to
# use it unless it is a real directory we own (mkdir -m only applies the
# mode when it actually creates the directory), repairing the mode since
# -O proves ownership but not permissions.
HOOK_STATE_DIR="${TMPDIR:-/tmp}/claude-auto-test-$(id -u)"
mkdir -m 700 -p "$HOOK_STATE_DIR" 2>/dev/null || true
if [ -L "$HOOK_STATE_DIR" ] || [ ! -d "$HOOK_STATE_DIR" ] || [ ! -O "$HOOK_STATE_DIR" ] \
  || ! chmod 700 "$HOOK_STATE_DIR" 2>/dev/null; then
  # Untrusted state dir: without safe coordination files this hook cannot
  # dedupe or hand off runs, so skip quietly — it is best-effort by design.
  exit 0
fi

# Atomically consume a published run request. rename(2) is atomic — exactly
# one mv wins — and a failed mv (marker absent) cleanly ends the rerun loop,
# so no unconsumable-marker spin guard is needed.
claim_marker() {
  mv "$1" "$1.claimed.$$" 2>/dev/null || return 1
  rm -f "$1.claimed.$$"
  return 0
}

# Acquire runner ownership: a symlink targeting the holder's PID — created
# and owner-stamped in one atomic syscall (see header). On contention, a
# lock held by a live process means a runner exists that will consume our
# published marker — return failure so the caller exits.
#
# A lock whose recorded PID is dead is a crashed runner's leftover, and
# reclaiming it must be single-winner: a bare rm+ln lets a second
# reclaimer — acting on its stale read of the same dead holder — rm the
# first reclaimer's freshly installed LIVE lock and install its own,
# yielding dual owners. Reclamation is therefore serialized through a
# reclaim token taken with the same atomic ln, and the winner re-verifies
# the lock still names the dead holder it read before removing it. Losers
# return failure; their marker stays published for the winner to consume.
# Residual exposure: a reclaimer crashing between token and lock leaves a
# dead token, whose own removal has the same race one level down — that
# requires a second crash inside a microsecond window, accepted.
acquire_lock() {
  ln -s "$$" "$1" 2>/dev/null && return 0
  local holder
  holder=$(readlink "$1" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  local token="$1.reclaim"
  if ! ln -s "$$" "$token" 2>/dev/null; then
    local tholder
    tholder=$(readlink "$token" 2>/dev/null || true)
    if [ -n "$tholder" ] && kill -0 "$tholder" 2>/dev/null; then
      return 1
    fi
    rm -f "$token"
    ln -s "$$" "$token" 2>/dev/null || return 1
  fi
  # Token held: re-verify, then replace. A changed target means a new
  # owner installed between our read and the token grab — leave it alone.
  local rc=1
  if [ "$(readlink "$1" 2>/dev/null || true)" = "$holder" ]; then
    rm -f "$1"
    ln -s "$$" "$1" 2>/dev/null
    rc=$?
  fi
  rm -f "$token"
  return "$rc"
}

# Release only what we own: by the time an exit path runs, a newer runner
# may hold this lock — unlinking it would reopen dual ownership.
release_lock() {
  [ "$(readlink "$1" 2>/dev/null)" = "$$" ] && rm -f "$1"
  return 0
}

# A *.sh edit runs the repo's own shell test suite (REQ-010,
# docs/features/script_tests/PRD.md) instead of the JS runner below — this
# repo's shell scripts have no vitest/jest coverage, only *.test.sh suites.
case "$FILE_PATH" in
  *.sh)
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"
    [ -f "$RUN_TESTS" ] || exit 0

    SH_MARKER="$HOOK_STATE_DIR/shell.rerun"
    SH_LOCK="$HOOK_STATE_DIR/shell.lock"

    # Publish first, then try to become the runner. If the lock is held,
    # the live holder's rerun loop is guaranteed to see this marker after
    # its current run — the edit is never silently dropped.
    touch "$SH_MARKER"
    acquire_lock "$SH_LOCK" || exit 0

    SH_OUT_FILE=$(mktemp "$HOOK_STATE_DIR/shell-out.XXXXXX")
    trap 'release_lock "$SH_LOCK"; rm -f "$SH_OUT_FILE"' EXIT INT TERM

    # Run while requests exist. The first inner iteration normally consumes
    # the marker we just published; a failed first claim means the previous
    # runner consumed it in its final rerun (which tested disk contents
    # that already included our edit), so there is nothing to do. The outer
    # release-then-recheck loop closes the end-of-life gap: a publisher
    # that saw our lock between our final failed claim and the release has
    # left a marker nobody owns — retake the lock and consume it, unless a
    # newer invocation already acquired it (then it inherits the marker).
    SH_EXIT=0
    SH_RAN=0
    while :; do
      while claim_marker "$SH_MARKER"; do
        bash "$RUN_TESTS" >"$SH_OUT_FILE" 2>&1
        SH_EXIT=$?
        SH_RAN=1
      done
      release_lock "$SH_LOCK"
      [ -e "$SH_MARKER" ] || break
      acquire_lock "$SH_LOCK" || break
    done
    [ "$SH_RAN" -eq 1 ] || exit 0
    SH_OUTPUT=$(tail -30 "$SH_OUT_FILE" 2>/dev/null || true)

    if [ "$SH_EXIT" -eq 0 ]; then
      SH_SUMMARY=$(echo "$SH_OUTPUT" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | head -1)
      jq -n --arg file "$FILE_PATH" --arg summary "$SH_SUMMARY" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          systemMessage: ("Shell tests passing after editing " + $file + " (" + $summary + ")")
        }
      }'
    else
      SH_TRIMMED=$(echo "$SH_OUTPUT" | tail -20)
      jq -n --arg file "$FILE_PATH" --arg output "$SH_TRIMMED" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          systemMessage: ("SHELL TESTS FAILED after editing " + $file + ":\n```\n" + $output + "\n```\nRoute to backend-coder for fixes.")
        }
      }'
    fi
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

MARKER="$HOOK_STATE_DIR/js.rerun"
LOCK="$HOOK_STATE_DIR/js.lock"

# Publish-then-lock, same protocol as the shell branch.
touch "$MARKER"
acquire_lock "$LOCK" || exit 0

OUT_FILE=$(mktemp "$HOOK_STATE_DIR/js-out.XXXXXX")
trap 'release_lock "$LOCK"; rm -f "$OUT_FILE"' EXIT INT TERM

# Release-then-recheck handoff — same protocol as the shell branch.
TEST_EXIT=0
RAN=0
while :; do
  while claim_marker "$MARKER"; do
    "${TEST_CMD[@]}" >"$OUT_FILE" 2>&1
    TEST_EXIT=$?
    RAN=1
  done
  release_lock "$LOCK"
  [ -e "$MARKER" ] || break
  acquire_lock "$LOCK" || break
done
[ "$RAN" -eq 1 ] || exit 0
TEST_OUTPUT=$(tail -30 "$OUT_FILE" 2>/dev/null || true)

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
