#!/bin/bash
# Self-contained test suite for scripts/run-tests.sh.
# Style follows scripts/create-local-issues.test.sh / scripts/poll-pr-reviews.test.sh:
# set -euo pipefail, a jq guard, a fail() that writes to stderr and exits 1,
# small run_in/expect_* wrappers, sandbox dirs under this suite's own
# mktemp -d, cleanup trap.
#
# RECURSION GUARD: run-tests.sh discovers and executes every git-tracked
# *.test.sh under the repo — including this file, once it's committed. That
# is fine and expected (it's the whole point of the discovery mechanism) —
# what this suite must never do is invoke the REAL scripts/run-tests.sh
# against the REAL repo, which would recurse into itself. Every invocation
# below instead COPIES run-tests.sh into a throwaway sandbox tree (built
# fresh under this suite's own mktemp -d, never git-related to this repo)
# and runs that copy there, with a sandbox-local REPO_ROOT of its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/run-tests.sh"

# run-tests.sh itself requires jq on PATH (it exits 1 immediately otherwise,
# before doing anything else) — guard the suite the same way so a
# jq-missing host fails fast with a clear message instead of confusing
# discovery-related assertion failures below.
command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

# sandbox_new_nongit — a throwaway, non-git directory under SUITE_TMP with
# a copy of run-tests.sh at scripts/run-tests.sh (so the copy's own
# REPO_ROOT computation, `dirname(BASH_SOURCE)/..`, lands on the sandbox
# root). Not a git repo, so the copy's discover_suites falls back to `find`.
sandbox_new_nongit() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/sandbox.XXXXXX")
  mkdir -p "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/run-tests.sh"
  printf '%s' "$dir"
}

# sandbox_new_git — same layout, but the sandbox root is its own throwaway
# git repo, so the copy's discover_suites uses `git ls-files` instead.
sandbox_new_git() {
  local dir
  dir=$(sandbox_new_nongit)
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test Suite"
  printf '%s' "$dir"
}

# run_in <sandbox_dir> — runs the sandbox's own copy of run-tests.sh,
# capturing stdout/stderr/exit code into LAST_STDOUT/LAST_STDERR/LAST_EXIT.
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT=0
run_in() {
  local dir="$1"
  local out="$SUITE_TMP/last_stdout"
  local err="$SUITE_TMP/last_stderr"
  set +e
  bash "$dir/scripts/run-tests.sh" >"$out" 2>"$err"
  LAST_EXIT=$?
  set -e
  LAST_STDOUT=$(cat "$out")
  LAST_STDERR=$(cat "$err")
}

expect_exit() {
  local expected="$1" desc="$2"
  [ "$LAST_EXIT" -eq "$expected" ] || fail "$desc: expected exit $expected, got $LAST_EXIT (stdout=$LAST_STDOUT stderr=$LAST_STDERR)"
}

expect_output_contains() {
  local pattern="$1" desc="$2"
  printf '%s\n%s\n' "$LAST_STDOUT" "$LAST_STDERR" | grep -qF -- "$pattern" \
    || fail "$desc: expected output to contain '$pattern' (stdout=$LAST_STDOUT stderr=$LAST_STDERR)"
}

expect_output_not_contains() {
  local pattern="$1" desc="$2"
  if printf '%s\n%s\n' "$LAST_STDOUT" "$LAST_STDERR" | grep -qiF -- "$pattern"; then
    fail "$desc: expected output NOT to contain '$pattern' (stdout=$LAST_STDOUT stderr=$LAST_STDERR)"
  fi
}

# =============================================================================
# (a) Zero-suite guard: an empty, non-git sandbox has no *.test.sh at all
# (the find fallback still runs, but discovers nothing). Must exit 1 with a
# clear "no test suites were discovered" message, not a silent
# "0 passed, 0 failed" exit 0.
# =============================================================================
ZERO_DIR=$(sandbox_new_nongit)
run_in "$ZERO_DIR"
expect_exit 1 "zero-suite guard"
expect_output_contains "no test suites were discovered" "zero-suite guard"

