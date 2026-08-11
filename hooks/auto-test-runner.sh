#!/bin/bash
# PostToolUse hook (async): Run tests in background after file edits.
# Replaces the manual test-runner coordination from v1 orchestrator.
#
# Triggered on: Edit, Write (source files only, not docs/config)
# Runs asynchronously — does not block Claude's work.
# Results delivered as a systemMessage on the next turn.
#
# Skip-if-in-flight: hook invocations run synchronously inside this process
# (there is no `&` around the suite invocation before the pidfile is even
# written below the *.sh branch), so a same-process kill-and-restart can
# never fire — the "kill" would need to interrupt code that hasn't reached
# the point of checking for a kill yet, and by the time a later invocation
# runs, the earlier invocation's own trap has already cleaned up its
# pidfile. That combination let concurrent hook invocations orphan test
# processes instead of ever actually restarting them. Both branches below
# background the actual test-suite invocation, record the *child's* PID (not
# this hook process's own $$), and skip launching a new run outright if a
# still-live run is already recorded — simpler and correct, vs. attempting
# to kill a process this same synchronous hook invocation can't outlive long
# enough to interrupt.

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

# Per-user 0700 state directory for pidfiles and rerun markers. Fully
# predictable names directly in the shared, world-writable ${TMPDIR:-/tmp}
# would let another local user (or a stale root-owned file) pre-create an
# entry this hook cannot delete — an undeletable rerun marker turns the
# consume loop below into an endless full-suite rerun. Same hardening as
# scripts/lib/poll-common.sh's pidfile directory: create with mode 700,
# then refuse to use it unless it is a real directory we own (mkdir -m
# only applies the mode when it actually creates the directory), repairing
# the mode since -O proves ownership but not permissions.
HOOK_STATE_DIR="${TMPDIR:-/tmp}/claude-auto-test-$(id -u)"
mkdir -m 700 -p "$HOOK_STATE_DIR" 2>/dev/null || true
if [ -L "$HOOK_STATE_DIR" ] || [ ! -d "$HOOK_STATE_DIR" ] || [ ! -O "$HOOK_STATE_DIR" ] \
  || ! chmod 700 "$HOOK_STATE_DIR" 2>/dev/null; then
  # Untrusted state dir: without safe coordination files this hook cannot
  # dedupe or hand off runs, so skip quietly — it is best-effort by design.
  exit 0
fi

# Atomically claim a rerun request. `rm`-based consumption is not mutually
# exclusive: when the previous child has just exited, the owner's rerun
# loop and a touch-first later invocation can each see the marker, each
# "consume" it (rm -f of an already-unlinked file still succeeds), and
# both launch the suite, racing on the shared pidfile. rename(2) is atomic
# — exactly one mv wins, so exactly one invocation becomes the runner for
# any published request. A failed claim also cleanly ends the rerun loop
# if the marker were ever unremovable, so no spin guard is needed.
claim_marker() {
  mv "$1" "$1.claimed.$$" 2>/dev/null || return 1
  rm -f "$1.claimed.$$"
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

    # Skip-if-in-flight pattern on its own pidfile so a shell-suite run never
    # collides with a vitest/jest run below. The pidfile records the *child*
    # test-runner process's PID, not this hook invocation's own $$ — the
    # previous approach recorded the hook's own PID, which is meaningless to
    # a later invocation (the hook process that owned it has usually already
    # exited by the time anyone reads the pidfile back) and can never
    # actually be interrupted mid-run since it's blocked synchronously
    # capturing output.
    SH_PIDFILE="$HOOK_STATE_DIR/shell.pid"
    # Rerun marker: this hook runs async, so a second invocation can arrive
    # while a run is already in flight testing *older* file contents. Bare
    # skip-if-in-flight would drop that newer edit untested — the only
    # reported result would cover the stale contents. Instead the skipping
    # invocation leaves a marker, and the in-flight invocation re-runs the
    # suite once after its current run finishes. Multiple mid-run edits
    # coalesce into a single rerun (touch is idempotent), which is correct:
    # the rerun tests whatever is on disk at that point.
    SH_RERUN_MARKER="$HOOK_STATE_DIR/shell.rerun"

    # Publish the rerun request BEFORE the in-flight liveness check, not
    # after: a touch that happens after confirming the PID is alive races
    # the owner's post-wait marker check — the run can exit and the owner
    # consume (and see no) marker between this invocation's kill -0 and its
    # touch, leaving a marker nobody will ever read. Touch-first closes
    # that: either the owner is still in wait and will consume the marker
    # afterward, or the run has already finished, the liveness check below
    # falls through, and this invocation becomes the runner itself —
    # clearing the marker it just set before launching.
    touch "$SH_RERUN_MARKER"
    if [ -f "$SH_PIDFILE" ]; then
      OLD_SH_PID=$(cat "$SH_PIDFILE" 2>/dev/null || true)
      if [ -n "$OLD_SH_PID" ] && kill -0 "$OLD_SH_PID" 2>/dev/null; then
        # Confirm the live PID is actually a shell-suite run before treating
        # it as "in flight" — a recycled PID could otherwise belong to some
        # unrelated process, causing this hook to wrongly skip a run that
        # should have started.
        OLD_SH_COMM=$(ps -o comm= -p "$OLD_SH_PID" 2>/dev/null || true)
        case "$OLD_SH_COMM" in
          *bash*|*run-tests*)
            exit 0
            ;;
        esac
      fi
    fi

    # Become the runner only by atomically claiming the request published
    # above (the run below tests current disk contents, which already
    # include whatever edit set the marker). A failed claim means another
    # invocation — an in-flight owner's rerun loop — took it and will run
    # the suite; launching here too would duplicate the run. Claim BEFORE
    # registering the cleanup trap: a loser's exit must not tear down the
    # shared pidfile the winning runner just wrote.
    claim_marker "$SH_RERUN_MARKER" || exit 0

    SH_OUT_FILE=$(mktemp "$HOOK_STATE_DIR/shell-out.XXXXXX")
    # Remove the shared pidfile only if it still records OUR child — by the
    # time this runner exits, a newer invocation may already have claimed a
    # fresh rerun request and written its own PID there; unconditional rm
    # would blind later invocations to that still-running suite.
    cleanup_sh() {
      [ "$(cat "$SH_PIDFILE" 2>/dev/null)" = "${SH_PID:-}" ] && rm -f "$SH_PIDFILE"
      rm -f "$SH_OUT_FILE"
    }
    trap cleanup_sh EXIT INT TERM

    # `set -m` gives the backgrounded run its own process group (where the
    # shell supports job control in a script), so a future kill of the
    # recorded child PID cannot also reach this hook process's own group.
    set -m 2>/dev/null || true
    bash "$RUN_TESTS" >"$SH_OUT_FILE" 2>&1 &
    SH_PID=$!
    set +m 2>/dev/null || true
    echo "$SH_PID" > "$SH_PIDFILE"

    wait "$SH_PID"
    SH_EXIT=$?

    # An edit landed mid-run: its invocation skipped and left the marker, so
    # the result above may describe stale contents. Re-run once against
    # what's on disk now and report that instead. Loop bounded at one extra
    # pass per marker cycle — a marker set during the rerun triggers another.
    # claim_marker keeps runner ownership exclusive: if a newer invocation
    # claimed this request first (its liveness check saw our child already
    # exited), the claim fails and that invocation runs instead.
    while claim_marker "$SH_RERUN_MARKER"; do
      set -m 2>/dev/null || true
      bash "$RUN_TESTS" >"$SH_OUT_FILE" 2>&1 &
      SH_PID=$!
      set +m 2>/dev/null || true
      echo "$SH_PID" > "$SH_PIDFILE"
      wait "$SH_PID"
      SH_EXIT=$?
    done
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

