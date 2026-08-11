#!/bin/bash
# Self-contained test suite for scripts/poll-mr-reviews.sh (REQ-004).
# Deliberately duplicates its own fail()/expect_*/stub scaffolding rather than
# sourcing a shared helper — see docs/features/script_tests/ARCHITECTURE.md §4.
#
# Contract asserted: exit codes 0/1/2/3/4/10/11 (poll-mr-reviews.sh's full
# documented set — unlike poll-pr-reviews.sh, exit 4 IS reachable here since
# PIPELINE_FAILED is GitLab-only).
#
# Seam: a stub `glab` prepended onto PATH, dispatching on the API path
# (discussions/pipelines/approvals/award_emoji) with per-call fixtures
# selected by a per-endpoint counter file. The real script fetches all four
# endpoints in parallel and `wait`s; the stub is concurrency-safe by
# construction, not by locking — each endpoint has its own counter/fixture
# files and is never invoked concurrently with itself (calls to the same
# endpoint are always separated by the script's own `wait`).
#
# Every invocation runs inside one throwaway `git init` sandbox (under this
# suite's own temp dir) with a fake `origin` remote, because the script
# derives PROJECT_SLUG from `git remote get-url origin`.

set -euo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_MR="$SUITE_DIR/poll-mr-reviews.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Sandbox + stub scaffolding
# ---------------------------------------------------------------------------

SCRATCH=$(mktemp -d)
SANDBOX="$SCRATCH/repo"
STUB_BIN="$SCRATCH/bin"
ERR_FILE="$SCRATCH/stderr.log"
SPAWNED_PID=""

mkdir -p "$SANDBOX" "$STUB_BIN"

cat > "$STUB_BIN/glab" <<'STUB'
#!/bin/bash
# Stub glab: dispatches on the API path, returns per-call fixtures.
# GLAB_FIXTURES_DIR points at a per-test directory of fixture/counter files.
if [ "$1" != "api" ]; then
  exit 0
fi
path="$2"
case "$path" in
  *discussions*)  ep=discussions ;;
  *pipelines*)    ep=pipelines ;;
  *award_emoji*)  ep=award_emoji ;;
  *approvals*)    ep=approvals ;;
  *)              ep=unknown ;;
esac
dir="${GLAB_FIXTURES_DIR:-/nonexistent}"
count_file="$dir/${ep}.count"
n=0
[ -f "$count_file" ] && n=$(cat "$count_file")
n=$((n + 1))
echo "$n" > "$count_file"
fixture="$dir/${ep}_${n}.json"
if [ -f "$fixture" ]; then
  cat "$fixture"
else
  default="$dir/${ep}_default.json"
  [ -f "$default" ] && cat "$default"
fi
exit 0
STUB
chmod +x "$STUB_BIN/glab"

PATH="$STUB_BIN:$PATH"
export PATH

cleanup_suite() {
  [ -n "$SPAWNED_PID" ] && kill "$SPAWNED_PID" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH" >/dev/null 2>&1 || true
}
trap cleanup_suite EXIT

cd "$SANDBOX"
git init -q
git remote add origin "https://gitlab.example.com/default/repo.git"

PID_PREFIX=$$
CASE_N=0
next_mr_iid() {
  CASE_N=$((CASE_N + 1))
  echo "${PID_PREFIX}${CASE_N}"
}

FIXTURE_DIR=""
new_fixture_dir() {
  FIXTURE_DIR=$(mktemp -d "$SCRATCH/fixtures.XXXXXX")
  GLAB_FIXTURES_DIR="$FIXTURE_DIR"
  export GLAB_FIXTURES_DIR
}

fixture() {
  # fixture <endpoint> <call_num> <json-on-stdin-via-heredoc-caller>
  local ep="$1" n="$2" json="$3"
  printf '%s' "$json" > "$FIXTURE_DIR/${ep}_${n}.json"
}

fixture_default() {
  local ep="$1" json="$2"
  printf '%s' "$json" > "$FIXTURE_DIR/${ep}_default.json"
}

# Sensible not-approved / no-op defaults so tests only need to override the
# calls they actually care about.
seed_neutral_defaults() {
  fixture_default approvals '{"approved": false, "approvals_left": -1, "approved_by": []}'
  fixture_default award_emoji '[]'
  fixture_default discussions '[]'
  fixture_default pipelines '[]'
}

OUT=""
CODE=0
run_and_capture() {
  # run_and_capture [mr] [interval] [max_polls]  — zero args means a truly
  # argument-less invocation (exercises the "missing mr_iid" usage path).
  OUT=$("$POLL_MR" "$@" 2>"$ERR_FILE") && CODE=0 || CODE=$?
}

