#!/bin/bash
# Self-contained test suite for scripts/create-github-issues.sh.
# No network access; gh is stubbed via PATH. bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/create-github-issues.sh"
REAL_PATH="$PATH"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

OUT_FILE="$WORKDIR/out.json"
ERR_FILE="$WORKDIR/err.json"
EC=0

# ---------------------------------------------------------------------------
# Stub gh — recorded argv per call, dispatches on the first two args, and its
# behavior is steered by env vars the test cases export before invoking it.
# ---------------------------------------------------------------------------

STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
STUB_LOG="$WORKDIR/stub.log"
STUB_CALL_DIR="$WORKDIR/calls"
STUB_CALL_COUNTER="$WORKDIR/call_counter"
STUB_ISSUE_COUNTER="$WORKDIR/issue_counter"
export STUB_LOG STUB_CALL_DIR STUB_CALL_COUNTER STUB_ISSUE_COUNTER

cat > "$STUBDIR/gh" <<'STUBEOF'
#!/bin/bash
set -u

n=0
[ -f "$STUB_CALL_COUNTER" ] && n=$(cat "$STUB_CALL_COUNTER")
n=$((n + 1))
printf '%s' "$n" > "$STUB_CALL_COUNTER"

# One argument per line so a caller can grep for a flag's value without
# depending on exact shell quoting; body/title text may itself contain
# newlines, which just adds extra lines inside the same call's file.
printf '%s\n' "$@" > "$STUB_CALL_DIR/call_${n}.args"
printf '%s %s\n' "${1:-}" "${2:-}" >> "$STUB_LOG"

sub1="${1:-}"
sub2="${2:-}"

case "$sub1 $sub2" in
  "auth status")
    [ "${STUB_AUTH_FAIL:-0}" = "1" ] && exit 1
    exit 0
    ;;
  "repo view")
    [ "${STUB_REPO_VIEW_EMPTY:-0}" = "1" ] && exit 0
    printf '%s\n' "${STUB_REPO_NAME:-owner/repo}"
    exit 0
    ;;
  "label create")
    exit 0
    ;;
  "issue create")
    title=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--title" ]; then title="$a"; fi
      prev="$a"
    done

    is_epic=0
    case "$title" in
      Epic:*) is_epic=1 ;;
    esac

    if [ "$is_epic" = "1" ] && [ "${STUB_FAIL_EPIC:-0}" = "1" ]; then
      echo "stub: epic creation failed" >&2
      exit 1
    fi

    if [ "$is_epic" = "0" ] && [ -n "${STUB_FAIL_STEP:-}" ]; then
      case "$title" in
        "${STUB_FAIL_STEP}:"*)
          echo "stub: child issue failed" >&2
          exit 1
          ;;
      esac
    fi

    cnt=0
    [ -f "$STUB_ISSUE_COUNTER" ] && cnt=$(cat "$STUB_ISSUE_COUNTER")
    cnt=$((cnt + 1))
    printf '%s' "$cnt" > "$STUB_ISSUE_COUNTER"

    if [ "$is_epic" = "1" ] && [ "${STUB_BAD_EPIC_URL:-0}" = "1" ]; then
      echo "https://github.com/${STUB_REPO_NAME:-owner/repo}/pull/${cnt}"
      exit 0
    fi

    echo "https://github.com/${STUB_REPO_NAME:-owner/repo}/issues/${cnt}"
    exit 0
    ;;
  *)
    echo "stub gh: unhandled subcommand: $*" >&2
    exit 1
    ;;
esac
STUBEOF
chmod +x "$STUBDIR/gh"

reset_stub() {
  rm -rf "$STUB_CALL_DIR"
  mkdir -p "$STUB_CALL_DIR"
  : > "$STUB_LOG"
  echo 0 > "$STUB_CALL_COUNTER"
  echo 100 > "$STUB_ISSUE_COUNTER"
}
reset_stub

reset_stub_controls() {
  unset STUB_AUTH_FAIL STUB_REPO_VIEW_EMPTY STUB_FAIL_EPIC STUB_FAIL_STEP \
    STUB_BAD_EPIC_URL STUB_REPO_NAME 2>/dev/null || true
}
reset_stub_controls

# PATH variants that genuinely lack a binary — the real environment's PATH
# cannot be trusted to lack gh or jq (both exist as system binaries on some
# hosts), so these are curated symlink dirs containing only what's needed to
# reach the assertion point, deliberately excluding the target binary.
MINIMAL_NO_GH="$WORKDIR/path_no_gh"
mkdir -p "$MINIMAL_NO_GH"
ln -s "$(command -v cat)" "$MINIMAL_NO_GH/cat"
ln -s "$(command -v jq)" "$MINIMAL_NO_GH/jq"

MINIMAL_NO_JQ="$WORKDIR/path_no_jq"
mkdir -p "$MINIMAL_NO_JQ"
ln -s "$(command -v cat)" "$MINIMAL_NO_JQ/cat"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

