#!/bin/bash
# Self-contained test suite for hooks/plan-context.sh.
# Style follows hooks/pr-merge-sync-reminder.test.sh / scripts/create-local-issues.test.sh:
# set -euo pipefail, fail() to stderr + exit 1, mktemp -d sandbox, cleanup trap,
# flat top-level assertion calls, no test framework.
#
# plan-context.sh is a PostCompact hook that reads NO stdin — it only reads
# plans/<feature>/PLAN_steps.md (and docs/features/<feature>/PLAN_steps.md,
# and a top-level PLAN_steps.md) relative to its own cwd. Every case below
# runs the hook with cwd pointed at a throwaway sandbox built under this
# suite's own mktemp -d, so nothing here reads or writes the real repo's
# plan files.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/plan-context.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

# sandbox_new — a fresh throwaway directory under SUITE_TMP. Uses mktemp -d
# for uniqueness (not a counter) since it may be called via command
# substitution, which runs in a subshell — a counter increment there would
# be lost in the parent shell.
sandbox_new() {
  mktemp -d "$SUITE_TMP/sandbox.XXXXXX"
}

# write_plan <path-under-sandbox> — writes stdin (heredoc) to <path>,
# creating parent directories as needed.
write_plan() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

# run_hook <dir> — runs the hook with cwd=<dir> and no stdin, capturing
# stdout into LAST_OUT. The hook never reads stdin; </dev/null makes that
# explicit and keeps a hung read from ever being possible here.
LAST_OUT=""
run_hook() {
  local dir="$1"
  LAST_OUT=$(cd "$dir" && bash "$HOOK" </dev/null)
}

# =======================================================================
# (a) Fully-completed status-dialect plan: every step's status: is
# "completed", with unchecked "- [ ]" acceptance-criteria boxes inside
# each step (which stay unchecked forever once a step is done). The plan
# must be treated as fully done — the hook prints NOTHING (exit 0, empty
# stdout) when it is the only plan present.
# =======================================================================
A_DIR=$(sandbox_new)
write_plan "$A_DIR/plans/featurea/PLAN_steps.md" <<'EOF'
- `step_id`: "featurea.step_01"
  title: "First step"
  status: "completed"
  acceptance_criteria:
    - [ ] Never checked, step is done anyway
- `step_id`: "featurea.step_02"
  title: "Second step"
  status: "completed"
  acceptance_criteria:
    - [ ] Also never checked
EOF

run_hook "$A_DIR"
[ -z "$LAST_OUT" ] || fail "(a) expected empty output for a fully-completed status-dialect plan, got: $LAST_OUT"

# =======================================================================
# (b) status-dialect plan, 1 pending step among N (3) completed steps:
# output must include the pending step's step_id and status lines, must
# NOT include any completed step_id, and must include the "(N
# completed/closed entries omitted)" count.
# =======================================================================
B_DIR=$(sandbox_new)
write_plan "$B_DIR/plans/featureb/PLAN_steps.md" <<'EOF'
- `step_id`: "featureb.step_01"
  status: "completed"
- `step_id`: "featureb.step_02"
  status: "completed"
- `step_id`: "featureb.step_03"
  status: "pending"
- `step_id`: "featureb.step_04"
  status: "completed"
EOF

run_hook "$B_DIR"
echo "$LAST_OUT" | grep -qF 'featureb.step_03' \
  || fail "(b) expected pending step_id 'featureb.step_03' in output: $LAST_OUT"
echo "$LAST_OUT" | grep -qF 'status: "pending"' \
  || fail "(b) expected the pending step's status line in output: $LAST_OUT"
echo "$LAST_OUT" | grep -qF 'featureb.step_01' && fail "(b) completed step_id 'featureb.step_01' leaked into output"
echo "$LAST_OUT" | grep -qF 'featureb.step_02' && fail "(b) completed step_id 'featureb.step_02' leaked into output"
echo "$LAST_OUT" | grep -qF 'featureb.step_04' && fail "(b) completed step_id 'featureb.step_04' leaked into output"
echo "$LAST_OUT" | grep -qF '(3 completed/closed entries omitted)' \
  || fail "(b) expected omitted-count footer '(3 completed/closed entries omitted)': $LAST_OUT"