wait_for_file() {
  local f="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$f" ] && return 0
    sleep 0.2
  done
  return 1
}

EXERCISED_CODES=""
mark_exercised() {
  case " $EXERCISED_CODES " in
    *" $1 "*) ;;
    *) EXERCISED_CODES="$EXERCISED_CODES $1" ;;
  esac
}

expect_exit() {
  local desc="$1" expected="$2" actual="$3"
  [ "$actual" = "$expected" ] || fail "$desc: expected exit $expected, got $actual (stderr: $(cat "$ERR_FILE" 2>/dev/null))"
}

expect_json() {
  local desc="$1" json="$2" jqfilter="$3"
  echo "$json" | jq -e "$jqfilter" >/dev/null 2>&1 \
    || fail "$desc: jq filter '$jqfilter' failed against: $json"
}

expect_stderr_match() {
  local desc="$1" pattern="$2"
  grep -Eq "$pattern" "$ERR_FILE" || fail "$desc: stderr did not match /$pattern/ (got: $(cat "$ERR_FILE"))"
}

# ---------------------------------------------------------------------------
# REQ-004 AC: slug derivation for both remote forms, pidfile lifecycle.
# Both forms must derive the same slug: "group-sub-proj" (.git stripped,
# "/" -> "-"). Each test also exercises exit 0 via native approval and the
# pidfile's create-during-run / remove-on-exit lifecycle.
# ---------------------------------------------------------------------------

assert_slug_and_pidfile_lifecycle() {
  local desc="$1" remote_url="$2" expected_slug="$3"
  local mr pidfile
  mr=$(next_mr_iid)
  git remote set-url origin "$remote_url"

  new_fixture_dir
  seed_neutral_defaults
  fixture approvals 1 '{"approved": true, "approvals_left": 5, "approved_by": [{"user": {"username": "alice"}}]}'

  pidfile="${TMPDIR:-/tmp}/poll-mr-reviews-${expected_slug}-${mr}.pid"
  rm -f "$pidfile"

  "$POLL_MR" "$mr" 1 1 >"$SCRATCH/out.json" 2>"$ERR_FILE" &
  local bgpid=$!

  wait_for_file "$pidfile" || fail "$desc: pidfile $pidfile never appeared while running"
  [ -s "$pidfile" ] || fail "$desc: pidfile $pidfile exists but is empty"

  local code
  wait "$bgpid" && code=0 || code=$?
  expect_exit "$desc" 0 "$code"
  mark_exercised 0

  if [ -f "$pidfile" ]; then
    fail "$desc: pidfile $pidfile not removed after exit"
  fi

  expect_json "$desc gate" "$(cat "$SCRATCH/out.json")" '.gate == "native_approval"'
}

assert_slug_and_pidfile_lifecycle \
  "slug (https form)" \
  "https://gitlab.com/group/sub/proj.git" \
  "group-sub-proj"

assert_slug_and_pidfile_lifecycle \
  "slug (ssh form)" \
  "git@gitlab.com:group/sub/proj.git" \
  "group-sub-proj"

git remote set-url origin "https://gitlab.example.com/default/repo.git"

# ---------------------------------------------------------------------------
# Pidfile kill-previous-instance path (same semantics as REQ-003): the suite
# spawns its OWN sleep process, records it in the expected pidfile, and
# asserts the script kills exactly that process and logs the message. The
# suite must never signal a PID it did not create.
# ---------------------------------------------------------------------------

test_kill_previous_instance() {
  local mr slug pidfile old_pid
  mr=$(next_mr_iid)
  slug="default-repo"
  pidfile="${TMPDIR:-/tmp}/poll-mr-reviews-${slug}-${mr}.pid"

  sleep 30 &
  old_pid=$!
  disown "$old_pid" 2>/dev/null || true
  SPAWNED_PID="$old_pid"
  echo "$old_pid" > "$pidfile"

  new_fixture_dir
  seed_neutral_defaults
  fixture approvals 1 '{"approved": true, "approvals_left": 5, "approved_by": [{"user": {"username": "carol"}}]}'

  run_and_capture "$mr" 1 1
  expect_exit "kill-previous-instance" 0 "$CODE"
  mark_exercised 0

  expect_stderr_match "kill-previous-instance log line" \
    "Killed previous polling instance \\(PID $old_pid\\)"

  if kill -0 "$old_pid" >/dev/null 2>&1; then
    fail "kill-previous-instance: old pid $old_pid still alive after run"
  fi
  SPAWNED_PID=""

  if [ -f "$pidfile" ]; then
    fail "kill-previous-instance: pidfile not cleaned up"
  fi
}
test_kill_previous_instance

