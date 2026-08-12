#!/bin/bash
# scripts/run-tests.sh — repo test entry point (REQ-005, docs/features/script_tests/PRD.md).
#
# Discovers every git-tracked *.test.sh file under the repo (no hardcoded
# list — a new suite is picked up automatically once committed) and runs
# each with `bash <file>`, not as an executable:
# hooks/enforce-git-conventions.test.sh is mode 644 and would otherwise be
# skipped or fail outright.
#
# One suite's failure does not stop the others. Prints one PASS/FAIL line per
# suite plus a final "N passed, M failed" summary, and exits 0 only when every
# suite passed.
#
# bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays,
# no ${var,,}.

# Deliberately not `set -e`: a failing suite must not abort the loop before
# every other suite has had a chance to run. `-u` catches real bugs in this
# script; `pipefail` is unused since no suite's output is piped through
# another command whose exit code we rely on.
set -u -o pipefail

command -v jq >/dev/null 2>&1 || {
  echo "run-tests.sh: jq is required to run the test suites but was not found on PATH" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same-tree recursion refusal. A suite that (directly or through a hook it
# exercises) re-invokes THIS tree's run-tests.sh would re-discover and
# re-execute that same suite — an unbounded mutual recursion that idles in
# nested sleeps and looks exactly like a stall (observed 2026-08-11: a
# hook test invoked the real hook instead of its sandbox copy; the hook's
# REPO_ROOT resolved back to this tree and the run nested indefinitely).
# The sentinel carries the tree path, not a boolean, so a test that copies
# run-tests.sh into a sandbox and runs the COPY under this runner is
# unaffected — only re-entry into the SAME tree refuses.
if [ "${RUN_TESTS_ACTIVE_ROOT:-}" = "$REPO_ROOT" ]; then
  echo "run-tests.sh: nested invocation for the same tree ($REPO_ROOT) — refusing to recurse. A suite (or a hook it runs) is re-invoking its own test runner; fix the suite to target a sandbox copy." >&2
  exit 1
fi
export RUN_TESTS_ACTIVE_ROOT="$REPO_ROOT"

# Per-suite watchdog: a hung suite must become a loud, attributable FAIL
# in bounded time, never a silent indefinite stall of the whole run.
# Overridable for genuinely slow suites; 120s is ~4x the slowest suite
# today. macOS ships no `timeout`, so this is a hand-rolled poll loop.
SUITE_TIMEOUT="${RUN_TESTS_SUITE_TIMEOUT:-120}"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_SUITES=""

# -print0 / read -d '' avoids word-splitting and glob expansion on suite
# paths; `sort -z` gives a deterministic run order. Both are bash-3.2 safe on
# macOS's BSD find/sort.
#
# Discovery is scoped to tracked files via `git ls-files` rather than a
# filesystem `find`: an untracked *.test.sh dropped anywhere under the repo
# (e.g. inside an untracked scratch dir, a malicious or accidental copy, or a
# stale worktree artifact) would otherwise be picked up and executed with no
# review — `bash "$suite"` runs arbitrary code. Falling back to `find` (with
# `.git`, `.claude/worktrees`, and `node_modules` pruned at any depth, plus
# the Claude Code runtime dirs `projects/`, `file-history/`, and
# `paste-cache/` pruned at the repo root — see the inline comment below)
# only when this repo has no git history to query, which in practice only
# happens for the deployed copy under ~/.claude.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  discover_suites() {
    git -C "$REPO_ROOT" ls-files -z '*.test.sh' | while IFS= read -r -d '' rel; do
      printf '%s\0' "$REPO_ROOT/$rel"
    done | sort -z
  }
else
  discover_suites() {
    # The extra prunes matter for the deployed copy under ~/.claude (not a
    # git repo, so this fallback is its live path): Claude Code runtime dirs
    # there (projects/ file-history/ paste-cache/) hold stale copies of
    # edited files, including *.test.sh — executing those would run
    # arbitrary out-of-date code. They are anchored to $REPO_ROOT because
    # those runtime dirs live only at the deployed root — an any-depth
    # wildcard would also silently drop legitimate suites like
    # src/projects/widget.test.sh in other non-git copies. Harmless in a
    # normal repo checkout where the root-level dirs don't exist.
    find "$REPO_ROOT" -type f -name "*.test.sh" \
      -not -path "*/.git/*" \
      -not -path "*/.claude/worktrees/*" \
      -not -path "*/node_modules/*" \
      -not -path "$REPO_ROOT/projects/*" \
      -not -path "$REPO_ROOT/file-history/*" \
      -not -path "$REPO_ROOT/paste-cache/*" \
      -print0 | sort -z
  }
fi

SUITE_OUT=$(mktemp "${TMPDIR:-/tmp}/run-tests-suite-out.XXXXXX")
trap 'rm -f "$SUITE_OUT"' EXIT

while IFS= read -r -d '' suite; do
  suite_rel="${suite#"$REPO_ROOT"/}"

  # `bash "$suite"` runs each suite as its own fresh process (in its own
  # process group via set -m, so the watchdog kill below reaches the
  # suite's children too) — no shared shell state (cwd, variables, traps)
  # leaks between suites, and a suite that itself does `cd` cannot affect
  # this loop or any other suite.
  set -m 2>/dev/null || true
  bash "$suite" >"$SUITE_OUT" 2>&1 &
  suite_pid=$!
  set +m 2>/dev/null || true

  waited=0
  while kill -0 "$suite_pid" 2>/dev/null && [ "$waited" -lt "$SUITE_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$suite_pid" 2>/dev/null; then
    kill -- -"$suite_pid" 2>/dev/null || kill "$suite_pid" 2>/dev/null
    sleep 1
    # Escalate to SIGKILL on the WHOLE GROUP unconditionally: gating it on
    # the leader being alive lets a TERM-ignoring descendant survive when
    # the leader died first, leaking processes into subsequent suites.
    kill -9 -- -"$suite_pid" 2>/dev/null || kill -9 "$suite_pid" 2>/dev/null
    wait "$suite_pid" 2>/dev/null
    echo "FAIL: $suite_rel (TIMEOUT after ${SUITE_TIMEOUT}s — suite killed; hung suites usually mean a wait on a process that never exits or an accidental recursion)"
    tail -20 "$SUITE_OUT" | sed 's/^/  /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_SUITES="$FAILED_SUITES $suite_rel"
    continue
  fi

  if wait "$suite_pid"; then
    echo "PASS: $suite_rel"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $suite_rel"
    sed 's/^/  /' "$SUITE_OUT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_SUITES="$FAILED_SUITES $suite_rel"
  fi
done < <(discover_suites)

echo ""
echo "$PASS_COUNT passed, $FAIL_COUNT failed"

# Zero suites executed means discovery itself broke (e.g. a failure inside
# the discover_suites process substitution never reaches this shell), not
# that the repo has no tests — this repo always has *.test.sh suites.
# Without this guard the script would print "0 passed, 0 failed" and exit 0,
# silently running nothing on a supported platform.
if [ "$PASS_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo "run-tests.sh: no test suites were discovered — suite discovery failed" >&2
  exit 1
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "Failed suites:$FAILED_SUITES" >&2
  exit 1
fi

exit 0