# Skip-if-in-flight: same pattern as the shell-suite branch above — record
# the backgrounded test-runner child's PID (not this hook's own $$) and
# skip starting a second run rather than trying to kill-and-restart, which
# can't interrupt a process this same synchronous hook invocation is blocked
# waiting on anyway.
PIDFILE="$HOOK_STATE_DIR/js.pid"
# Same rerun-marker pattern as the shell-suite branch: an edit arriving while
# a run is in flight must trigger one coalesced rerun, not be silently dropped.
RERUN_MARKER="$HOOK_STATE_DIR/js.rerun"

# Touch-before-check, same reasoning as the shell branch: publishing the
# rerun request after the liveness check races the owner's post-wait marker
# consumption; touch-first guarantees the marker is either consumed by the
# still-waiting owner or cleared by this invocation when it becomes the
# runner itself.
touch "$RERUN_MARKER"
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Identity check before treating this PID as "in flight" — vitest/jest
    # run under node via npx, so confirm the live process is actually a
    # node-based test runner before skipping on its account.
    OLD_COMM=$(ps -o comm= -p "$OLD_PID" 2>/dev/null || true)
    case "$OLD_COMM" in
      *node*|*npx*|*vitest*|*jest*)
        exit 0
        ;;
    esac
  fi
fi

# Become the runner only via atomic claim — same reasoning as the shell
# branch: a failed claim means an in-flight owner's rerun loop took this
# request and will run. Claim BEFORE registering the cleanup trap so a
# loser's exit cannot tear down the winning runner's pidfile.
claim_marker "$RERUN_MARKER" || exit 0

OUT_FILE=$(mktemp "$HOOK_STATE_DIR/js-out.XXXXXX")
# Conditional pidfile cleanup — same reasoning as the shell branch.
cleanup_js() {
  [ "$(cat "$PIDFILE" 2>/dev/null)" = "${TEST_PID:-}" ] && rm -f "$PIDFILE"
  rm -f "$OUT_FILE"
}
trap cleanup_js EXIT INT TERM

set -m 2>/dev/null || true
"${TEST_CMD[@]}" >"$OUT_FILE" 2>&1 &
TEST_PID=$!
set +m 2>/dev/null || true
echo "$TEST_PID" > "$PIDFILE"

wait "$TEST_PID"
TEST_EXIT=$?

# claim_marker keeps runner ownership exclusive — same reasoning as the
# shell branch's rerun loop.
while claim_marker "$RERUN_MARKER"; do
  set -m 2>/dev/null || true
  "${TEST_CMD[@]}" >"$OUT_FILE" 2>&1 &
  TEST_PID=$!
  set +m 2>/dev/null || true
  echo "$TEST_PID" > "$PIDFILE"
  wait "$TEST_PID"
  TEST_EXIT=$?
done
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
