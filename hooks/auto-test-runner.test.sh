#!/bin/bash
# Self-contained test suite for hooks/auto-test-runner.sh (the *.sh /
# shell-suite branch only — this repo has no vitest/jest config, so the JS
# branch is dead code here and out of scope).
# Style follows hooks/pr-merge-sync-reminder.test.sh / scripts/create-local-issues.test.sh:
# set -euo pipefail, fail() to stderr + exit 1, mktemp -d sandboxes, cleanup
# trap, jq skip-guard, flat top-level assertion calls, no test framework.
#
# The hook computes REPO_ROOT from its own file location (dirname of
# BASH_SOURCE + /..) and runs $REPO_ROOT/scripts/run-tests.sh, so every case
# below copies the real hook into <sandbox>/hooks/auto-test-runner.sh and
# provides a stub <sandbox>/scripts/run-tests.sh that just records an
# invocation (and optionally sleeps) instead of running the real suite.
# Each case also gets its own TMPDIR, exported before invoking the hook, so
# the hook's per-user state dir (${TMPDIR}/claude-auto-test-$(id -u)) is
# fully sandboxed and never touches the real one.
set -euo pipefail

# Recursion guard (defense-in-depth). Every case below invokes a SANDBOXED
# copy of the hook whose REPO_ROOT resolves to a throwaway case dir, never
# the real worktree — see setup_case() and the hard per-case path
# assertions below. If that ever regressed (a sandboxed hook resolving
# REPO_ROOT back to this worktree), it would re-run the real
# scripts/run-tests.sh, which would re-discover and re-run THIS suite —
# nested, unbounded. This guard makes any such re-entry an immediate no-op
# instead of runaway recursion.
if [ -n "${AUTO_TEST_RUNNER_TEST_ACTIVE:-}" ]; then
  exit 0
fi
export AUTO_TEST_RUNNER_TEST_ACTIVE=1

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/auto-test-runner.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

# The event fed to every invocation: a *.sh file_path that is not skip-
# matched (not under /docs/, /config/, /.claude/, etc.), so every case
# below exercises the shell-suite branch.
PAYLOAD='{"tool_input":{"file_path":"/x/foo.sh"}}'

# sandbox_new — fresh throwaway dir under SUITE_TMP. mktemp -d for
# uniqueness (not a counter): this is invoked via command substitution,
# which runs in a subshell, so a counter increment there would be lost.
sandbox_new() {
  mktemp -d "$SUITE_TMP/sandbox.XXXXXX"
}

# setup_case — builds a fresh case dir containing a copy of the real hook
# at hooks/auto-test-runner.sh and a scripts/run-tests.sh stub, and prints
# the case dir's path. The hook resolves REPO_ROOT as dirname(hooks/..),
# which is exactly this case dir, so it also doubles as the project-key
# input (see project_key below).
setup_case() {
  local dir
  dir=$(sandbox_new)
  mkdir -p "$dir/hooks" "$dir/scripts"
  cp "$HOOK" "$dir/hooks/auto-test-runner.sh"
  cat > "$dir/scripts/run-tests.sh" <<'STUB'
#!/bin/bash
# Stub replacing the real run-tests.sh for auto-test-runner.test.sh.
# Records one invocation per run into $RUNLOG (passed through by the
# caller's exported env, inherited by this backgrounded child), together
# with this script's OWN invoked path ($0) — that path is asserted by
# every case below to be the sandboxed stub, never the real repo's
# scripts/run-tests.sh, proving the hook under test resolved REPO_ROOT to
# the sandbox and not the worktree. Optionally sleeps $STUB_SLEEP seconds
# first, to create a window during which concurrent hook invocations can
# be fired for the coalescing case.
echo "run $$ $0" >> "${RUNLOG:?RUNLOG not set}"
if [ -n "${STUB_SLEEP:-}" ]; then
  sleep "$STUB_SLEEP"
fi
exit 0
STUB
  chmod +x "$dir/scripts/run-tests.sh"
  printf '%s' "$dir"
}

# project_key <repo_root> — the exact key formula from the hook's own
# _project_key(): cksum is POSIX and bash-3.2/macOS safe.
project_key() {
  printf '%s' "$1" | cksum | tr -s ' \t' '.' | sed 's/\.$//'
}

# state_dir <tmpdir> — the hook's per-user state dir given the TMPDIR it
# was invoked with.
state_dir() {
  printf '%s/claude-auto-test-%s' "$1" "$(id -u)"
}

# run_count <runlog> — number of stub invocations recorded (0 if the
# runlog was never created).
run_count() {
  [ -f "$1" ] || { echo 0; return 0; }
  wc -l < "$1" | tr -d ' '
}

