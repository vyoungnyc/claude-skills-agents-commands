#!/bin/bash
# scripts/sync-omp-config.test.sh — tests for the Claude->omp converter/sync.
#
# Style follows scripts/sync-claude-config.test.sh / hooks/*.test.sh:
# set -euo pipefail, fail() to stderr + exit 1, mktemp -d sandboxes, cleanup
# trap, jq skip-guard, flat top-level assertion calls, no test framework.
#
# sync-omp-config.sh derives REPO_ROOT from its own location, so each case
# copies the script into a self-contained sandbox repo (scripts/ + Claude
# source dirs) and runs the COPY with OMP_HOME pointed at a sandbox target —
# the real ~/.omp is never touched.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq is required to run tests" >&2; exit 1; }

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$THIS_DIR/sync-omp-config.sh"
[ -f "$SCRIPT" ] || { echo "cannot find sync-omp-config.sh next to test" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

SUITE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$SUITE_TMP"; }
trap cleanup EXIT

# Build a sandbox repo with the script + representative Claude source config.
# Echoes the sandbox repo root.
setup_repo() {
  local dir
  dir="$(mktemp -d "$SUITE_TMP/repo.XXXXXX")"
  mkdir -p "$dir/scripts" "$dir/agents" "$dir/skills/demo-skill" "$dir/commands" "$dir/hooks"
  cp "$SCRIPT" "$dir/scripts/sync-omp-config.sh"

  # read-only agent: opus, Claude tool names + an mcp__ + LS that must drop.
  cat > "$dir/agents/checker.md" <<'EOF'
---
name: checker
description: "Read-only checker."
tools: Read, Grep, Glob, Bash, LS, mcp__context7
model: opus
memory: project
maxTurns: 20
permissionMode: plan
---
BODY-CHECKER
second line
EOF

  # spawning agent: sonnet, includes Agent/Task -> should yield omp `task`.
  cat > "$dir/agents/boss.md" <<'EOF'
---
name: boss
description: "Coordinator."
tools: Read, Write, Edit, Agent, Task, AskUserQuestion, TaskList, SendMessage
model: sonnet
---
BODY-BOSS
EOF

  cat > "$dir/skills/demo-skill/SKILL.md" <<'EOF'
---
name: demo-skill
description: "Demo."
---
SKILL-BODY
EOF

  cat > "$dir/commands/do-thing.md" <<'EOF'
---
name: do-thing
description: "Does thing."
model: haiku
---
COMMAND-BODY $ARGUMENTS
EOF

  cat > "$dir/hooks/echoer.sh" <<'EOF'
#!/bin/bash
echo hi
EOF
  # a *.test.sh that must NOT be deployed
  cat > "$dir/hooks/echoer.test.sh" <<'EOF'
#!/bin/bash
echo test
EOF

  # omp-native extension package + shared settings seed (deployed verbatim).
  mkdir -p "$dir/omp-extensions/caveman/src"
  cat > "$dir/omp-extensions/caveman/package.json" <<'EOF'
{ "name": "caveman", "type": "module", "omp": { "name": "Caveman", "extensions": ["src/index.ts"] } }
EOF
  cat > "$dir/omp-extensions/caveman/src/index.ts" <<'EOF'
export default function caveman() {}
EOF
  cat > "$dir/omp-extensions/caveman/caveman.default.json" <<'EOF'
{ "defaultLevel": "full", "showStatus": true }
EOF

  echo "$dir"
}

run() {
  # $1 = repo dir; rest = args. Sets OMP_HOME to <repo>/omp.
  local dir="$1"; shift
  OMP_HOME="$dir/omp" bash "$dir/scripts/sync-omp-config.sh" "$@"
}

# ============================================================ (1) conversion
R="$(setup_repo)"
run "$R" --apply >/dev/null 2>&1 || fail "(1) --apply exited nonzero"
AG="$R/omp/agent/agents/checker.md"
[ -f "$AG" ] || fail "(1) checker.md not deployed"
# First-ever deploy created the dirs from nothing — there is no prior state,
# so no backup snapshot must be produced (mirrors the whole-dir contract).
[ ! -d "$R/omp/backups" ] || fail "(1) first-ever deploy must not create a backup"
grep -q '^tools: read, grep, glob, bash$' "$AG" \
  || fail "(1) checker tools not translated to 'read, grep, glob, bash': $(grep '^tools:' "$AG")"
grep -q 'LS\|mcp__\|write\|edit' "$AG" \
  && fail "(1) checker leaked a dropped/unmapped tool into: $(grep '^tools:' "$AG")"
grep -q '^model:' "$AG" && fail "(1) model must be dropped without --map-models"
grep -Eq '^(memory|maxTurns|permissionMode):' "$AG" && fail "(1) Claude-only keys not stripped"
grep -q '^BODY-CHECKER$' "$AG" || fail "(1) body first line not preserved"
grep -q '^second line$' "$AG" || fail "(1) body second line not preserved"

# ============================================================ (2) task/spawn
BOSS="$R/omp/agent/agents/boss.md"
grep -q '^tools: read, write, edit, task, ask, todo, hub$' "$BOSS" \
  || fail "(2) boss tools not translated (Agent/Task->task, dedup): $(grep '^tools:' "$BOSS")"

# ============================================================ (3) skills/cmds verbatim
diff -q "$R/skills/demo-skill/SKILL.md" "$R/omp/agent/skills/demo-skill/SKILL.md" >/dev/null \
  || fail "(3) skill not copied verbatim"
diff -q "$R/commands/do-thing.md" "$R/omp/agent/commands/do-thing.md" >/dev/null \
  || fail "(3) command not copied verbatim"

# ============================================================ (4) hooks
TS="$R/omp/agent/hooks/pre/claude-compat.ts"
[ -f "$TS" ] || fail "(4) claude-compat.ts not emitted"
grep -q 'export default function' "$TS" || fail "(4) adapter missing default export"
[ -f "$R/omp/agent/hooks/scripts/echoer.sh" ] || fail "(4) hook script not copied"
[ -f "$R/omp/agent/hooks/scripts/echoer.test.sh" ] && fail "(4) *.test.sh must not deploy"
# The adapter deploys at user/global scope, so it must mirror the GLOBAL
# settings.json hook set. pr-merge-sync-reminder.sh is project-scoped only
# (hooks/settings.json, Bash(gh *)) and must NOT be wired — a global wiring
# would fire an invalid sync prompt after squash merges in unrelated repos.
grep -q 'runScript("pr-merge-sync-reminder' "$TS" \
  && fail "(4) project-scoped pr-merge-sync-reminder must not be invoked by the global adapter"
# Positive controls: global-scope hooks stay wired (match the invocation, not
# the doc comments, which mention several script names).
grep -q 'runScript("enforce-git-conventions' "$TS" || fail "(4) enforce-git-conventions not wired"
grep -q '"auto-test-runner.sh"' "$TS" || fail "(4) auto-test-runner not wired"

# ============================================================ (5) idempotent
OUT="$(run "$R" --apply 2>&1)"
echo "$OUT" | grep -q "Already in sync" || fail "(5) second --apply not idempotent: $OUT"

# ============================================================ (6) dry run writes nothing
R2="$(setup_repo)"
run "$R2" >/dev/null 2>&1 || fail "(6) dry run exited nonzero"
[ -e "$R2/omp" ] && fail "(6) dry run created target files"

# ============================================================ (7) backup on overwrite
echo "tampered" > "$AG"
OUT="$(run "$R" --apply 2>&1)"
echo "$OUT" | grep -q "Backup (full snapshot" || fail "(7) no backup snapshot reported on overwrite"
BK="$(ls -d "$R"/omp/backups/*/agent/agents 2>/dev/null | head -1)"
[ -n "$BK" ] || fail "(7) no directory snapshot created"
grep -q tampered "$BK/checker.md" || fail "(7) overwritten file's pre-apply content missing from snapshot"
[ -f "$BK/boss.md" ] || fail "(7) snapshot is not a full-directory copy (unchanged sibling boss.md absent)"

# ============================================================ (8) --no-hooks
R3="$(setup_repo)"
run "$R3" --apply --no-hooks >/dev/null 2>&1 || fail "(8) --no-hooks exited nonzero"
[ -e "$R3/omp/agent/hooks" ] && fail "(8) --no-hooks still deployed hooks"
[ -f "$R3/omp/agent/agents/checker.md" ] || fail "(8) --no-hooks skipped agents too"

# ============================================================ (9) --map-models
R4="$(setup_repo)"
run "$R4" --apply --map-models >/dev/null 2>&1 || fail "(9) --map-models exited nonzero"
grep -q '^model: "@good"$' "$R4/omp/agent/agents/checker.md" \
  || fail "(9) opus not mapped to quoted @good (unquoted @ is invalid YAML): $(grep '^model:' "$R4/omp/agent/agents/checker.md")"
grep -q '^model:' "$R4/omp/agent/agents/boss.md" \
  && fail "(9) sonnet should stay inherited (no model line)"

# ============================================================ (10) bad arg
if run "$R" --bogus >/dev/null 2>&1; then
  fail "(10) unknown arg did not exit nonzero"
fi

# ============================================================ (11) jq gating
# The converter never calls jq; only the deployed hook scripts need it. So a
# --no-hooks sync must work without jq, while a hooks sync must fail fast when
# jq is absent. Build a PATH mirroring the real one MINUS jq; skip if jq can't
# be hidden (e.g. shadowed by a builtin).
NOJQ_BIN="$SUITE_TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
_oldifs="$IFS"; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for exe in "$d"/*; do
    b="${exe##*/}"
    [ "$b" = "jq" ] && continue
    [ -e "$NOJQ_BIN/$b" ] || ln -s "$exe" "$NOJQ_BIN/$b" 2>/dev/null || true
  done