# =============================================================================
# (b) Root-level runtime-dir prunes (non-git find fallback): decoys under
# root-level projects/ and file-history/ must be pruned; a root-level
# real.test.sh must still be discovered and run.
# =============================================================================
PRUNE_DIR=$(sandbox_new_nongit)
mkdir -p "$PRUNE_DIR/projects" "$PRUNE_DIR/file-history"
printf 'exit 1\n' > "$PRUNE_DIR/projects/decoy.test.sh"
printf 'exit 1\n' > "$PRUNE_DIR/file-history/decoy2.test.sh"
printf 'exit 0\n' > "$PRUNE_DIR/real.test.sh"
run_in "$PRUNE_DIR"
expect_exit 0 "root-level runtime-dir prunes"
expect_output_contains "PASS: real.test.sh" "root-level runtime-dir prunes"
expect_output_not_contains "decoy" "root-level runtime-dir prunes"

# =============================================================================
# (c) Anchored-prunes-only-at-root: a nested src/projects/ dir shares a
# basename with the pruned root-level projects/ dir, but the prune is
# anchored to $REPO_ROOT/projects/* — it must NOT exclude this nested one.
# =============================================================================
NESTED_DIR=$(sandbox_new_nongit)
mkdir -p "$NESTED_DIR/src/projects"
printf 'exit 0\n' > "$NESTED_DIR/src/projects/widget.test.sh"
run_in "$NESTED_DIR"
expect_exit 0 "anchored-prunes-only-at-root"
expect_output_contains "PASS: src/projects/widget.test.sh" "anchored-prunes-only-at-root"

# =============================================================================
# (d) Failing suite propagates: one passing and one failing suite, tracked
# in a throwaway git sandbox (git ls-files discovery path) — overall exit 1,
# summary line reflects both counts.
# =============================================================================
MIXED_DIR=$(sandbox_new_git)
printf 'exit 0\n' > "$MIXED_DIR/pass.test.sh"
printf 'exit 1\n' > "$MIXED_DIR/fail.test.sh"
git -C "$MIXED_DIR" add -A
run_in "$MIXED_DIR"
expect_exit 1 "failing suite propagates"
expect_output_contains "1 passed, 1 failed" "failing suite propagates"

# =============================================================================
# (e) Timed-out suite's TERM-ignoring descendant is killed: the suite leader
# dies on the group TERM but backgrounds a child that traps TERM away; the
# watchdog's group SIGKILL must be unconditional (a leader-alive gate would
# skip it and leak the child into subsequent suites).
# =============================================================================
LEAK_DIR=$(sandbox_new_nongit)
LEAK_SENTINEL="leak-sentinel-$$"
cat > "$LEAK_DIR/hang.test.sh" <<EOF
#!/bin/bash
( trap '' TERM; exec -a "$LEAK_SENTINEL" sleep 300 ) &
wait
EOF
set +e
RUN_TESTS_SUITE_TIMEOUT=2 bash "$LEAK_DIR/scripts/run-tests.sh" >"$SUITE_TMP/last_stdout" 2>"$SUITE_TMP/last_stderr"
LAST_EXIT=$?
set -e
LAST_STDOUT=$(cat "$SUITE_TMP/last_stdout")
LAST_STDERR=$(cat "$SUITE_TMP/last_stderr")
expect_exit 1 "timeout kills TERM-ignoring descendant"
expect_output_contains "TIMEOUT" "timeout kills TERM-ignoring descendant"
sleep 1
if pgrep -f "$LEAK_SENTINEL" >/dev/null 2>&1; then
  pkill -9 -f "$LEAK_SENTINEL" 2>/dev/null
  fail "timeout kills TERM-ignoring descendant: sentinel process survived the group SIGKILL"
fi

echo "run-tests.sh tests passed"
