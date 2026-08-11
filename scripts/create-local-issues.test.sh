#!/bin/bash
# Self-contained test suite for scripts/create-local-issues.sh.
# Style follows hooks/enforce-git-conventions.test.sh: set -euo pipefail,
# a jq guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# HARD ISOLATION: create-local-issues.sh does `cd "$(git rev-parse
# --show-toplevel)"` and appends to .gitignore. Every invocation in this
# suite therefore runs inside a throwaway `git init` sandbox created under
# this suite's own mktemp -d, never from this checkout. The suite also
# asserts the real repo's .gitignore is byte-identical before and after
# its own run (see the isolation self-check at the bottom of the file).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/create-local-issues.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ---------------------------------------------------------------------
# Isolation self-check (before) — snapshot the real repo's .gitignore so
# we can prove this run never touched it, no matter what the sandboxed
# invocations below do.
# ---------------------------------------------------------------------
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)"
REAL_GITIGNORE="$REAL_REPO_ROOT/.gitignore"
REAL_GITIGNORE_BEFORE=""
if [ -n "$REAL_REPO_ROOT" ] && [ -f "$REAL_GITIGNORE" ]; then
  REAL_GITIGNORE_BEFORE=$(cat "$REAL_GITIGNORE")
fi

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

EXERCISED_EXIT_CODES=""
record_exit() {
  case " $EXERCISED_EXIT_CODES " in
    *" $1 "*) ;;
    *) EXERCISED_EXIT_CODES="$EXERCISED_EXIT_CODES $1" ;;
  esac
}

# sandbox_new — create a fresh throwaway git repo under SUITE_TMP and
# print its path. Every invocation of the script under test happens
# inside one of these, satisfying the hard-isolation AC.
# NOTE: uses mktemp -d for uniqueness rather than a global counter,
# because this function is invoked via command substitution ($(...)),
# which runs it in a subshell — any counter increment there would be
# lost in the parent shell, silently reusing the same directory name
# for every call.
sandbox_new() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/sandbox.XXXXXX")
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test Suite"
  printf '%s' "$dir"
}

# run_in <dir> [args...] — runs the script under test with cwd=<dir>,
# capturing stdout/stderr/exit code into LAST_STDOUT/LAST_STDERR/LAST_EXIT.
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT=0
run_in() {
  local dir="$1"; shift
  local out="$SUITE_TMP/last_stdout"
  local err="$SUITE_TMP/last_stderr"
  set +e
  ( cd "$dir" && bash "$SCRIPT" "$@" ) >"$out" 2>"$err"
  LAST_EXIT=$?
  set -e
  LAST_STDOUT=$(cat "$out")
  LAST_STDERR=$(cat "$err")
}

# expect_exit <expected_code> <dir> [args...] — runs and asserts the exit
# code, recording it as exercised.
expect_exit() {
  local expected="$1"; shift
  local dir="$1"; shift
  run_in "$dir" "$@"
  [ "$LAST_EXIT" -eq "$expected" ] || fail "expected exit $expected, got $LAST_EXIT for args ($*) in $dir; stderr: $LAST_STDERR"
  record_exit "$expected"
}

expect_stderr_match() {
  local pattern="$1"
  echo "$LAST_STDERR" | grep -Eq "$pattern" || fail "stderr did not match /$pattern/: $LAST_STDERR"
}

expect_file_contains() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || fail "expected file $file to exist"
  grep -qF -e "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

expect_file_not_contains() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || fail "expected file $file to exist"
  grep -qF -e "$pattern" "$file" && fail "expected $file NOT to contain: $pattern"
  return 0
}

write_json() {
  # write_json <file> <content-via-stdin>
  cat > "$1"
}

# =======================================================================
# Happy path: 3 steps, deliberately out of alphabetical order, to prove
# output order follows input step order (not key sort) and that file
# names are zero-padded in that same order.
# =======================================================================
HP_DIR=$(sandbox_new)
write_json "$HP_DIR/steps.json" <<'EOF'
[
  {"step_id": "step_b", "title": "Second step", "acceptance_criteria": ["B1", "B2"], "file_domain": ["src/b/"], "complexity": "medium", "dependencies": [], "batch_hint": "backend"},
  {"step_id": "step_a", "title": "First step", "acceptance_criteria": [], "file_domain": ["src/a/"], "complexity": "low", "dependencies": ["step_b"], "batch_hint": "frontend"},
  {"step_id": "step_c", "title": "It's a test", "acceptance_criteria": ["C1"], "file_domain": ["src/c/"], "complexity": "high", "dependencies": [], "batch_hint": "backend"}
]
EOF

