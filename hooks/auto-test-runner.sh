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
#   lock    — runner ownership, an atomic mkdir held for the runner's whole
#             lifetime (launch, wait, rerun loop). Exactly one invocation
#             holds it at a time; everyone else exits immediately after
#             publishing their marker, trusting the lock holder's rerun
#             loop to consume it.
#
# The lock closes the claim-to-launch window that pidfile-based liveness
# checking could not: with a pidfile, an invocation arriving after a runner
# consumed the marker but before it wrote its child PID saw "no live
# runner", published-and-claimed a fresh marker, and launched a second
# concurrent suite. Ownership here is held across that entire interval, so
# the sequence "publish marker → fail to get lock → exit" is always safe:
# a live lock holder is guaranteed to check the marker again after its
# current run finishes.
#
# The lock dir records the holder's PID so a crashed runner (kill -9, no
# trap) cannot wedge testing forever: an acquirer that finds the lock held
# by a dead process removes and retakes it.

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

# Acquire runner ownership: atomic mkdir, holder PID recorded inside. On
# contention, a lock held by a live process means a runner exists whose
# rerun loop will consume our published marker — return failure so the
# caller exits. A lock held by a dead process is a crashed runner's
# leftover: remove and retake it (two concurrent reclaimers race on the
# inner mkdir, which only one can win).
acquire_lock() {
  if mkdir "$1" 2>/dev/null; then
    echo $$ > "$1/pid"
    return 0
  fi
  local holder
  holder=$(cat "$1/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  rm -rf "$1"
  mkdir "$1" 2>/dev/null || return 1
  echo $$ > "$1/pid"
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
    trap 'rm -rf "$SH_LOCK"; rm -f "$SH_OUT_FILE"' EXIT INT TERM

    # Run while requests exist. The first iteration normally consumes the
    # marker we just published; a failed first claim means the previous
    # runner consumed it in its final rerun (which tested disk contents
    # that already included our edit), so there is nothing to do.
    SH_EXIT=0
    SH_RAN=0
    while claim_marker "$SH_MARKER"; do
      bash "$RUN_TESTS" >"$SH_OUT_FILE" 2>&1
      SH_EXIT=$?
      SH_RAN=1
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
trap 'rm -rf "$LOCK"; rm -f "$OUT_FILE"' EXIT INT TERM

TEST_EXIT=0
RAN=0
while claim_marker "$MARKER"; do
  "${TEST_CMD[@]}" >"$OUT_FILE" 2>&1
  TEST_EXIT=$?
  RAN=1
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