# ---------------------------------------------------------------------------
# Exit 0 — native approval (approved:true, and separately approvals_left:0)
# ---------------------------------------------------------------------------

test_approved_true() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture approvals 1 '{"approved": true, "approvals_left": 3, "approved_by": [{"user": {"username": "alice"}}, {"user": {"username": "bob"}}]}'

  run_and_capture "$mr" 1 1
  expect_exit "approved:true" 0 "$CODE"
  mark_exercised 0
  expect_json "approved:true status" "$OUT" '.status == "APPROVED"'
  expect_json "approved:true gate" "$OUT" '.gate == "native_approval"'
  expect_json "approved:true approved_by populated" "$OUT" '(.approved_by | length) == 2'
  expect_json "approved:true approved_by contains alice" "$OUT" '.approved_by | index("alice")'
}
test_approved_true

test_approvals_left_zero() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture approvals 1 '{"approved": false, "approvals_left": 0, "approved_by": [{"user": {"username": "dana"}}]}'

  run_and_capture "$mr" 1 1
  expect_exit "approvals_left:0" 0 "$CODE"
  mark_exercised 0
  expect_json "approvals_left:0 gate" "$OUT" '.gate == "native_approval"'
  expect_json "approvals_left:0 approved_by populated" "$OUT" '(.approved_by | length) == 1'
}
test_approvals_left_zero

# ---------------------------------------------------------------------------
# Exit 0 — award emoji (thumbsup from bot patterns, incl. gitlab-duo and
# gitlab-code-review)
# ---------------------------------------------------------------------------

test_award_emoji_gitlab_duo() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture award_emoji 1 '[{"name": "thumbsup", "user": {"username": "gitlab-duo"}}]'

  run_and_capture "$mr" 1 1
  expect_exit "award_emoji gitlab-duo" 0 "$CODE"
  mark_exercised 0
  expect_json "award_emoji gitlab-duo gate" "$OUT" '.gate == "award_emoji"'
  expect_json "award_emoji gitlab-duo approvers" "$OUT" '(.approvers | length) == 1 and .approvers[0].user == "gitlab-duo"'
}
test_award_emoji_gitlab_duo

test_award_emoji_gitlab_code_review() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture award_emoji 1 '[{"name": "thumbsup", "user": {"username": "gitlab-code-review"}}]'

  run_and_capture "$mr" 1 1
  expect_exit "award_emoji gitlab-code-review" 0 "$CODE"
  mark_exercised 0
  expect_json "award_emoji gitlab-code-review gate" "$OUT" '.gate == "award_emoji"'
}
test_award_emoji_gitlab_code_review

test_award_emoji_dependabot() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture award_emoji 1 '[{"name": "thumbsup", "user": {"username": "dependabot[bot]"}}]'

  run_and_capture "$mr" 1 1
  expect_exit "award_emoji dependabot[bot]" 0 "$CODE"
  mark_exercised 0
  expect_json "award_emoji dependabot gate" "$OUT" '.gate == "award_emoji"'
}
test_award_emoji_dependabot

# ---------------------------------------------------------------------------
# Ordering — approval checked before discussions: a fixture with BOTH an
# approval and a new discussion exits 0, not 1.
# ---------------------------------------------------------------------------

test_ordering_approval_before_discussions() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture discussions 1 '[]'
  fixture approvals 1 '{"approved": true, "approvals_left": 1, "approved_by": [{"user": {"username": "erin"}}]}'
  fixture discussions 2 '[
    {
      "id": "ord-1",
      "notes": [
        {
          "resolvable": true,
          "resolved": false,
          "author": {"username": "reviewer1"},
          "position": {"new_path": "src/x.rb", "new_line": 5},
          "body": "should not be reached",
          "created_at": "2024-01-01T00:00:00Z"
        }
      ]
    }
  ]'

  run_and_capture "$mr" 1 1
  expect_exit "ordering approval-before-discussions" 0 "$CODE"
  mark_exercised 0
  expect_json "ordering status" "$OUT" '.status == "APPROVED"'
  expect_json "ordering gate" "$OUT" '.gate == "native_approval"'
}
test_ordering_approval_before_discussions

# ---------------------------------------------------------------------------
# Exit 1 — new discussion appears on poll 2 (not poll 1), including the
# null-path/null-line case when `position` is absent from the note.
# ---------------------------------------------------------------------------