expect_exit 0 "$HP_DIR" "happyfeat" "steps.json"

echo "$LAST_STDOUT" | jq -e '.' >/dev/null || fail "happy path stdout is not valid JSON"
[ "$(echo "$LAST_STDOUT" | jq -r '.epic')" = "plans/happyfeat/issue-0000.md" ] || fail "unexpected .epic value"

# Issue map: step order (input order), not alphabetical, 4-digit padding.
EXPECTED_ORDER="step_b plans/happyfeat/issue-0001.md
step_a plans/happyfeat/issue-0002.md
step_c plans/happyfeat/issue-0003.md"
ACTUAL_ORDER=$(echo "$LAST_STDOUT" | jq -r '.issues | to_entries[] | .key + " " + .value')
[ "$ACTUAL_ORDER" = "$EXPECTED_ORDER" ] || fail "issue map order/paths mismatch:
expected:
$EXPECTED_ORDER
actual:
$ACTUAL_ORDER"

# --- File contents: front matter, AC lines, empty-AC placeholder -------
ISSUE_B="$HP_DIR/plans/happyfeat/issue-0001.md"
ISSUE_A="$HP_DIR/plans/happyfeat/issue-0002.md"
ISSUE_C="$HP_DIR/plans/happyfeat/issue-0003.md"

expect_file_contains "$ISSUE_B" "step_id: 'step_b'"
expect_file_contains "$ISSUE_B" "title: 'Second step'"
expect_file_contains "$ISSUE_B" "status: open"
expect_file_contains "$ISSUE_B" "complexity: medium"
expect_file_contains "$ISSUE_B" "domain: backend"
expect_file_contains "$ISSUE_B" "feature: happyfeat"
expect_file_contains "$ISSUE_B" "created:"
expect_file_contains "$ISSUE_B" "- [ ] B1"
expect_file_contains "$ISSUE_B" "- [ ] B2"

# step_a has an empty acceptance_criteria array -> placeholder line.
expect_file_contains "$ISSUE_A" "- [ ] (no acceptance criteria defined)"

# --- YAML apostrophe escaping -------------------------------------------
# 'It's a test' -> 'It''s a test' (single-quote doubling per yaml_escape()).
expect_file_contains "$ISSUE_C" "title: 'It''s a test'"
expect_file_contains "$ISSUE_C" "# step_c: It's a test"

# --- Epic file: type, step count, task-list links, quality gates -------
EPIC="$HP_DIR/plans/happyfeat/issue-0000.md"
expect_file_contains "$EPIC" "type: epic"
expect_file_contains "$EPIC" "feature: happyfeat"
expect_file_contains "$EPIC" "**Steps:** 3"
expect_file_contains "$EPIC" "[step_b: Second step](plans/happyfeat/issue-0001.md)"
expect_file_contains "$EPIC" "[step_a: First step](plans/happyfeat/issue-0002.md)"
expect_file_contains "$EPIC" "[step_c: It's a test](plans/happyfeat/issue-0003.md)"
expect_file_contains "$EPIC" "- [ ] Code review passed"
expect_file_contains "$EPIC" "- [ ] Security review passed"
expect_file_contains "$EPIC" "- [ ] All tests passing"
expect_file_contains "$EPIC" "- [ ] Docs updated"

# =======================================================================
# Overwrite protection: a second run over the same plans/<feature_id>/
# must exit 1, leave the existing files byte-identical, and
# FORCE_OVERWRITE=1 must exit 0 and actually rewrite them.
# =======================================================================
EPIC_BEFORE=$(cat "$EPIC")
ISSUE_B_BEFORE=$(cat "$ISSUE_B")

expect_exit 1 "$HP_DIR" "happyfeat" "steps.json"
expect_stderr_match "Issue files already exist"

[ "$(cat "$EPIC")" = "$EPIC_BEFORE" ] || fail "epic file changed after a rejected overwrite"
[ "$(cat "$ISSUE_B")" = "$ISSUE_B_BEFORE" ] || fail "issue-0001.md changed after a rejected overwrite"

