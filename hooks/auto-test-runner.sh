#!/bin/bash
# PostToolUse hook (async): Run tests in background after file edits.
# Replaces the manual test-runner coordination from v1 orchestrator.
#
# Triggered on: Edit, Write (source files only, not docs/config)
# Runs asynchronously — does not block Claude's work.
# Results delivered as a systemMessage on the next turn.
#
# Concurrency model (per suite target — shell and JS coordinate separately,
# and every coordination file is namespaced by the tested project so two
# projects under the same user never share a lock or marker):
#
#   marker  — a published "please run the tests" request. Every invocation
#             touches it first, unconditionally. Multiple edits coalesce:
#             touch is idempotent, and one run over current disk contents
#             satisfies every request published before it launched.
#   lock    — runner ownership: a symlink whose target is one or more
#             ';'-separated pid:start-time identity tokens. `ln -s` creates
#             the link and records the owner in ONE atomic syscall, so
#             there is no instant at which the lock exists without an owner
#             recorded. After launching the suite, the runner atomically
#             re-stamps the lock (temp symlink + rename) to carry BOTH the
#             wrapper's and the test child's identities: liveness holds if
#             EITHER is alive, so a killed wrapper (e.g. a harness hook
#             timeout) whose child suite is still running is not mistaken
#             for a crashed runner — that mistake would launch a second
#             concurrent suite against the same project.
#
# The lock is held across liveness reasoning, launch, and every rerun.
# Handoff at the end of a runner's life is a release-then-recheck loop:
# after the final failed claim the runner releases the lock and then looks
# at the marker again — a publisher that saw our lock in the gap between
# that final claim and the release has left a marker nobody owns, so the
# runner retakes the lock and consumes it (or a newer invocation already
# has). Release is guarded (only the recorded owner unlinks), so no exit
# path can remove a lock some newer runner now holds.
#
# Crash recovery: a lock (or reclaim token) whose recorded identities are
# all dead is a crashed runner's leftover. Reclamation is single-winner —
# serialized through a reclaim token taken with the same atomic ln, with
# dead-token GC via atomic rename and ownership re-verified immediately
# before every mutation. Any contender that loses a race or finds the
# state changed under it RETRIES the whole acquisition (bounded), rather
# than standing down outright: a restored token's owner may itself have
# already given up after finding its token briefly missing, and a retry
# either finds a live holder (exit — it will consume our marker) or wins
# the lock and consumes the marker itself.

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

# PID-reuse-safe identity, same technique as scripts/lib/poll-common.sh:
# a bare PID is not enough to know a recorded holder is still the same
# process instance — the OS recycles PIDs, and a recycled PID held by any
# unrelated long-lived process would make a crashed runner's lock look
# live forever, wedging testing. Identities are "pid:start-time", and
# liveness requires both the PID to be alive and its start time to match.
_pid_start_time() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

MY_TOKEN="$$:$(_pid_start_time "$$")"
LOCK_STAMP="$MY_TOKEN"

# True if the single "pid:start-time" identity $1 names a live process
# instance. Colon-less or empty identities are not verifiable → not live.
_one_live() {
  local pid="${1%%:*}" start="${1#*:}"
  [ -n "$pid" ] && [ "$1" != "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(_pid_start_time "$pid")" = "$start" ]
}

# True if ANY ';'-separated identity in $1 is live — a lock stamped with
# "wrapper;child" stays live while either process runs.
_holder_is_live() {
  local ids="$1" id
  [ -n "$ids" ] || return 1
  local IFS=';'
  for id in $ids; do
    _one_live "$id" && return 0
  done
  return 1
}

# Atomically consume a published run request. rename(2) is atomic — exactly
# one mv wins — and a failed mv (marker absent) cleanly ends the rerun loop.
claim_marker() {
  mv "$1" "$1.claimed.$$" 2>/dev/null || return 1
  rm -f "$1.claimed.$$"
  return 0
}