FEATURE_ID="demo_feature"

PLAN_OK="$WORKDIR/plan_ok.json"
cat > "$PLAN_OK" <<'JSON'
[
  {
    "step_id": "step_01",
    "title": "First step",
    "acceptance_criteria": ["A works"],
    "file_domain": ["src/a/"],
    "complexity": "medium",
    "dependencies": [],
    "batch_hint": "backend"
  },
  {
    "step_id": "step_02",
    "title": "Second step",
    "acceptance_criteria": ["B works"],
    "file_domain": ["src/b/"],
    "complexity": "low",
    "dependencies": ["step_01"],
    "batch_hint": "frontend"
  }
]
JSON

PLAN_INVALID="$WORKDIR/plan_invalid.json"
printf '{not valid json' > "$PLAN_INVALID"

PLAN_EMPTY="$WORKDIR/plan_empty.json"
printf '[]' > "$PLAN_EMPTY"

PLAN_MISSING="$WORKDIR/does_not_exist.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_script() {
  # usage: run_script <PATH value> <script args...>
  local usepath="$1"; shift
  set +e
  PATH="$usepath" "$SCRIPT" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
  EC=$?
  set -e
}

EXERCISED_CODES=""
mark_exercised() {
  case " $EXERCISED_CODES " in
    *" $1 "*) ;;
    *) EXERCISED_CODES="$EXERCISED_CODES $1" ;;
  esac
}

expect_exit() {
  local desc="$1" expected="$2"
  [ "$EC" = "$expected" ] || fail "$desc: expected exit $expected, got $EC (stderr: $(cat "$ERR_FILE"), stdout: $(cat "$OUT_FILE"))"
  mark_exercised "$expected"
}

expect_jq() {
  local file="$1" filter="$2" desc="$3"
  jq -e "$filter" "$file" >/dev/null 2>&1 || fail "$desc (filter: $filter) against $file: $(cat "$file")"
}

expect_error_match() {
  local file="$1" pattern="$2" desc="$3"
  local msg
  msg=$(jq -r '.error // empty' "$file" 2>/dev/null || true)
  echo "$msg" | grep -Eq "$pattern" || fail "$desc: .error '$msg' did not match /$pattern/"
}