# Modify the input so a rewrite is observable, then force it.
write_json "$HP_DIR/steps2.json" <<'EOF'
[
  {"step_id": "step_b", "title": "Second step UPDATED", "acceptance_criteria": ["B1", "B2"], "file_domain": ["src/b/"], "complexity": "medium", "dependencies": [], "batch_hint": "backend"},
  {"step_id": "step_a", "title": "First step", "acceptance_criteria": [], "file_domain": ["src/a/"], "complexity": "low", "dependencies": ["step_b"], "batch_hint": "frontend"},
  {"step_id": "step_c", "title": "It's a test", "acceptance_criteria": ["C1"], "file_domain": ["src/c/"], "complexity": "high", "dependencies": [], "batch_hint": "backend"}
]
EOF

FORCE_OVERWRITE=1 run_in "$HP_DIR" "happyfeat" "steps2.json"
[ "$LAST_EXIT" -eq 0 ] || fail "FORCE_OVERWRITE=1 expected exit 0, got $LAST_EXIT; stderr: $LAST_STDERR"
record_exit 0
expect_file_contains "$ISSUE_B" "title: 'Second step UPDATED'"
[ "$(cat "$ISSUE_B")" != "$ISSUE_B_BEFORE" ] || fail "FORCE_OVERWRITE=1 did not rewrite issue-0001.md"

# =======================================================================
# Exit 10, four ways: no arguments; plan-steps file missing; invalid
# JSON; empty array. Each in its own fresh sandbox.
# =======================================================================
NOARGS_DIR=$(sandbox_new)
expect_exit 10 "$NOARGS_DIR"
expect_stderr_match "Usage: create-local-issues.sh"

MISSING_DIR=$(sandbox_new)
expect_exit 10 "$MISSING_DIR" "missingfeat" "does-not-exist.json"
expect_stderr_match "Plan steps file not found"

INVALID_DIR=$(sandbox_new)
write_json "$INVALID_DIR/bad.json" <<'EOF'
this is not json
EOF
expect_exit 10 "$INVALID_DIR" "invalidfeat" "bad.json"
expect_stderr_match "not valid JSON"
# DEF-5 (fixed, scripts/create-local-issues.sh): mkdir -p "$PLANS_DIR" now
# runs only after the plan-steps JSON has been parsed and validated, so the
# invalid-JSON exit-10 path leaves no plans/<feature_id>/ directory behind.
[ ! -d "$INVALID_DIR/plans/invalidfeat" ] || fail "DEF-5: expected no plans/invalidfeat/ dir to be left behind on invalid-JSON exit 10"

EMPTY_DIR=$(sandbox_new)
write_json "$EMPTY_DIR/empty.json" <<'EOF'
[]
EOF
expect_exit 10 "$EMPTY_DIR" "emptyfeat" "empty.json"
expect_stderr_match "at least one step"

# =======================================================================
# SKIP_GITIGNORE branches.
# =======================================================================
GI_STEPS='[{"step_id": "step_01", "title": "T", "acceptance_criteria": [], "file_domain": ["src/"], "complexity": "low", "dependencies": [], "batch_hint": "backend"}]'

# (1) Unset, in a repo whose .gitignore lacks "plans/" -> gains an entry,
# original content preserved (appended, not overwritten).
GI_APPEND_DIR=$(sandbox_new)
write_json "$GI_APPEND_DIR/.gitignore" <<'EOF'
node_modules/
EOF
write_json "$GI_APPEND_DIR/steps.json" <<< "$GI_STEPS"
expect_exit 0 "$GI_APPEND_DIR" "gifeat" "steps.json"
expect_file_contains "$GI_APPEND_DIR/.gitignore" "node_modules/"
expect_file_contains "$GI_APPEND_DIR/.gitignore" "plans/"

# (2) SKIP_GITIGNORE=1 -> file byte-unchanged.
GI_SKIP_DIR=$(sandbox_new)
write_json "$GI_SKIP_DIR/.gitignore" <<'EOF'
node_modules/
EOF
write_json "$GI_SKIP_DIR/steps.json" <<< "$GI_STEPS"
GI_SKIP_BEFORE=$(cat "$GI_SKIP_DIR/.gitignore")
SKIP_GITIGNORE=1 run_in "$GI_SKIP_DIR" "gifeat" "steps.json"
[ "$LAST_EXIT" -eq 0 ] || fail "SKIP_GITIGNORE=1 expected exit 0, got $LAST_EXIT; stderr: $LAST_STDERR"
record_exit 0
[ "$(cat "$GI_SKIP_DIR/.gitignore")" = "$GI_SKIP_BEFORE" ] || fail "SKIP_GITIGNORE=1 modified .gitignore"