# assert_stub_path_is_sandboxed <runlog> <case_dir> <label> — hard
# guarantee that every recorded stub invocation's own script path (the 3rd
# field logged by the stub, its $0) is exactly <case_dir>/scripts/run-tests.sh
# — the sandboxed stub — and never the real repo's scripts/run-tests.sh. A
# case "passing" without this holding would mean it exercised the wrong
# copy of the hook (REPO_ROOT resolved outside the sandbox).
assert_stub_path_is_sandboxed() {
  local runlog="$1" case_dir="$2" label="$3" expected="$2/scripts/run-tests.sh" logged_path
  [ -f "$runlog" ] || return 0
  while IFS= read -r line; do
    logged_path="${line##* }"
    [ "$logged_path" = "$expected" ] \
      || fail "$label: stub invocation logged script path '$logged_path', expected sandboxed '$expected' — the hook ran the wrong copy of scripts/run-tests.sh"
  done < "$runlog"
}

# invoke_hook <case_dir> <tmpdir> <runlog> [stub_sleep] — feeds PAYLOAD on
# stdin, exporting TMPDIR and RUNLOG (and STUB_SLEEP, possibly empty) for
# the hook and any test-runner child it backgrounds. Captures stdout into
# LAST_OUT. Runs synchronously (blocks until the hook, including any of its
# own internal reruns, has fully exited).
LAST_OUT=""
invoke_hook() {
  local case_dir="$1" tmpdir="$2" runlog="$3" stub_sleep="${4:-}"
  LAST_OUT=$(echo "$PAYLOAD" | TMPDIR="$tmpdir" RUNLOG="$runlog" STUB_SLEEP="$stub_sleep" bash "$case_dir/hooks/auto-test-runner.sh")
}

# =======================================================================
# (a) Single invocation runs the stub exactly once and emits a
# systemMessage JSON on stdout.
# =======================================================================
A_DIR=$(setup_case)
A_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
A_RUNLOG="$A_TMPDIR/runlog.txt"

invoke_hook "$A_DIR" "$A_TMPDIR" "$A_RUNLOG"

[ "$(run_count "$A_RUNLOG")" -eq 1 ] || fail "(a) expected exactly 1 stub run for a single invocation, got $(run_count "$A_RUNLOG")"
assert_stub_path_is_sandboxed "$A_RUNLOG" "$A_DIR" "(a)"
echo "$LAST_OUT" | jq -e '.hookSpecificOutput.systemMessage' >/dev/null \
  || fail "(a) expected a systemMessage in hook stdout, got: $LAST_OUT"

# =======================================================================
# (b) Coalescing: one invocation starts a stub run that sleeps 2s; while
# it runs, 3 more invocations fire. They must exit quickly (having only
# published markers), and the total stub-run count must land in
# [2, 5) — the initial run plus at least one coalesced rerun, but not one
# rerun per extra invocation.
# =======================================================================
B_DIR=$(setup_case)
B_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
B_RUNLOG="$B_TMPDIR/runlog.txt"

(
  echo "$PAYLOAD" | TMPDIR="$B_TMPDIR" RUNLOG="$B_RUNLOG" STUB_SLEEP=2 bash "$B_DIR/hooks/auto-test-runner.sh" \
    > "$B_TMPDIR/inv1.out" 2>"$B_TMPDIR/inv1.err"
) &
INV1_PID=$!

# Give invocation 1 time to touch the marker, win the lock, and background
# its (sleeping) stub run before the extra invocations fire — generous
# relative to the near-instant work involved, well inside the 2s sleep.
sleep 1

SECONDS=0
for n in 2 3 4; do
  echo "$PAYLOAD" | TMPDIR="$B_TMPDIR" RUNLOG="$B_RUNLOG" bash "$B_DIR/hooks/auto-test-runner.sh" \
    > "$B_TMPDIR/inv$n.out" 2>"$B_TMPDIR/inv$n.err"
done
FIRE_ELAPSED=$SECONDS
[ "$FIRE_ELAPSED" -le 1 ] || fail "(b) expected invocations 2-4 to exit quickly (<=1s total) while invocation 1's lock is held live, took ${FIRE_ELAPSED}s"

wait "$INV1_PID"

B_RUNS=$(run_count "$B_RUNLOG")
[ "$B_RUNS" -ge 2 ] || fail "(b) expected >=2 total stub runs (initial + a coalesced rerun), got $B_RUNS"
[ "$B_RUNS" -lt 5 ] || fail "(b) expected <5 total stub runs (reruns must coalesce, not run once per invocation), got $B_RUNS"

B_STATE_DIR=$(state_dir "$B_TMPDIR")
B_LEFTOVER=$(ls -A "$B_STATE_DIR" 2>/dev/null || true)
[ -z "$B_LEFTOVER" ] || fail "(b) expected no marker/lock files left in the state dir after coalescing settles, found: $B_LEFTOVER"

