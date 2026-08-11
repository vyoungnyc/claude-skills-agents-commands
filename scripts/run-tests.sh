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
# `.git`, `.claude/worktrees`, and `node_modules` pruned) only when this repo
# has no git history to query, which in practice never happens here.
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
    # arbitrary out-of-date code. Harmless in a normal repo checkout where
    # these dirs don't exist.
    find "$REPO_ROOT" -type f -name "*.test.sh" \
      -not -path "*/.git/*" \
      -not -path "*/.claude/worktrees/*" \
      -not -path "*/node_modules/*" \
      -not -path "*/projects/*" \
      -not -path "*/file-history/*" \
      -not -path "*/paste-cache/*" \
      -print0 | sort -z
  }
fi

while IFS= read -r -d '' suite; do
  suite_rel="${suite#"$REPO_ROOT"/}"

  # `bash "$suite"` runs each suite as its own fresh process — no shared
  # shell state (cwd, variables, traps) leaks between suites, and a suite
  # that itself does `cd` cannot affect this loop or any other suite.
  if suite_output=$(bash "$suite" 2>&1); then
    echo "PASS: $suite_rel"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $suite_rel"
    echo "$suite_output" | sed 's/^/  /'
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