# (3) No .gitignore yet, unset -> one is created containing "plans/".
GI_CREATE_DIR=$(sandbox_new)
write_json "$GI_CREATE_DIR/steps.json" <<< "$GI_STEPS"
[ ! -f "$GI_CREATE_DIR/.gitignore" ] || fail "test setup error: .gitignore should not pre-exist"
expect_exit 0 "$GI_CREATE_DIR" "gifeat" "steps.json"
[ -f "$GI_CREATE_DIR/.gitignore" ] || fail "expected .gitignore to be created"
expect_file_contains "$GI_CREATE_DIR/.gitignore" "plans/"

# =======================================================================
# Optional roadmap file.
# =======================================================================
RM_STEPS='[{"step_id": "step_01", "title": "T", "acceptance_criteria": [], "file_domain": ["src/"], "complexity": "low", "dependencies": [], "batch_hint": "backend"}]'

# Valid roadmap -> renders a populated table.
RM_VALID_DIR=$(sandbox_new)
write_json "$RM_VALID_DIR/steps.json" <<< "$RM_STEPS"
write_json "$RM_VALID_DIR/roadmap.json" <<'EOF'
[{"phase": "Phase 1", "summary": "Setup"}, {"phase": "Phase 2", "summary": "Build"}]
EOF
expect_exit 0 "$RM_VALID_DIR" "rmfeat" "steps.json" "roadmap.json"
RM_VALID_EPIC="$RM_VALID_DIR/plans/rmfeat/issue-0000.md"
expect_file_contains "$RM_VALID_EPIC" "## Roadmap"
expect_file_contains "$RM_VALID_EPIC" "| Phase 1 | In Progress | Setup |"
expect_file_contains "$RM_VALID_EPIC" "| Phase 2 | Planned | Build |"

# Absent roadmap arg -> no roadmap section at all.
RM_ABSENT_DIR=$(sandbox_new)
write_json "$RM_ABSENT_DIR/steps.json" <<< "$RM_STEPS"
expect_exit 0 "$RM_ABSENT_DIR" "rmfeat" "steps.json"
expect_file_not_contains "$RM_ABSENT_DIR/plans/rmfeat/issue-0000.md" "## Roadmap"

# DEF-6 (fixed, scripts/create-local-issues.sh) -> malformed roadmap JSON
# still exits 0 (jq failure is caught by `|| true`), and the roadmap rows
# are now parsed before the "## Roadmap" heading/table header is built, so
# a parse failure omits the whole section rather than leaving a
# header-only, zero-row table. Matches the PRD AC (section fully omitted).
RM_MALFORMED_DIR=$(sandbox_new)
write_json "$RM_MALFORMED_DIR/steps.json" <<< "$RM_STEPS"
write_json "$RM_MALFORMED_DIR/roadmap.json" <<'EOF'
this is not valid json
EOF
expect_exit 0 "$RM_MALFORMED_DIR" "rmfeat" "steps.json" "roadmap.json"
RM_MALFORMED_EPIC="$RM_MALFORMED_DIR/plans/rmfeat/issue-0000.md"
expect_file_not_contains "$RM_MALFORMED_EPIC" "## Roadmap"

# =======================================================================
# Isolation self-check (after) — the real repo's .gitignore must be
# byte-identical to what it was before this suite ran.
# =======================================================================
REAL_GITIGNORE_AFTER=""
if [ -n "$REAL_REPO_ROOT" ] && [ -f "$REAL_GITIGNORE" ]; then
  REAL_GITIGNORE_AFTER=$(cat "$REAL_GITIGNORE")
fi
[ "$REAL_GITIGNORE_BEFORE" = "$REAL_GITIGNORE_AFTER" ] || fail "real repo .gitignore was modified by this test run (isolation breach)"

echo "Exercised exit codes:$EXERCISED_EXIT_CODES"
echo "create-local-issues.sh tests passed"