# =======================================================================
# (c) Stale-lock reclaim: a lock symlink whose recorded identity is a
# dead PID must be reclaimed and the suite still run.
# =======================================================================
C_DIR=$(setup_case)
C_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
C_RUNLOG="$C_TMPDIR/runlog.txt"
C_KEY=$(project_key "$C_DIR")
C_STATE_DIR=$(state_dir "$C_TMPDIR")
mkdir -m 700 -p "$C_STATE_DIR"
ln -s "99999999:Wed Jan  1 00:00:00 2020" "$C_STATE_DIR/$C_KEY.shell.lock"

invoke_hook "$C_DIR" "$C_TMPDIR" "$C_RUNLOG"

[ "$(run_count "$C_RUNLOG")" -ge 1 ] || fail "(c) expected the stub to run after reclaiming a dead lock"
C_LEFTOVER=$(ls -A "$C_STATE_DIR" 2>/dev/null || true)
[ -z "$C_LEFTOVER" ] || fail "(c) expected state dir clean after dead-lock reclaim, found: $C_LEFTOVER"

# =======================================================================
# (d) PID-reuse guard: a lock recorded against a PID that happens to be
# alive right now (PID 1), but whose start time does not match — must
# still be treated as dead and reclaimed.
# =======================================================================
D_DIR=$(setup_case)
D_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
D_RUNLOG="$D_TMPDIR/runlog.txt"
D_KEY=$(project_key "$D_DIR")
D_STATE_DIR=$(state_dir "$D_TMPDIR")
mkdir -m 700 -p "$D_STATE_DIR"
ln -s "1:Wed Jan  1 00:00:00 2020" "$D_STATE_DIR/$D_KEY.shell.lock"

invoke_hook "$D_DIR" "$D_TMPDIR" "$D_RUNLOG"

[ "$(run_count "$D_RUNLOG")" -ge 1 ] || fail "(d) expected the stub to run after reclaiming a PID-reuse (live PID, wrong start time) lock"
D_LEFTOVER=$(ls -A "$D_STATE_DIR" 2>/dev/null || true)
[ -z "$D_LEFTOVER" ] || fail "(d) expected state dir clean after PID-reuse reclaim, found: $D_LEFTOVER"

# =======================================================================
# (e) Live-holder respect: a lock whose recorded identity genuinely
# matches a live process (this test's own shell, pid + real lstart) must
# be respected — the invocation must exit WITHOUT running the stub, and
# the marker it published must remain (for the "live" holder to consume).
# =======================================================================
E_DIR=$(setup_case)
E_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
E_RUNLOG="$E_TMPDIR/runlog.txt"
E_KEY=$(project_key "$E_DIR")
E_STATE_DIR=$(state_dir "$E_TMPDIR")
mkdir -m 700 -p "$E_STATE_DIR"

MY_LSTART=$(ps -o lstart= -p $$ | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
ln -s "$$:$MY_LSTART" "$E_STATE_DIR/$E_KEY.shell.lock"

invoke_hook "$E_DIR" "$E_TMPDIR" "$E_RUNLOG"

[ "$(run_count "$E_RUNLOG")" -eq 0 ] || fail "(e) expected the stub NOT to run while a live holder's lock is in place"
[ -f "$E_STATE_DIR/$E_KEY.shell.rerun" ] || fail "(e) expected the published marker to remain in the state dir for the live holder to consume"

# Clean up our synthetic plants — nothing will ever consume them since the
# "live holder" here is this test process itself, not a real runner.
rm -f "$E_STATE_DIR/$E_KEY.shell.lock" "$E_STATE_DIR/$E_KEY.shell.rerun"

# =======================================================================
# (f) Dead reclaim-token GC: both the lock AND its .reclaim token are
# dead — the invocation must GC the dead token and still reclaim + run.
# =======================================================================
F_DIR=$(setup_case)
F_TMPDIR=$(mktemp -d "$SUITE_TMP/tmpdir.XXXXXX")
F_RUNLOG="$F_TMPDIR/runlog.txt"
F_KEY=$(project_key "$F_DIR")
F_STATE_DIR=$(state_dir "$F_TMPDIR")
mkdir -m 700 -p "$F_STATE_DIR"
ln -s "99999999:Wed Jan  1 00:00:00 2020" "$F_STATE_DIR/$F_KEY.shell.lock"
ln -s "88888888:Wed Jan  1 00:00:00 2020" "$F_STATE_DIR/$F_KEY.shell.lock.reclaim"

invoke_hook "$F_DIR" "$F_TMPDIR" "$F_RUNLOG"

[ "$(run_count "$F_RUNLOG")" -ge 1 ] || fail "(f) expected the stub to run after GC-ing a dead reclaim token"
F_LEFTOVER=$(ls -A "$F_STATE_DIR" 2>/dev/null || true)
[ -z "$F_LEFTOVER" ] || fail "(f) expected state dir clean after dead reclaim-token GC, found: $F_LEFTOVER"

echo "auto-test-runner.sh tests passed"
