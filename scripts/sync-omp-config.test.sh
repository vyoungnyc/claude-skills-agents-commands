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
  R6="$(setup_repo)"
  if PATH="$NOJQ_BIN" OMP_HOME="$R6/omp" bash "$R6/scripts/sync-omp-config.sh" --apply >/dev/null 2>&1; then
    fail "(11) hooks sync without jq must fail (jq needed for the deployed hook scripts)"
  fi
fi

echo "PASS: sync-omp-config.test.sh (11 cases)"