# Acquire runner ownership of lock $1. Single-winner at every step:
# primary ln is atomic; stale-lock reclamation serializes through a
# reclaim token (atomic ln); dead-token GC claims the link itself via
# atomic rename (a bare rm+ln would let a loser's stale-read rm delete
# the winner's fresh live token); and ownership is re-verified immediately
# before each mutation. Losers and contenders that find state changed
# under them retry the whole acquisition (bounded) instead of standing
# down permanently — see the header's crash-recovery paragraph.
acquire_lock() {
  local lock="$1" attempt
  for attempt in 1 2 3; do
    if ln -s "$MY_TOKEN" "$lock" 2>/dev/null; then
      LOCK_STAMP="$MY_TOKEN"
      return 0
    fi
    local holder
    holder=$(readlink "$lock" 2>/dev/null || true)
    if _holder_is_live "$holder"; then
      return 1
    fi
    local token="$lock.reclaim"
    if ! ln -s "$MY_TOKEN" "$token" 2>/dev/null; then
      local tholder
      tholder=$(readlink "$token" 2>/dev/null || true)
      if _holder_is_live "$tholder"; then
        return 1
      fi
      local gc="$token.gc.$$"
      mv "$token" "$gc" 2>/dev/null || continue
      local moved
      moved=$(readlink "$gc" 2>/dev/null || true)
      rm -f "$gc"
      if [ "$moved" != "$tholder" ]; then
        # We renamed something newer than what we judged dead: a completed
        # reclaim installed a live token between our read and our mv.
        # Restore an equivalent link if the spot is still empty, then
        # retry from the top — the restored owner may already have stood
        # down after finding its token missing, so simply exiting here
        # could leave marker+lock stale with no live owner (Codex round
        # 16); the retry converges either way.
        [ -n "$moved" ] && ln -s "$moved" "$token" 2>/dev/null
        continue
      fi
      ln -s "$MY_TOKEN" "$token" 2>/dev/null || continue
    fi
    # Re-verify token ownership immediately before mutating the lock: the
    # restore path above necessarily has an empty-path window a third
    # contender can win. Whoever's token is on disk NOW is the one
    # entitled to replace the lock.
    if [ "$(readlink "$token" 2>/dev/null || true)" != "$MY_TOKEN" ]; then
      continue
    fi
    local rc=1
    if [ "$(readlink "$lock" 2>/dev/null || true)" = "$holder" ]; then
      rm -f "$lock"
      ln -s "$MY_TOKEN" "$lock" 2>/dev/null
      rc=$?
    fi
    rm -f "$token"
    if [ "$rc" -eq 0 ]; then
      LOCK_STAMP="$MY_TOKEN"
      return 0
    fi
  done
  return 1
}

# Atomically re-stamp the held lock to carry an additional identity
# (temp symlink + rename — contenders read either the old or the new
# stamp, both of which name this runner). Records the new stamp so the
# guarded release still matches.
stamp_lock() {
  local lock="$1" extra="$2" tmp="$HOOK_STATE_DIR/.stamp.$$"
  ln -s "$MY_TOKEN;$extra" "$tmp" 2>/dev/null || return 0
  if mv -f "$tmp" "$lock" 2>/dev/null; then
    LOCK_STAMP="$MY_TOKEN;$extra"
  else
    rm -f "$tmp"
  fi
  return 0
}

# Release only what we own: by the time an exit path runs, a newer runner
# may hold this lock — unlinking it would reopen dual ownership.
release_lock() {
  [ "$(readlink "$1" 2>/dev/null)" = "$LOCK_STAMP" ] && rm -f "$1"
  return 0
}

# Namespace key for a project path: two projects for the same user must
# never share a marker or lock — otherwise project A's runner "consumes"
# project B's request by rerunning A's suite, and B's edit is silently
# never tested. cksum is POSIX and bash-3.2/macOS safe.
_project_key() {
  printf '%s' "$1" | cksum | tr -s ' \t' '.' | sed 's/\.$//'
}