test_new_discussion_on_poll_2() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture discussions 1 '[]'
  fixture discussions 2 '[]'
  fixture discussions 3 '[
    {
      "id": "d-new-1",
      "notes": [
        {
          "resolvable": true,
          "resolved": false,
          "author": {"username": "reviewer2"},
          "body": "no position on this note",
          "created_at": "2024-02-02T00:00:00Z"
        }
      ]
    }
  ]'

  run_and_capture "$mr" 1 3
  expect_exit "new discussion poll 2" 1 "$CODE"
  mark_exercised 1
  expect_json "new discussion status" "$OUT" '.status == "NEW_COMMENTS"'
  expect_json "new discussion count" "$OUT" '.count == 1'
  expect_json "new discussion poll number" "$OUT" '.poll == 2'
  expect_json "new discussion fields" "$OUT" \
    '.discussions[0] | (.id == "d-new-1") and (.author == "reviewer2") and (.body == "no position on this note") and (.created == "2024-02-02T00:00:00Z")'
  expect_json "new discussion null path" "$OUT" '.discussions[0].path == null'
  expect_json "new discussion null line" "$OUT" '.discussions[0].line == null'
}
test_new_discussion_on_poll_2

# ---------------------------------------------------------------------------
# Exit 4 — failed pipeline whose id differs from the startup snapshot; and
# the negative control: a failed pipeline with the SAME id does not exit 4.
# ---------------------------------------------------------------------------

test_pipeline_failed_new_id() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture pipelines 1 '[{"id": 100, "status": "success"}]'
  fixture discussions 1 '[]'
  fixture discussions 2 '[]'
  fixture pipelines 2 '[{"id": 101, "status": "failed"}]'

  run_and_capture "$mr" 1 1
  expect_exit "pipeline failed new id" 4 "$CODE"
  mark_exercised 4
  expect_json "pipeline failed status" "$OUT" '.status == "PIPELINE_FAILED"'
  expect_json "pipeline failed id" "$OUT" '.pipeline_id == "101"'
  expect_json "pipeline failed pipeline_status" "$OUT" '.pipeline_status == "failed"'
}
test_pipeline_failed_new_id

test_pipeline_failed_same_id_negative_control() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture pipelines 1 '[{"id": 100, "status": "failed"}]'
  fixture discussions 1 '[]'
  fixture discussions 2 '[]'
  fixture pipelines 2 '[{"id": 100, "status": "failed"}]'

  run_and_capture "$mr" 1 1
  expect_exit "pipeline same-id negative control (must NOT be 4)" 2 "$CODE"
  mark_exercised 2
  expect_json "pipeline same-id negative control status" "$OUT" '.status == "IDLE_TIMEOUT"'
}
test_pipeline_failed_same_id_negative_control

# ---------------------------------------------------------------------------
# Exit 2 — idle timeout, nothing happens for max_polls iterations.
# ---------------------------------------------------------------------------

test_idle_timeout() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture discussions 1 '[]'
  fixture discussions 2 '[]'
  fixture pipelines 1 '[]'
  fixture pipelines 2 '[]'

  run_and_capture "$mr" 1 1
  expect_exit "idle timeout" 2 "$CODE"
  mark_exercised 2
  expect_json "idle timeout status" "$OUT" '.status == "IDLE_TIMEOUT"'
  expect_json "idle timeout polls_completed" "$OUT" '.polls_completed == 1'
  expect_json "idle timeout total_seconds" "$OUT" '.total_seconds == 1'
}
test_idle_timeout

# ---------------------------------------------------------------------------
# Exit 3 — blocked on human at the BLOCKED_THRESHOLD (3) boundary: same
# unresolved discussion present on every poll, exit fires on poll 3, not
# earlier.
# ---------------------------------------------------------------------------

test_blocked_on_human_threshold() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults

  local stale_note='[
    {
      "id": "d-stale-1",
      "notes": [
        {
          "resolvable": true,
          "resolved": false,
          "author": {"username": "reviewer3"},
          "position": {"new_path": "src/y.rb", "new_line": 9},
          "body": "still open",
          "created_at": "2024-03-03T00:00:00Z"
        }
      ]
    }
  ]'
  fixture discussions 1 "$stale_note"
  fixture discussions 2 "$stale_note"
  fixture discussions 3 "$stale_note"
  fixture discussions 4 "$stale_note"
  fixture pipelines 1 '[]'
  fixture pipelines 2 '[]'
  fixture pipelines 3 '[]'
  fixture pipelines 4 '[]'

  run_and_capture "$mr" 1 4
  expect_exit "blocked on human" 3 "$CODE"
  mark_exercised 3
  expect_json "blocked on human status" "$OUT" '.status == "BLOCKED_ON_HUMAN"'
  expect_json "blocked on human poll" "$OUT" '.poll == 3'
  expect_json "blocked on human stale_polls" "$OUT" '.stale_polls == 3'
  expect_json "blocked on human discussions non-empty" "$OUT" '(.discussions | length) == 1'
}
test_blocked_on_human_threshold