# Finds a stub call file whose args contain an exact line, e.g. the epic's
# --title value, then greps that same file's args for a substring.
call_file_containing_line() {
  local exact_line="$1" f
  for f in "$STUB_CALL_DIR"/*.args; do
    grep -Fqx -- "$exact_line" "$f" 2>/dev/null && { echo "$f"; return 0; }
  done
  return 1
}

# True if any recorded call has --repo followed by the expected value.
call_has_repo_value() {
  local expected="$1" f val
  for f in "$STUB_CALL_DIR"/*.args; do
    val=$(grep -A1 -Fx -- "--repo" "$f" 2>/dev/null | tail -n1)
    [ "$val" = "$expected" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Happy path — asserts JSON shape via jq, never string equality.
# ---------------------------------------------------------------------------

reset_stub
export GH_REPO="acme/demo"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "happy path" 0
expect_jq "$OUT_FILE" '.epic | type == "number"' "happy path .epic is a number"
expect_jq "$OUT_FILE" '(.issues | keys | sort) == ["step_01","step_02"]' "happy path .issues keys are exactly the input step_ids"
expect_jq "$OUT_FILE" '.issues.step_01 | type == "number"' "happy path .issues.step_01 is a number"
expect_jq "$OUT_FILE" '.issues.step_02 | type == "number"' "happy path .issues.step_02 is a number"
unset GH_REPO

# ---------------------------------------------------------------------------
# Exit 10 — usage errors, four ways.
# ---------------------------------------------------------------------------

run_script "$STUBDIR:$REAL_PATH"
expect_exit "no arguments" 10
expect_error_match "$ERR_FILE" "^Usage: create-github-issues\.sh" "no arguments"

run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_MISSING"
expect_exit "plan-steps file missing" 10
expect_error_match "$ERR_FILE" "not found" "plan-steps file missing"

run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_INVALID"
expect_exit "plan-steps file not valid JSON" 10
expect_error_match "$ERR_FILE" "not valid JSON" "plan-steps file not valid JSON"

run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_EMPTY"
expect_exit "plan-steps array empty" 10
expect_error_match "$ERR_FILE" "at least one step" "plan-steps array empty"

# ---------------------------------------------------------------------------
# Exit 1 — fatal errors, three ways.
# ---------------------------------------------------------------------------

# gh absent from PATH entirely (curated PATH, real PATH cannot be trusted to
# lack gh on every host).
run_script "$MINIMAL_NO_GH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "gh absent from PATH" 1
expect_error_match "$ERR_FILE" "gh CLI not found" "gh absent from PATH"

# gh auth status failing.
reset_stub
export STUB_AUTH_FAIL=1
export GH_REPO="acme/demo"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "gh auth status failing" 1
expect_error_match "$ERR_FILE" "not authenticated" "gh auth status failing"
unset STUB_AUTH_FAIL
unset GH_REPO

# Repo undeterminable — GH_REPO unset, gh repo view returns empty.
reset_stub
unset GH_REPO 2>/dev/null || true
export STUB_REPO_VIEW_EMPTY=1
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "repo undeterminable" 1
expect_error_match "$ERR_FILE" "Could not determine target repo" "repo undeterminable"
unset STUB_REPO_VIEW_EMPTY

# ---------------------------------------------------------------------------
# Exit 1 with partial output — only epic creation fails.
# ---------------------------------------------------------------------------

reset_stub
reset_stub_controls
export STUB_FAIL_EPIC=1
export GH_REPO="acme/demo"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "partial epic failure" 1
expect_jq "$OUT_FILE" '.epic == null' "partial epic failure .epic is null"
expect_jq "$OUT_FILE" '.issues.step_01 | type == "number"' "partial epic failure .issues.step_01 still populated"
expect_jq "$OUT_FILE" '.issues.step_02 | type == "number"' "partial epic failure .issues.step_02 still populated"
expect_jq "$OUT_FILE" '.error | type == "string"' "partial epic failure .error is a string"
unset STUB_FAIL_EPIC
unset GH_REPO

# ---------------------------------------------------------------------------
# Partial child failure — one of two child issues fails.
# ---------------------------------------------------------------------------

reset_stub
reset_stub_controls
export STUB_FAIL_STEP="step_01"
export GH_REPO="acme/demo"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "partial child failure" 0
expect_jq "$OUT_FILE" '.issues.step_01 == null' "partial child failure step_01 is null"
expect_jq "$OUT_FILE" '.issues.step_02 | type == "number"' "partial child failure step_02 still succeeds"
expect_jq "$OUT_FILE" '.epic | type == "number"' "partial child failure epic still created"

EPIC_CALL_FILE=$(call_file_containing_line "Epic: ${FEATURE_ID}") \
  || fail "partial child failure: could not find the epic's issue-create call in the stub log"
grep -Fq -- '(failed)' "$EPIC_CALL_FILE" \
  || fail "partial child failure: epic body did not contain a '(failed)' task-list line"
unset STUB_FAIL_STEP
unset GH_REPO

# ---------------------------------------------------------------------------
# Unparseable epic URL — stub returns a URL with no issues/<n> segment.
# ---------------------------------------------------------------------------

reset_stub
reset_stub_controls
export STUB_BAD_EPIC_URL=1
export GH_REPO="acme/demo"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "unparseable epic URL" 0
expect_jq "$OUT_FILE" '.epic == null' "unparseable epic URL .epic is null"
expect_jq "$OUT_FILE" '.epic_url | type == "string"' "unparseable epic URL .epic_url is a string"
unset STUB_BAD_EPIC_URL
unset GH_REPO

# ---------------------------------------------------------------------------
# GH_REPO honored — argv log shows --repo matching GH_REPO, gh repo view
# never called.
# ---------------------------------------------------------------------------

reset_stub
reset_stub_controls
export GH_REPO="acme/ghtest"
run_script "$STUBDIR:$REAL_PATH" "$FEATURE_ID" "$PLAN_OK"
expect_exit "GH_REPO honored" 0
call_has_repo_value "acme/ghtest" || fail "GH_REPO honored: no stub call carried --repo acme/ghtest"
grep -qx "repo view" "$STUB_LOG" && fail "GH_REPO honored: gh repo view was called despite GH_REPO being set"
unset GH_REPO

# ---------------------------------------------------------------------------
# DEF-4 (docs/features/script_tests/PRD.md) — jq is invoked at line 74,
# twenty-three lines before the `command -v jq` guard at line 97. With jq
# absent the script exits 10 ("Plan steps file is not valid JSON"), not the
# documented 1 ("jq not found") — the guard at line 97 is dead code. This
# asserts the OBSERVED behavior, not the aspirational documented contract.
# ---------------------------------------------------------------------------

run_script "$MINIMAL_NO_JQ" "$FEATURE_ID" "$PLAN_OK"
expect_exit "DEF-4: jq absent exits 10, not documented 1" 10
expect_error_match "$ERR_FILE" "not valid JSON" "DEF-4: jq absent"

# ---------------------------------------------------------------------------
# REQ-009 — state exercised exit codes rather than assuming them.
# Documented set for create-github-issues.sh: 0, 1, 10. Accumulated via
# mark_exercised (called from expect_exit on every successful assertion)
# rather than a hardcoded string, so this can't silently drift if a case
# above is ever removed.
# ---------------------------------------------------------------------------

SORTED_CODES=$(echo "$EXERCISED_CODES" | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ')
echo "create-github-issues.sh exit codes exercised: $SORTED_CODES(documented set: 0 1 10)"
echo "create-github-issues.sh tests passed"