done
IFS="$_oldifs"
if command -v jq >/dev/null 2>&1 && ! PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
  R5="$(setup_repo)"
  PATH="$NOJQ_BIN" OMP_HOME="$R5/omp" bash "$R5/scripts/sync-omp-config.sh" --apply --no-hooks >/dev/null 2>&1 \
    || fail "(11) --no-hooks sync must succeed without jq"
  [ -f "$R5/omp/agent/agents/checker.md" ] || fail "(11) --no-hooks --apply without jq did not deploy agents"
  # A dry run previews only — it must succeed without jq even with hooks on.
  R5b="$(setup_repo)"
  PATH="$NOJQ_BIN" OMP_HOME="$R5b/omp" bash "$R5b/scripts/sync-omp-config.sh" >/dev/null 2>&1 \
    || fail "(11) hooks dry run must succeed without jq"
  [ -e "$R5b/omp" ] && fail "(11) dry run without jq wrote files"
  R6="$(setup_repo)"
  if PATH="$NOJQ_BIN" OMP_HOME="$R6/omp" bash "$R6/scripts/sync-omp-config.sh" --apply >/dev/null 2>&1; then
    fail "(11) hooks sync without jq must fail (jq needed for the deployed hook scripts)"
  fi
fi

# ============================================================ (12) unique backup path
# Two applies in the SAME UTC second must not share a backup dir, else the
# second run's per-category existence check mistakes the first run's snapshot
# for its own and skips a needed backup. A `date` shim forces the collision;
# the per-process suffix must still separate the two runs.
DSHIM="$SUITE_TMP/date-shim-bin"; mkdir -p "$DSHIM"
_oldifs="$IFS"; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for exe in "$d"/*; do
    b="${exe##*/}"
    [ "$b" = "date" ] && continue
    [ -e "$DSHIM/$b" ] || ln -s "$exe" "$DSHIM/$b" 2>/dev/null || true
  done