# ---------------------------------------------------------------------------
# Exit 10 — missing mr_iid; non-positive-integer mr_iid/interval/max_polls.
# Also checks the DEF-3 repair: usage-error stderr carries no
# unbound-variable noise from the EXIT trap.
# ---------------------------------------------------------------------------

test_usage_errors() {
  run_and_capture
  expect_exit "no arguments" 10 "$CODE"
  expect_stderr_match "no arguments message" "Usage: poll-mr-reviews.sh"
  mark_exercised 10
  if grep -qi "unbound variable" "$ERR_FILE"; then
    fail "DEF-3 regression: unbound-variable noise on usage error"
  fi

  local bad
  for bad in 0 -1 abc; do
    run_and_capture "$bad" 1 3
    expect_exit "mr_iid=$bad" 10 "$CODE"
    expect_stderr_match "mr_iid=$bad message" "mr_iid must be a positive integer"
  done

  local mr
  mr=$(next_mr_iid)

  for bad in 0 -1 abc; do
    run_and_capture "$mr" "$bad" 3
    expect_exit "poll_interval_sec=$bad" 10 "$CODE"
    expect_stderr_match "poll_interval_sec=$bad message" "poll_interval_sec must be a positive integer"
  done

  for bad in 0 -1 abc; do
    run_and_capture "$mr" 1 "$bad"
    expect_exit "max_polls=$bad" 10 "$CODE"
    expect_stderr_match "max_polls=$bad message" "max_polls must be a positive integer"
  done
}
test_usage_errors

# ---------------------------------------------------------------------------
# Exit 11 — empty or non-JSON discussions snapshot.
# ---------------------------------------------------------------------------

test_snapshot_failure_empty() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  # No discussions_1.json and no default -> stub prints nothing.

  run_and_capture "$mr" 1 1
  expect_exit "empty discussions snapshot" 11 "$CODE"
  mark_exercised 11
  expect_stderr_match "empty discussions snapshot message" "Failed to snapshot MR discussions"
}
test_snapshot_failure_empty

test_snapshot_failure_non_json() {
  local mr
  mr=$(next_mr_iid)
  new_fixture_dir
  fixture discussions 1 'not valid json {{{'

  run_and_capture "$mr" 1 1
  expect_exit "non-JSON discussions snapshot" 11 "$CODE"
  mark_exercised 11
  expect_stderr_match "non-JSON discussions snapshot message" "Failed to snapshot MR discussions"
}
test_snapshot_failure_non_json

# ---------------------------------------------------------------------------
# Concurrency safety of the stub: the script fetches four endpoints in
# parallel and `wait`s. Confirm every endpoint's counter/fixture file was
# written cleanly (no interleaving corruption) after a single poll cycle
# that necessarily fires all four in the background simultaneously.
# ---------------------------------------------------------------------------

test_concurrent_stub_safety() {
  local mr ep cf val
  mr=$(next_mr_iid)
  new_fixture_dir
  seed_neutral_defaults
  fixture approvals 1 '{"approved": true, "approvals_left": 0, "approved_by": [{"user": {"username": "frank"}}]}'

  run_and_capture "$mr" 1 1
  expect_exit "concurrent stub safety" 0 "$CODE"
  mark_exercised 0

  for ep in discussions pipelines approvals award_emoji; do
    cf="$FIXTURE_DIR/${ep}.count"
    [ -f "$cf" ] || fail "concurrent stub safety: no count file for $ep (endpoint never invoked)"
    val=$(cat "$cf")
    [[ "$val" =~ ^[0-9]+$ ]] || fail "concurrent stub safety: $ep count file corrupted: '$val'"
    [ "$val" -ge 1 ] || fail "concurrent stub safety: $ep count file is zero"
  done
}
test_concurrent_stub_safety

# ---------------------------------------------------------------------------
# REQ-009: report exercised exit codes vs. the documented set.
# ---------------------------------------------------------------------------

SORTED_CODES=$(echo "$EXERCISED_CODES" | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ')
echo "poll-mr-reviews.sh exit codes exercised: $SORTED_CODES(documented set: 0 1 2 3 4 10 11)"

echo "poll-mr-reviews.sh tests passed"