# =======================================================================
# (c) status-less step fail-open: one completed step, and one step that
# has a step_id but NO status: line at all (freshly authored, hand-
# edited). The status-less step_id must still be surfaced via the
# END-of-file flush — never silently dropped.
# =======================================================================
C_DIR=$(sandbox_new)
write_plan "$C_DIR/plans/featurec/PLAN_steps.md" <<'EOF'
- `step_id`: "featurec.step_01"
  status: "completed"
- `step_id`: "featurec.step_02"
  title: "freshly authored, no status field yet"
EOF

run_hook "$C_DIR"
echo "$LAST_OUT" | grep -qF 'featurec.step_02' \
  || fail "(c) expected status-less step_id 'featurec.step_02' to be fail-open surfaced (END flush): $LAST_OUT"
echo "$LAST_OUT" | grep -qF 'featurec.step_01' && fail "(c) completed step_id 'featurec.step_01' should not appear"

# =======================================================================
# (d) checkbox-only dialect (no status: lines anywhere): only unfinished
# "[ ]" markers print; finished "[✅]" markers are omitted. A checkbox
# plan with ONLY "[✅]" markers prints nothing at all.
# =======================================================================
D1_DIR=$(sandbox_new)
write_plan "$D1_DIR/plans/featured1/PLAN_steps.md" <<'EOF'
- [✅] Done task one
- [ ] Pending task two
- [✅] Done task three
EOF

run_hook "$D1_DIR"
echo "$LAST_OUT" | grep -qF 'Pending task two' \
  || fail "(d) expected unfinished checkbox line 'Pending task two' in output: $LAST_OUT"
echo "$LAST_OUT" | grep -qF 'Done task one' && fail "(d) finished [✅] checkbox line 'Done task one' leaked into output"
echo "$LAST_OUT" | grep -qF 'Done task three' && fail "(d) finished [✅] checkbox line 'Done task three' leaked into output"

D2_DIR=$(sandbox_new)
write_plan "$D2_DIR/plans/featured2/PLAN_steps.md" <<'EOF'
- [✅] Done task one
- [✅] Done task two
EOF

run_hook "$D2_DIR"
[ -z "$LAST_OUT" ] || fail "(d) expected empty output for a checkbox-only plan with only [✅] markers, got: $LAST_OUT"

# =======================================================================
# (e) Truncation priority: status-dialect plan with 25 completed steps
# BEFORE 1 pending step. The pending step's step_id + status must still
# appear in the output — head -20 must not crowd it out, regardless of
# how many completed steps precede it in the file.
# =======================================================================
E_DIR=$(sandbox_new)
E_PLAN="$E_DIR/plans/featuree/PLAN_steps.md"
mkdir -p "$(dirname "$E_PLAN")"
: > "$E_PLAN"
i=1
while [ "$i" -le 25 ]; do
  printf -- '- `step_id`: "featuree.step_%02d"\n' "$i" >> "$E_PLAN"
  printf '  status: "completed"\n' >> "$E_PLAN"
  printf '  acceptance_criteria:\n' >> "$E_PLAN"
  printf '    - [ ] Never checked, step %02d is done anyway\n' "$i" >> "$E_PLAN"
  i=$((i + 1))
done
printf -- '- `step_id`: "featuree.step_pending"\n' >> "$E_PLAN"
printf '  status: "pending"\n' >> "$E_PLAN"

run_hook "$E_DIR"
echo "$LAST_OUT" | grep -qF 'featuree.step_pending' \
  || fail "(e) expected pending step_id 'featuree.step_pending' to survive the head -20 cap despite 25 preceding completed steps: $LAST_OUT"
echo "$LAST_OUT" | grep -qF 'status: "pending"' \
  || fail "(e) expected the pending step's status line in output: $LAST_OUT"
echo "$LAST_OUT" | grep -qF '(25 completed/closed entries omitted)' \
  || fail "(e) expected omitted-count footer '(25 completed/closed entries omitted)': $LAST_OUT"

echo "plan-context.sh tests passed"