# A *.sh edit runs the repo's own shell test suite (REQ-010,
# docs/features/script_tests/PRD.md) instead of the JS runner below — this
# repo's shell scripts have no vitest/jest coverage, only *.test.sh suites.
case "$FILE_PATH" in
  *.sh)
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"
    [ -f "$RUN_TESTS" ] || exit 0

    # The shell suite's target is always $REPO_ROOT (the repo this hook
    # file lives in — the project repo in-repo, ~/.claude when deployed
    # globally), so the namespace key is that root: all invocations that
    # would run the same suite share one marker/lock, and nothing else
    # does.
    SH_KEY=$(_project_key "$REPO_ROOT")
    SH_MARKER="$HOOK_STATE_DIR/$SH_KEY.shell.rerun"
    SH_LOCK="$HOOK_STATE_DIR/$SH_KEY.shell.lock"

    # Publish first, then try to become the runner. If the lock is held,
    # the live holder's rerun loop is guaranteed to see this marker after
    # its current run — the edit is never silently dropped.
    touch "$SH_MARKER"
    acquire_lock "$SH_LOCK" || exit 0

    SH_OUT_FILE=$(mktemp "$HOOK_STATE_DIR/shell-out.XXXXXX")
    # Cleanup on EXIT only; signal handlers must exit explicitly — a
    # trapped INT/TERM otherwise runs the handler and RESUMES the script,
    # which would continue the rerun loop after releasing the lock and
    # launch suites without ownership. If a signal lands while the suite
    # child is still running, the child must be terminated (bounded
    # escalation) BEFORE the lock is released: exiting the wrapper does
    # not kill the child, and releasing while it runs would let the next
    # edit start a concurrent suite alongside the orphan.
    cleanup_sh() {
      if [ -n "${SH_CHILD:-}" ] && kill -0 "$SH_CHILD" 2>/dev/null; then
        # The suite was launched in its own process group (set -m), so
        # signal the GROUP: a positive PID reaches only the leader, and a
        # suite that spawned descendants would leave them orphaned past
        # the lock release.
        kill -- -"$SH_CHILD" 2>/dev/null || kill "$SH_CHILD" 2>/dev/null
        local i
        for i in 1 2 3; do
          kill -0 "$SH_CHILD" 2>/dev/null || break
          sleep 1
        done
        kill -9 -- -"$SH_CHILD" 2>/dev/null || kill -9 "$SH_CHILD" 2>/dev/null
        wait "$SH_CHILD" 2>/dev/null
      fi
      release_lock "$SH_LOCK"
      rm -f "$SH_OUT_FILE"
    }
    trap cleanup_sh EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Run while requests exist. The first inner iteration normally consumes
    # the marker we just published; a failed first claim means the previous
    # runner consumed it in its final rerun (which tested disk contents
    # that already included our edit), so there is nothing to do. The
    # suite runs as a backgrounded child whose pid:start-time identity is
    # stamped onto the lock — if this wrapper is killed (hook timeout)
    # while the child still runs, the lock stays live via the child and
    # no second suite launches concurrently.
    SH_EXIT=0
    SH_RAN=0
    while :; do
      while claim_marker "$SH_MARKER"; do
        # set -m puts the suite in its own process group so signal-path
        # cleanup can terminate the whole group, descendants included.
        set -m 2>/dev/null || true
        bash "$RUN_TESTS" >"$SH_OUT_FILE" 2>&1 &
        SH_CHILD=$!
        set +m 2>/dev/null || true
        stamp_lock "$SH_LOCK" "$SH_CHILD:$(_pid_start_time "$SH_CHILD")"
        wait "$SH_CHILD"
        SH_EXIT=$?
        # Orphan sweep before any further claim/release: a suite that
        # backgrounded a descendant and exited leaves it in the group.
        kill -0 -- -"$SH_CHILD" 2>/dev/null && kill -9 -- -"$SH_CHILD" 2>/dev/null
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

# The JS suite's target is the current project (vitest/jest run in cwd),
# so namespace by the project root: edits in two different repos must not
# coordinate through the same marker/lock.
PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
JS_KEY=$(_project_key "$PROJ_ROOT")
MARKER="$HOOK_STATE_DIR/$JS_KEY.js.rerun"
LOCK="$HOOK_STATE_DIR/$JS_KEY.js.lock"

# Publish-then-lock, same protocol as the shell branch.
touch "$MARKER"
acquire_lock "$LOCK" || exit 0

OUT_FILE=$(mktemp "$HOOK_STATE_DIR/js-out.XXXXXX")
# EXIT-only cleanup with child termination before release + exiting
# signal handlers — same reasoning as the shell branch.
cleanup_js() {
  if [ -n "${TEST_CHILD:-}" ] && kill -0 "$TEST_CHILD" 2>/dev/null; then
    # Group signal — same reasoning as the shell branch's cleanup.
    kill -- -"$TEST_CHILD" 2>/dev/null || kill "$TEST_CHILD" 2>/dev/null
    local i
    for i in 1 2 3; do
      kill -0 "$TEST_CHILD" 2>/dev/null || break
      sleep 1
    done
    kill -9 -- -"$TEST_CHILD" 2>/dev/null || kill -9 "$TEST_CHILD" 2>/dev/null
    wait "$TEST_CHILD" 2>/dev/null
  fi
  release_lock "$LOCK"
  rm -f "$OUT_FILE"
}
trap cleanup_js EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Release-then-recheck handoff with child-identity stamping — same
# protocol as the shell branch.
TEST_EXIT=0
RAN=0
while :; do
  while claim_marker "$MARKER"; do
    # Own process group for group-wide signal cleanup — same as shell branch.
    set -m 2>/dev/null || true
    "${TEST_CMD[@]}" >"$OUT_FILE" 2>&1 &
    TEST_CHILD=$!
    set +m 2>/dev/null || true
    stamp_lock "$LOCK" "$TEST_CHILD:$(_pid_start_time "$TEST_CHILD")"
    wait "$TEST_CHILD"
    TEST_EXIT=$?
    # Orphan sweep: unlike the shell branch's run-tests.sh (which sweeps
    # its own suites' orphans), vitest/jest have no such guarantee — a
    # runner that backgrounded a descendant and exited normally would
    # otherwise leave it alive past the lock release, and the next edit
    # would start a suite alongside it.
    kill -0 -- -"$TEST_CHILD" 2>/dev/null && kill -9 -- -"$TEST_CHILD" 2>/dev/null
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