done
IFS="$_oldifs"
printf '#!/bin/bash\necho FIXEDSTAMP\n' > "$DSHIM/date"; chmod +x "$DSHIM/date"
if [ "$(PATH="$DSHIM" date -u +%Y 2>/dev/null)" = "FIXEDSTAMP" ]; then
  R7="$(setup_repo)"
  PATH="$DSHIM" OMP_HOME="$R7/omp" bash "$R7/scripts/sync-omp-config.sh" --apply >/dev/null 2>&1 || fail "(12) first apply failed"
  echo tamperedA > "$R7/omp/agent/agents/checker.md"
  PATH="$DSHIM" OMP_HOME="$R7/omp" bash "$R7/scripts/sync-omp-config.sh" --apply >/dev/null 2>&1 || fail "(12) second apply failed"
  echo tamperedB > "$R7/omp/agent/agents/checker.md"
  PATH="$DSHIM" OMP_HOME="$R7/omp" bash "$R7/scripts/sync-omp-config.sh" --apply >/dev/null 2>&1 || fail "(12) third apply failed"
  NDIRS=$(ls -d "$R7"/omp/backups/*/ 2>/dev/null | grep -c . || true)
  [ "$NDIRS" -ge 2 ] || fail "(12) same-second applies collided into one backup dir (got $NDIRS)"
  grep -rhq tamperedA "$R7"/omp/backups/*/agent/agents/checker.md 2>/dev/null || fail "(12) first overwrite's pre-apply content missing from backups"
  grep -rhq tamperedB "$R7"/omp/backups/*/agent/agents/checker.md 2>/dev/null || fail "(12) second overwrite's pre-apply content missing (collided backup)"
fi

# ============================================================ (13) file/dir conflict
# A live directory where a staged file belongs must be replaced by the file,
# not have the file nested inside it (checker.md/checker.md). Otherwise the
# apply "succeeds" but omp can't find the agent and every later sync re-reports.
R8="$(setup_repo)"
run "$R8" --apply >/dev/null 2>&1 || fail "(13) initial apply failed"
rm -f "$R8/omp/agent/agents/checker.md"
mkdir -p "$R8/omp/agent/agents/checker.md"
echo stale > "$R8/omp/agent/agents/checker.md/nested"
run "$R8" --apply >/dev/null 2>&1 || fail "(13) apply over a dir conflict failed"
[ -f "$R8/omp/agent/agents/checker.md" ] || fail "(13) staged file not deployed as a regular file over a conflicting dir"
grep -q '^BODY-CHECKER$' "$R8/omp/agent/agents/checker.md" || fail "(13) deployed checker.md content wrong after conflict"
CONFLICT_OUT="$(run "$R8" 2>&1)"
echo "$CONFLICT_OUT" | grep -q "Already in sync" || fail "(13) conflict not resolved — still reporting changes: $CONFLICT_OUT"

# ============================================================ (14) destination symlink
# A live symlink where a staged file belongs must be replaced by a real file,
# and cp must NOT follow it and overwrite the external referent.
R9="$(setup_repo)"
run "$R9" --apply >/dev/null 2>&1 || fail "(14) initial apply failed"
EXT="$SUITE_TMP/ext-target-omp.txt"; echo "EXTERNAL-UNTOUCHED" > "$EXT"
rm -f "$R9/omp/agent/agents/checker.md"
ln -s "$EXT" "$R9/omp/agent/agents/checker.md"
run "$R9" --apply >/dev/null 2>&1 || fail "(14) apply over a symlink failed"
[ -L "$R9/omp/agent/agents/checker.md" ] && fail "(14) destination left as a symlink"
[ -f "$R9/omp/agent/agents/checker.md" ] || fail "(14) staged file not deployed as a regular file over a symlink"
grep -q '^BODY-CHECKER$' "$R9/omp/agent/agents/checker.md" || fail "(14) deployed content wrong after symlink"
[ "$(cat "$EXT")" = "EXTERNAL-UNTOUCHED" ] || fail "(14) cp followed the symlink and overwrote the external target"
SYM_OUT="$(run "$R9" 2>&1)"
echo "$SYM_OUT" | grep -q "Already in sync" || fail "(14) symlink conflict not resolved: $SYM_OUT"

# ============================================================ (15) symlinked root
# A live category dir that is itself a symlink must be replaced by a real dir;
# the overlay must write into the intended location, not the external referent,
# which stays untouched, and the link must be recorded in the backup.
R10="$(setup_repo)"
run "$R10" --apply >/dev/null 2>&1 || fail "(15) initial apply failed"
EXTDIR="$SUITE_TMP/ext-agents-dir"; mkdir -p "$EXTDIR"; echo "EXTERNAL-FILE" > "$EXTDIR/outsider.md"
rm -rf "$R10/omp/agent/agents"
ln -s "$EXTDIR" "$R10/omp/agent/agents"
run "$R10" --apply >/dev/null 2>&1 || fail "(15) apply over a symlinked root failed"
[ -L "$R10/omp/agent/agents" ] && fail "(15) category root left as a symlink"
[ -d "$R10/omp/agent/agents" ] || fail "(15) category root not a real directory after apply"
[ -f "$R10/omp/agent/agents/checker.md" ] || fail "(15) staged file not deployed into the real root"
[ -f "$EXTDIR/outsider.md" ] || fail "(15) external referent file removed"
[ -e "$R10/omp/agent/agents/outsider.md" ] && fail "(15) overlay wrote into the external referent"
ROOTLINK_BK=$(find "$R10"/omp/backups -path "*/agent/agents" -type l 2>/dev/null | head -1)
[ -n "$ROOTLINK_BK" ] || fail "(15) symlinked root not recorded in backup"
SROOT_OUT="$(run "$R10" 2>&1)"
echo "$SROOT_OUT" | grep -q "Already in sync" || fail "(15) symlinked root not resolved: $SROOT_OUT"

# ============================================================ (16) nested symlink ancestor
# A symlink at a nested path component (a skill dir) must be replaced by a real
# dir; the overlay must write the staged file into it, not through the link
# into the external referent, which stays untouched.
R11="$(setup_repo)"
run "$R11" --apply >/dev/null 2>&1 || fail "(16) initial apply failed"
EXTSK="$SUITE_TMP/ext-skill-dir"; mkdir -p "$EXTSK"; echo "EXTERNAL-SKILL" > "$EXTSK/SKILL.md"
rm -rf "$R11/omp/agent/skills/demo-skill"
ln -s "$EXTSK" "$R11/omp/agent/skills/demo-skill"
run "$R11" --apply >/dev/null 2>&1 || fail "(16) apply over a symlinked nested dir failed"
[ -L "$R11/omp/agent/skills/demo-skill" ] && fail "(16) nested dir left as a symlink"
[ -d "$R11/omp/agent/skills/demo-skill" ] || fail "(16) nested dir not a real directory after apply"
diff -q "$R11/skills/demo-skill/SKILL.md" "$R11/omp/agent/skills/demo-skill/SKILL.md" >/dev/null || fail "(16) SKILL.md not deployed into the real nested dir"
[ "$(cat "$EXTSK/SKILL.md")" = "EXTERNAL-SKILL" ] || fail "(16) overlay wrote through the link and overwrote the external SKILL.md"
NEST_OUT="$(run "$R11" 2>&1)"
echo "$NEST_OUT" | grep -q "Already in sync" || fail "(16) nested symlink not resolved: $NEST_OUT"

# ============================================================ (17) extension deploy
R12="$(setup_repo)"
run "$R12" --apply >/dev/null 2>&1 || fail "(17) apply failed"
EXT="$R12/omp/agent/extensions/caveman"
[ -f "$EXT/package.json" ] || fail "(17) extension package.json not deployed"
grep -q '"omp"' "$EXT/package.json" || fail "(17) omp manifest key missing from deployed package.json"
diff -q "$R12/omp-extensions/caveman/src/index.ts" "$EXT/src/index.ts" >/dev/null \
  || fail "(17) extension src/index.ts not deployed verbatim"

# ============================================================ (18) settings seeded when absent
[ -f "$R12/omp/agent/caveman.json" ] || fail "(18) caveman.json not seeded on first apply"
grep -q '"defaultLevel": "full"' "$R12/omp/agent/caveman.json" || fail "(18) seeded settings content wrong"

# ============================================================ (19) seed never clobbers a chosen level
printf '{"defaultLevel":"ultra","showStatus":false}\n' > "$R12/omp/agent/caveman.json"
SEED_OUT="$(run "$R12" --apply 2>&1)"
echo "$SEED_OUT" | grep -q "Already in sync" || fail "(19) re-apply not idempotent with extensions: $SEED_OUT"
grep -q '"defaultLevel":"ultra"' "$R12/omp/agent/caveman.json" || fail "(19) seed clobbered an existing user settings file"

# ============================================================ (20) --no-extensions
R13="$(setup_repo)"
run "$R13" --apply --no-extensions >/dev/null 2>&1 || fail "(20) --no-extensions exited nonzero"
[ -e "$R13/omp/agent/extensions" ] && fail "(20) --no-extensions still deployed extensions"
[ -e "$R13/omp/agent/caveman.json" ] && fail "(20) --no-extensions still seeded settings"
[ -f "$R13/omp/agent/agents/checker.md" ] || fail "(20) --no-extensions skipped agents too"

# ====================================================== (21) apply refreshes prompt
# When update-caveman-prompt.sh is present, --apply must invoke it first. A stub
# records the call (and touches no network) so the wiring is tested offline.
R14="$(setup_repo)"
cat > "$R14/scripts/update-caveman-prompt.sh" <<EOF
#!/bin/bash
echo ran > "$R14/updater-ran"
EOF
chmod +x "$R14/scripts/update-caveman-prompt.sh"
run "$R14" --apply >/dev/null 2>&1 || fail "(21) apply with updater present failed"
[ -f "$R14/updater-ran" ] || fail "(21) sync did not invoke update-caveman-prompt.sh on --apply"

# ====================================================== (22) --no-update suppresses refresh
R15="$(setup_repo)"
cat > "$R15/scripts/update-caveman-prompt.sh" <<EOF
#!/bin/bash
echo ran > "$R15/updater-ran"
EOF
chmod +x "$R15/scripts/update-caveman-prompt.sh"
run "$R15" --apply --no-update >/dev/null 2>&1 || fail "(22) --no-update apply failed"
[ -f "$R15/updater-ran" ] && fail "(22) --no-update still invoked the updater"

# ====================================================== (23) dry run never refreshes
R16="$(setup_repo)"
cat > "$R16/scripts/update-caveman-prompt.sh" <<EOF
#!/bin/bash
echo ran > "$R16/updater-ran"
EOF
chmod +x "$R16/scripts/update-caveman-prompt.sh"
run "$R16" >/dev/null 2>&1 || fail "(23) dry run failed"
[ -f "$R16/updater-ran" ] && fail "(23) dry run invoked the updater (must be apply-only)"

# ====================================================== (24) refresh failure is non-fatal
R17="$(setup_repo)"
cat > "$R17/scripts/update-caveman-prompt.sh" <<'EOF'
#!/bin/bash
echo "boom" >&2
exit 4
EOF
chmod +x "$R17/scripts/update-caveman-prompt.sh"
run "$R17" --apply >/dev/null 2>&1 || fail "(24) a failing updater must not abort the sync"
[ -f "$R17/omp/agent/extensions/caveman/package.json" ] || fail "(24) extension not deployed after non-fatal updater failure"

echo "PASS: sync-omp-config.test.sh (24 cases)"
