#!/bin/bash
# Self-contained test suite for scripts/sync-claude-config.sh.
# Style follows scripts/create-local-issues.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_* wrappers,
# flat top-level assertion calls, no test framework.
#
# HARD ISOLATION: the script under test resolves REPO_ROOT from its own file
# location and writes only under CLAUDE_HOME. Every invocation here copies
# the script into a throwaway fake repo (its own mktemp -d tree) and always
# passes an explicit CLAUDE_HOME pointed at a second throwaway tree — the
# real $HOME/.claude is never read from or written to by this suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR/sync-claude-config.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

EXERCISED_EXIT_CODES=""
record_exit() {
  case " $EXERCISED_EXIT_CODES " in
    *" $1 "*) ;;
    *) EXERCISED_EXIT_CODES="$EXERCISED_EXIT_CODES $1" ;;
  esac
}

# fake_repo — a throwaway repo root with a copy of the real script plus
# minimal agents/skills/commands/rules/hooks/CLAUDE.md/settings.json fixtures.
fake_repo() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/repo.XXXXXX")
  mkdir -p "$dir/scripts" "$dir/agents" "$dir/skills" "$dir/commands" "$dir/rules" "$dir/hooks" "$dir/statusline"
  cp "$REAL_SCRIPT" "$dir/scripts/sync-claude-config.sh"
  chmod +x "$dir/scripts/sync-claude-config.sh"
  echo "agent content" > "$dir/agents/example.md"
  echo "skill content" > "$dir/skills/example.md"
  echo "command content" > "$dir/commands/example.md"
  echo "rule content" > "$dir/rules/example.md"
  printf '#!/bin/bash\necho hi\n' > "$dir/hooks/example.sh"
  printf '#!/bin/bash\necho hook test\n' > "$dir/hooks/example.test.sh"
  printf '#!/bin/bash\necho statusline\n' > "$dir/statusline/statusline-example.sh"
  printf '#!/bin/bash\necho statusline test\n' > "$dir/statusline/statusline-example.test.sh"
  echo "# CLAUDE.md repo version" > "$dir/CLAUDE.md"
  cat > "$dir/settings.json" <<'EOF'
{
  "env": {"REPO_FLAG": "1"},
  "statusLine": {"type": "command", "command": "repo-statusline.sh"},
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "repo-hook.sh"}]}
    ]
  }
}
EOF
  printf '%s' "$dir"
}

# fake_home — an empty throwaway CLAUDE_HOME.
fake_home() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  printf '%s' "$dir"
}

# run_sync <repo_dir> <home_dir> [args...] — captures stdout/stderr/exit into
# LAST_STDOUT/LAST_STDERR/LAST_EXIT.
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT=0
run_sync() {
  local repo="$1"; shift
  local home="$1"; shift
  local out="$SUITE_TMP/last_stdout"
  local err="$SUITE_TMP/last_stderr"
  set +e
  CLAUDE_HOME="$home" bash "$repo/scripts/sync-claude-config.sh" "$@" >"$out" 2>"$err"
  LAST_EXIT=$?
  set -e
  LAST_STDOUT=$(cat "$out")
  LAST_STDERR=$(cat "$err")
}

expect_exit() {
  local expected="$1"; shift
  run_sync "$@"
  [ "$LAST_EXIT" -eq "$expected" ] || fail "expected exit $expected, got $LAST_EXIT; stderr: $LAST_STDERR"
  record_exit "$expected"
}

expect_stdout_match() {
  local pattern="$1"
  echo "$LAST_STDOUT" | grep -Eq "$pattern" || fail "stdout did not match /$pattern/: $LAST_STDOUT"
}

expect_stdout_not_match() {
  local pattern="$1"
  echo "$LAST_STDOUT" | grep -Eq "$pattern" && fail "stdout unexpectedly matched /$pattern/: $LAST_STDOUT"
  return 0
}

# =======================================================================
# --help: exit 0, usage text, no filesystem changes.
# =======================================================================
HELP_HOME=$(fake_home)
expect_exit 0 "$(fake_repo)" "$HELP_HOME" --help
expect_stdout_match "Usage:"
[ -z "$(ls -A "$HELP_HOME")" ] || fail "--help must not touch CLAUDE_HOME"

# =======================================================================
# Unknown argument: exit 10, no filesystem changes.
# =======================================================================
BADARG_HOME=$(fake_home)
expect_exit 10 "$(fake_repo)" "$BADARG_HOME" --bogus
[ -z "$(ls -A "$BADARG_HOME")" ] || fail "unknown-argument path must not touch CLAUDE_HOME"

# =======================================================================
# Dry run against an already-synced CLAUDE_HOME: reports nothing to do,
# writes nothing (no backups/ dir created).
# =======================================================================
SYNCED_REPO=$(fake_repo)
SYNCED_HOME=$(fake_home)
mkdir -p "$SYNCED_HOME/agents" "$SYNCED_HOME/skills" "$SYNCED_HOME/commands" "$SYNCED_HOME/rules" "$SYNCED_HOME/hooks"
cp "$SYNCED_REPO/agents/example.md" "$SYNCED_HOME/agents/example.md"
cp "$SYNCED_REPO/skills/example.md" "$SYNCED_HOME/skills/example.md"
cp "$SYNCED_REPO/commands/example.md" "$SYNCED_HOME/commands/example.md"
cp "$SYNCED_REPO/rules/example.md" "$SYNCED_HOME/rules/example.md"
cp "$SYNCED_REPO/hooks/example.sh" "$SYNCED_HOME/hooks/example.sh"
cp "$SYNCED_REPO/statusline/statusline-example.sh" "$SYNCED_HOME/statusline-example.sh"
cp "$SYNCED_REPO/CLAUDE.md" "$SYNCED_HOME/CLAUDE.md"
cat > "$SYNCED_HOME/settings.json" <<'EOF'
{
  "env": {"REPO_FLAG": "1"},
  "statusLine": {"type": "command", "command": "repo-statusline.sh"},
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "repo-hook.sh"}]}
    ]
  }
}
EOF

expect_exit 0 "$SYNCED_REPO" "$SYNCED_HOME"
expect_stdout_match "Already in sync"
[ ! -d "$SYNCED_HOME/backups" ] || fail "no-op dry run must not create a backups/ dir"

# =======================================================================
# Dry run against an empty CLAUDE_HOME: reports every planned change,
# writes nothing at all (true dry run).
# =======================================================================
DRY_REPO=$(fake_repo)
DRY_HOME=$(fake_home)
expect_exit 0 "$DRY_REPO" "$DRY_HOME"
expect_stdout_match "Dry run"
expect_stdout_match "agents/"
expect_stdout_match "statusline-example.sh"
expect_stdout_match "CLAUDE.md"
expect_stdout_match "settings.json"
expect_stdout_match "Re-run with --apply"
expect_stdout_not_match "example\.test\.sh"
expect_stdout_not_match "statusline-example\.test\.sh"
[ -z "$(ls -A "$DRY_HOME")" ] || fail "dry run must not write any file under CLAUDE_HOME"

# =======================================================================
# --apply against an empty CLAUDE_HOME: copies every directory, hook
# script, CLAUDE.md, and creates settings.json from the repo (no live file
# existed, so nothing to back up).
# =======================================================================
APPLY_REPO=$(fake_repo)
APPLY_HOME=$(fake_home)
expect_exit 0 "$APPLY_REPO" "$APPLY_HOME" --apply
expect_stdout_match "Applied:"

[ "$(cat "$APPLY_HOME/agents/example.md")" = "agent content" ] || fail "agents/ not copied"
[ "$(cat "$APPLY_HOME/CLAUDE.md")" = "# CLAUDE.md repo version" ] || fail "CLAUDE.md not copied"
[ -x "$APPLY_HOME/hooks/example.sh" ] || fail "synced hook script must be executable"
[ -x "$APPLY_HOME/statusline-example.sh" ] || fail "synced statusline script must be executable"
[ "$(cat "$APPLY_HOME/statusline-example.sh")" = "$(cat "$APPLY_REPO/statusline/statusline-example.sh")" ] \
  || fail "statusline script content mismatch after flat copy"
[ ! -f "$APPLY_HOME/statusline/statusline-example.sh" ] || fail "statusline script must land flat in CLAUDE_HOME, not under a statusline/ subdirectory"
[ ! -f "$APPLY_HOME/hooks/example.test.sh" ] || fail "hooks/*.test.sh must never be deployed to a live CLAUDE_HOME"
[ ! -f "$APPLY_HOME/statusline-example.test.sh" ] || fail "statusline/*.test.sh must never be deployed to a live CLAUDE_HOME"
[ ! -d "$APPLY_HOME/backups" ] || fail "first-ever apply with no live files must not create a backup"

jq -e '.hooks.UserPromptSubmit' "$APPLY_HOME/settings.json" >/dev/null \
  || fail "settings.json not created with repo hooks"
jq -e '.statusLine.command == "repo-statusline.sh"' "$APPLY_HOME/settings.json" >/dev/null \
  || fail "settings.json not created with repo statusLine"

# =======================================================================
# --apply overlay-copy: a live-only file not present in the repo survives
# the sync untouched (directories are overlaid, never wiped).
# =======================================================================
OVERLAY_REPO=$(fake_repo)
OVERLAY_HOME=$(fake_home)
mkdir -p "$OVERLAY_HOME/agents"
echo "live-only, not in repo" > "$OVERLAY_HOME/agents/live-only.md"
expect_exit 0 "$OVERLAY_REPO" "$OVERLAY_HOME" --apply
[ -f "$OVERLAY_HOME/agents/live-only.md" ] || fail "overlay copy must not delete a live-only file"
[ "$(cat "$OVERLAY_HOME/agents/live-only.md")" = "live-only, not in repo" ] || fail "live-only file content changed"
[ -f "$OVERLAY_HOME/agents/example.md" ] || fail "repo file missing after overlay copy"

# --apply where a live file already exists and differs, in each of the three
# copy styles (overlay dir, hooks/*.sh flat, statusline/*.sh flat): the old
# content is backed up byte-for-byte before being overwritten. Supersedes an
# earlier agents+hooks-only version of this test (main's 671b3c9) — this one
# additionally covers statusline/*.sh.
# =======================================================================
# --apply where a live file already exists and differs, in each of the three
# copy styles (overlay dir, hooks/*.sh flat, statusline/*.sh flat into
# $CLAUDE_HOME root): the old content is backed up byte-for-byte before being
# overwritten. Also covers whole-directory snapshotting and symlink
# preservation for the hooks dir.
# =======================================================================
COLLIDE_REPO=$(fake_repo)
COLLIDE_HOME=$(fake_home)
mkdir -p "$COLLIDE_HOME/agents" "$COLLIDE_HOME/hooks"
echo "live agent content, pre-sync" > "$COLLIDE_HOME/agents/example.md"
printf '#!/bin/bash\necho live-pre-sync\n' > "$COLLIDE_HOME/hooks/example.sh"
printf '#!/bin/bash\necho keep\n' > "$COLLIDE_HOME/hooks/keep.sh"  # live-only, not in repo
ln -s example.sh "$COLLIDE_HOME/hooks/linked.sh"  # live-only symlink hook
echo "live-statusline-presync" > "$COLLIDE_HOME/statusline-example.sh"  # flat-copied style
expect_exit 0 "$COLLIDE_REPO" "$COLLIDE_HOME" --apply

[ "$(cat "$COLLIDE_HOME/agents/example.md")" = "agent content" ] || fail "colliding agents/ file not overwritten with repo version"
[ "$(cat "$COLLIDE_HOME/hooks/example.sh")" = "#!/bin/bash
echo hi" ] || fail "colliding hooks/ file not overwritten with repo version"

COLLIDE_AGENT_BACKUP=$(find "$COLLIDE_HOME/backups" -path "*/agents/example.md" 2>/dev/null | head -1 || true)
[ -n "$COLLIDE_AGENT_BACKUP" ] || fail "expected a backup of the overwritten agents/example.md"
[ "$(cat "$COLLIDE_AGENT_BACKUP")" = "live agent content, pre-sync" ] || fail "backed-up agents/example.md does not match pre-sync content"

COLLIDE_HOOK_BACKUP=$(find "$COLLIDE_HOME/backups" -path "*/hooks/example.sh" 2>/dev/null | head -1 || true)
[ -n "$COLLIDE_HOOK_BACKUP" ] || fail "expected a backup of the overwritten hooks/example.sh"
[ "$(cat "$COLLIDE_HOOK_BACKUP")" = "#!/bin/bash
echo live-pre-sync" ] || fail "backed-up hooks/example.sh does not match pre-sync content"

# Whole-directory snapshot: the live-only hook (never in the repo) is captured
# in the hooks backup too, and survives in place after the overlay.
COLLIDE_HOOK_LIVEONLY=$(find "$COLLIDE_HOME/backups" -path "*/hooks/keep.sh" 2>/dev/null | head -1 || true)
[ -n "$COLLIDE_HOOK_LIVEONLY" ] || fail "hooks backup is not a whole-directory snapshot (live-only keep.sh missing)"
[ -f "$COLLIDE_HOME/hooks/keep.sh" ] || fail "overlay must not delete a live-only hook"

# Symlink preservation: a live symlinked hook must be backed up AS a symlink
# (cp -R, not -r, which follows links on BSD), so a restore recreates the link
# rather than a dereferenced regular file.
COLLIDE_HOOK_LINK=$(find "$COLLIDE_HOME/backups" -path "*/hooks/linked.sh" 2>/dev/null | head -1 || true)
[ -L "$COLLIDE_HOOK_LINK" ] || fail "hooks backup dereferenced a symlink instead of preserving it"
[ "$(readlink "$COLLIDE_HOOK_LINK")" = "example.sh" ] || fail "backed-up symlink target changed"

# statusline/*.sh land flat in $CLAUDE_HOME's root, so they are backed up per
# file rather than as a directory snapshot.
[ "$(cat "$COLLIDE_HOME/statusline-example.sh")" = "$(cat "$COLLIDE_REPO/statusline/statusline-example.sh")" ] \
  || fail "colliding statusline script not overwritten with repo version"
COLLIDE_SL_BACKUP=$(find "$COLLIDE_HOME/backups" -name "statusline-example.sh" 2>/dev/null | head -1 || true)
[ -n "$COLLIDE_SL_BACKUP" ] || fail "expected a backup of the overwritten statusline-example.sh"
[ "$(cat "$COLLIDE_SL_BACKUP")" = "live-statusline-presync" ] \
  || fail "backed-up statusline-example.sh does not match pre-sync content"

# =======================================================================
# --apply where a destination is a symlink to an external file: the sync
# replaces the link with a real file and never follows it to overwrite the
# external target — both the dir bulk copy and the hooks per-file copy.
# =======================================================================
SYM_REPO=$(fake_repo)
SYM_HOME=$(fake_home)
mkdir -p "$SYM_HOME/agents" "$SYM_HOME/hooks"
EXT_A="$SUITE_TMP/ext-agent.txt"; echo "EXT-AGENT-KEEP" > "$EXT_A"
EXT_H="$SUITE_TMP/ext-hook.txt"; printf '#!/bin/bash\necho ext-hook-keep\n' > "$EXT_H"
ln -s "$EXT_A" "$SYM_HOME/agents/example.md"   # dst symlink where a repo file belongs
ln -s "$EXT_H" "$SYM_HOME/hooks/example.sh"
expect_exit 0 "$SYM_REPO" "$SYM_HOME" --apply
[ -L "$SYM_HOME/agents/example.md" ] && fail "agents dst left as a symlink after apply"
[ "$(cat "$SYM_HOME/agents/example.md")" = "agent content" ] || fail "agents symlink not replaced with the repo file"
[ "$(cat "$EXT_A")" = "EXT-AGENT-KEEP" ] || fail "dir copy followed a symlink and overwrote the external agent target"
[ -L "$SYM_HOME/hooks/example.sh" ] && fail "hooks dst left as a symlink after apply"
[ "$(cat "$SYM_HOME/hooks/example.sh")" = "#!/bin/bash
echo hi" ] || fail "hooks symlink not replaced with the repo file"
[ "$(cat "$EXT_H")" = "#!/bin/bash
echo ext-hook-keep" ] || fail "hooks copy followed a symlink and overwrote the external hook target"

# =======================================================================
# --apply where a category root itself is a symlink to an external dir: the
# sync records the link, replaces the root with a real directory, deploys the
# repo contents there, and leaves the external referent untouched.
# =======================================================================
ROOTSYM_REPO=$(fake_repo)
ROOTSYM_HOME=$(fake_home)
mkdir -p "$ROOTSYM_HOME"
EXT_ROOT="$SUITE_TMP/ext-agents-root"; mkdir -p "$EXT_ROOT"; echo "EXTERNAL-ROOT-AGENT" > "$EXT_ROOT/outsider.md"
ln -s "$EXT_ROOT" "$ROOTSYM_HOME/agents"
expect_exit 0 "$ROOTSYM_REPO" "$ROOTSYM_HOME" --apply
[ -L "$ROOTSYM_HOME/agents" ] && fail "category root left as a symlink after apply"
[ -d "$ROOTSYM_HOME/agents" ] || fail "category root not a real directory after apply"
[ "$(cat "$ROOTSYM_HOME/agents/example.md")" = "agent content" ] || fail "repo file not deployed into the real root"
[ -f "$EXT_ROOT/outsider.md" ] || fail "external referent file removed"
[ -e "$ROOTSYM_HOME/agents/outsider.md" ] && fail "overlay wrote into the external referent"
ROOTLINK=$(find "$ROOTSYM_HOME/backups" -name "agents.rootlink" 2>/dev/null | head -1 || true)
[ -n "$ROOTLINK" ] || fail "symlinked category root not recorded in backup"
[ -L "$ROOTLINK" ] || fail "recorded root backup is not a symlink"

# =======================================================================
# --apply on a differing CLAUDE.md: backs up the live version byte-for-byte
# before overwriting it with the repo version.
# =======================================================================
MD_REPO=$(fake_repo)
MD_HOME=$(fake_home)
mkdir -p "$MD_HOME"
echo "# live CLAUDE.md, pre-sync" > "$MD_HOME/CLAUDE.md"
expect_exit 0 "$MD_REPO" "$MD_HOME" --apply
[ "$(cat "$MD_HOME/CLAUDE.md")" = "# CLAUDE.md repo version" ] || fail "CLAUDE.md not overwritten with repo version"
BACKUP_MD=$(find "$MD_HOME/backups" -name "CLAUDE.md" 2>/dev/null | head -1 || true)
[ -n "$BACKUP_MD" ] || fail "expected a CLAUDE.md backup under $MD_HOME/backups"
[ "$(cat "$BACKUP_MD")" = "# live CLAUDE.md, pre-sync" ] || fail "backed-up CLAUDE.md does not match pre-sync content"

# =======================================================================
# --apply on settings.json: merges the repo's hooks+env in, preserves every
# live-only top-level key untouched, and backs up the original file.
# =======================================================================
ST_REPO=$(fake_repo)
ST_HOME=$(fake_home)
mkdir -p "$ST_HOME"
cat > "$ST_HOME/settings.json" <<'EOF'
{
  "_comment": "live-only comment, must survive",
  "enabledPlugins": {"caveman@caveman": true},
  "effortLevel": "high",
  "env": {"LIVE_ONLY_FLAG": "1"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "live-only-hook.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$ST_REPO" "$ST_HOME" --apply

jq -e '._comment == "live-only comment, must survive"' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json merge dropped a live-only top-level key"
jq -e '.enabledPlugins["caveman@caveman"] == true' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json merge dropped live-only enabledPlugins"
jq -e '.hooks.PreToolUse[0].hooks[0].command == "live-only-hook.sh"' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json merge dropped a live-only hook event"
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command == "repo-hook.sh"' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json merge did not add the repo's hook event"
jq -e '.env.LIVE_ONLY_FLAG == "1" and .env.REPO_FLAG == "1"' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json env merge did not union live and repo keys"
jq -e '.statusLine.command == "repo-statusline.sh"' "$ST_HOME/settings.json" >/dev/null \
  || fail "settings.json merge did not add the repo's statusLine (live had none)"

ST_BACKUP=$(find "$ST_HOME/backups" -name "settings.json" 2>/dev/null | head -1 || true)
[ -n "$ST_BACKUP" ] || fail "expected a settings.json backup"
jq -e '.hooks.PreToolUse[0].hooks[0].command == "live-only-hook.sh" and (.hooks.UserPromptSubmit | not) and (.statusLine | not)' "$ST_BACKUP" >/dev/null \
  || fail "backed-up settings.json does not match pre-merge content"

# =======================================================================
# statusLine merge: a live-only statusLine survives untouched when the repo
# defines none (mirrors the overlay-dir "never delete a live-only file" rule).
# =======================================================================
NOSL_REPO=$(fake_repo)
jq 'del(.statusLine)' "$NOSL_REPO/settings.json" > "$NOSL_REPO/settings.json.tmp" && mv "$NOSL_REPO/settings.json.tmp" "$NOSL_REPO/settings.json"
NOSL_HOME=$(fake_home)
mkdir -p "$NOSL_HOME"
cat > "$NOSL_HOME/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "live-only-statusline.sh"},
  "hooks": {}
}
EOF
expect_exit 0 "$NOSL_REPO" "$NOSL_HOME" --apply
jq -e '.statusLine.command == "live-only-statusline.sh"' "$NOSL_HOME/settings.json" >/dev/null \
  || fail "settings.json merge dropped a live-only statusLine when the repo defines none"

# =======================================================================
# Idempotency: running --apply a second time makes no further change and
# does not duplicate the merged hook entry.
# =======================================================================
expect_exit 0 "$ST_REPO" "$ST_HOME" --apply
expect_stdout_match "Already in sync"
UPS_COUNT=$(jq '.hooks.UserPromptSubmit | length' "$ST_HOME/settings.json")
[ "$UPS_COUNT" -eq 1 ] || fail "second apply duplicated the merged hook entry (count=$UPS_COUNT)"

# =======================================================================
# Regression: a live event can bundle multiple hook commands into ONE
# group (e.g. hand-edited, or merged from two separate additions over
# time). If the repo defines one of those commands as its own single-
# command group, the merge must recognize the command is already present
# and skip re-adding it -- comparing whole `.hooks` arrays for equality
# (instead of individual commands) would treat the bundled live group as
# unrelated and append the repo's group anyway, duplicating that command's
# execution on every future sync.
# =======================================================================
BUNDLE_REPO=$(fake_repo)
cat > "$BUNDLE_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "usage-refresh.sh --force", "timeout": 5}]}
    ]
  }
}
EOF
BUNDLE_HOME=$(fake_home)
cat > "$BUNDLE_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [
        {"type": "command", "command": "local-only-hook.js"},
        {"type": "command", "command": "usage-refresh.sh --force"}
      ]}
    ]
  }
}
EOF
expect_exit 0 "$BUNDLE_REPO" "$BUNDLE_HOME" --apply
# Assert COMMAND multiplicity, not group count: the harm is a command running
# twice on every session start. The repo-owns-its-commands merge strips the repo
# command out of the bundled live group and re-adds the repo group, so the group
# count is legitimately 2 while each command still appears exactly once.
BUNDLE_DUP=$(jq '[.hooks.SessionStart[].hooks[].command] | group_by(.) | map(select(length > 1)) | length' "$BUNDLE_HOME/settings.json")
[ "$BUNDLE_DUP" -eq 0 ] || fail "a repo hook already bundled into a live group must not end up registered twice"
jq -e '[.hooks.SessionStart[].hooks[].command] | index("local-only-hook.js")' "$BUNDLE_HOME/settings.json" >/dev/null \
  || fail "the live-only hook bundled alongside it must survive"
# The repo command is re-added as its own group, so the previously-bundled live
# group is left holding just the live-only hook. What must hold is that the
# live-only command survives somewhere and the repo command is registered once
# (both asserted above), plus that the repo metadata actually got deployed --
# which the old structure could never do.
jq -e '[.hooks.SessionStart[].hooks[] | select(.command == "usage-refresh.sh --force") | .timeout] | .[0] == 5' "$BUNDLE_HOME/settings.json" >/dev/null \
  || fail "the repo hook metadata (timeout) should be deployed onto the bundled command"

expect_exit 0 "$BUNDLE_REPO" "$BUNDLE_HOME" --apply
expect_stdout_match "Already in sync"

# =======================================================================
# Regression: a PARTIAL overlap must add only the missing command, not the
# whole repo group. A repo group with commands [A, B] where live already has
# A (in some other group) but not B must end up with exactly one live copy
# of A and one new copy of B -- not a second A alongside the new B.
# =======================================================================
PARTIAL_REPO=$(fake_repo)
cat > "$PARTIAL_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [
        {"type": "command", "command": "shared-format.sh"},
        {"type": "command", "command": "new-only-in-repo.sh"}
      ]}
    ]
  }
}
EOF
PARTIAL_HOME=$(fake_home)
cat > "$PARTIAL_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "shared-format.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$PARTIAL_REPO" "$PARTIAL_HOME" --apply
PARTIAL_SHARED_COUNT=$(jq '[.hooks.PostToolUse[].hooks[] | select(.command == "shared-format.sh")] | length' "$PARTIAL_HOME/settings.json")
[ "$PARTIAL_SHARED_COUNT" -eq 1 ] || fail "a partially-overlapping repo group duplicated the already-present command (count=$PARTIAL_SHARED_COUNT)"
PARTIAL_NEW_COUNT=$(jq '[.hooks.PostToolUse[].hooks[] | select(.command == "new-only-in-repo.sh")] | length' "$PARTIAL_HOME/settings.json")
[ "$PARTIAL_NEW_COUNT" -eq 1 ] || fail "the missing command from a partially-overlapping repo group was not added (count=$PARTIAL_NEW_COUNT)"

# =======================================================================
# Regression: the SAME command under a DIFFERENT matcher is a different
# trigger, not a duplicate. Live already runs `shared.sh` under matcher
# "Edit"; the repo group runs the same command under matcher "Write" too --
# that must be added as its own group, not treated as already covered.
# =======================================================================
MATCHER_REPO=$(fake_repo)
cat > "$MATCHER_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "shared.sh"}]}
    ]
  }
}
EOF
MATCHER_HOME=$(fake_home)
cat > "$MATCHER_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "shared.sh"}]},
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "user-own-hook.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$MATCHER_REPO" "$MATCHER_HOME" --apply
# DELIBERATE BEHAVIOR CHOICE, changed from an earlier additive rule: the repo
# declares the complete trigger set for its own commands, so re-targeting
# shared.sh from Edit to Write MOVES it rather than accumulating both. There is
# no signal in a live settings.json that distinguishes "a stale group this repo
# deployed earlier" from "a trigger the user added by hand" -- both are just a
# group -- so a default has to be picked. Additive was the old default and it is
# what left enforce-git-conventions.sh registered twice (see the `if` test
# below); it also makes it impossible for the repo to ever remove or re-target
# one of its own hooks. Repo-authoritative matches how CLAUDE.md and statusLine
# already deploy, and the live file is backed up first.
jq -e '[.hooks.PostToolUse[] | select(.matcher == "Edit" and ((.hooks // [])[0].command == "shared.sh"))] | length == 0' "$MATCHER_HOME/settings.json" >/dev/null \
  || fail "re-targeting a repo command should move it, not leave the stale Edit-matcher group behind"
jq -e '[.hooks.PostToolUse[] | select(.matcher == "Write" and ((.hooks // [])[0].command == "shared.sh"))] | length == 1' "$MATCHER_HOME/settings.json" >/dev/null \
  || fail "shared.sh must be registered under the repo trigger (Write)"
[ "$(jq '[.hooks.PostToolUse[].hooks[]? | select(.command == "shared.sh")] | length' "$MATCHER_HOME/settings.json")" -eq 1 ] \
  || fail "shared.sh must be registered exactly once"
# A command the user wrote themselves (not shipped by the repo) is untouched.
jq -e '[.hooks.PostToolUse[].hooks[]? | select(.command == "user-own-hook.sh")] | length == 1' "$MATCHER_HOME/settings.json" >/dev/null \
  || fail "a live-only hook the repo does not ship must survive"

# =======================================================================
# Regression: the group-level `if` predicate is part of the trigger, so the
# same command+matcher under a DIFFERENT `if` is not a duplicate. This
# repo's own settings.json runs enforce-git-conventions.sh under
# matcher "Bash" AND if "Bash(git *)", so a (command, matcher)-only key
# would drop the repo hook and it would never run under its condition.
# =======================================================================
IF_REPO=$(fake_repo)
cat > "$IF_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "if": "Bash(git *)", "hooks": [{"type": "command", "command": "guard.sh"}]}
    ]
  }
}
EOF
IF_HOME=$(fake_home)
cat > "$IF_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "if": "Bash(rm *)", "hooks": [{"type": "command", "command": "guard.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$IF_REPO" "$IF_HOME" --apply
# Same repo-authoritative rule as the matcher case above: the repo declares the
# trigger set for guard.sh, so its `if` replaces the live one rather than both
# being kept. Keeping both is precisely what registered
# enforce-git-conventions.sh twice in a real config.
jq -e '[.hooks.PreToolUse[] | select(.if == "Bash(rm *)")] | length == 0' "$IF_HOME/settings.json" >/dev/null \
  || fail "the stale live predicate should be replaced, not kept alongside the repo one"
jq -e '[.hooks.PreToolUse[] | select(.if == "Bash(git *)" and ((.hooks // [])[0].command == "guard.sh"))] | length == 1' "$IF_HOME/settings.json" >/dev/null \
  || fail "guard.sh must be registered under the repo predicate"
[ "$(jq '[.hooks.PreToolUse[].hooks[]? | select(.command == "guard.sh")] | length' "$IF_HOME/settings.json")" -eq 1 ] \
  || fail "guard.sh must be registered exactly once"

# An identical group (same command, matcher AND if) is still deduped -- the
# richer key must not turn every re-sync into an append.
expect_exit 0 "$IF_REPO" "$IF_HOME" --apply
IF_GIT_COUNT=$(jq '[.hooks.PreToolUse[] | select(.if == "Bash(git *)")] | length' "$IF_HOME/settings.json")
[ "$IF_GIT_COUNT" -eq 1 ] || fail "re-syncing an already-present (command, matcher, if) group duplicated it (count=$IF_GIT_COUNT)"

# An explicit empty matcher and an absent matcher mean the same thing and
# must dedup against each other rather than reading as two triggers.
EMPTYM_REPO=$(fake_repo)
cat > "$EMPTYM_REPO/settings.json" <<'EOF'
{
  "hooks": {"UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "same.sh"}]}]}
}
EOF
EMPTYM_HOME=$(fake_home)
cat > "$EMPTYM_HOME/settings.json" <<'EOF'
{
  "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "same.sh"}]}]}
}
EOF
expect_exit 0 "$EMPTYM_REPO" "$EMPTYM_HOME" --apply
EMPTYM_COUNT=$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command == "same.sh")] | length' "$EMPTYM_HOME/settings.json")
[ "$EMPTYM_COUNT" -eq 1 ] || fail "an explicit empty matcher and an absent matcher must dedup as the same trigger (count=$EMPTYM_COUNT)"

# =======================================================================
# Regression: hook-level execution metadata must be deployable. Dedup keys
# on (command, trigger), which correctly prevents duplicate appends -- but
# it also silently blocked UPDATES: `type`/`async`/`timeout`/
# `statusMessage` are not part of the identity, so a live copy of a command
# lacking the repo's `async: true` would stay synchronous forever and the
# repo could never change those fields once the command existed live.
# (This repo's own auto-test-runner.sh really does carry async+timeout.)
# =======================================================================
META_REPO=$(fake_repo)
cat > "$META_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [
        {"type": "command", "command": "auto-test-runner.sh", "async": true, "timeout": 300, "statusMessage": "Running tests..."}
      ]}
    ]
  }
}
EOF
META_HOME=$(fake_home)
cat > "$META_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [
        {"type": "command", "command": "auto-test-runner.sh", "timeout": 30}
      ]}
    ]
  }
}
EOF
expect_exit 0 "$META_REPO" "$META_HOME" --apply
META_COUNT=$(jq '[.hooks.PostToolUse[].hooks[] | select(.command == "auto-test-runner.sh")] | length' "$META_HOME/settings.json")
[ "$META_COUNT" -eq 1 ] || fail "the hook should be updated in place, not duplicated (count=$META_COUNT)"
jq -e '.hooks.PostToolUse[0].hooks[0].async == true' "$META_HOME/settings.json" >/dev/null \
  || fail "the repo's async:true was never deployed -- dedup dropped the repo hook instead of updating the live one"
jq -e '.hooks.PostToolUse[0].hooks[0].timeout == 300' "$META_HOME/settings.json" >/dev/null \
  || fail "the repo's timeout should replace the live obsolete one, got: $(jq -r '.hooks.PostToolUse[0].hooks[0].timeout' "$META_HOME/settings.json")"
jq -e '.hooks.PostToolUse[0].hooks[0].statusMessage == "Running tests..."' "$META_HOME/settings.json" >/dev/null \
  || fail "the repo's statusMessage should be deployed"

# Updating a matching hook must not disturb the OTHER commands in a
# multi-command live group, nor that group's own metadata.
MULTIMETA_REPO=$(fake_repo)
cat > "$MULTIMETA_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "shared.sh", "async": true}]}
    ]
  }
}
EOF
MULTIMETA_HOME=$(fake_home)
cat > "$MULTIMETA_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks": [
        {"type": "command", "command": "my-local-hook.sh"},
        {"type": "command", "command": "shared.sh"}
      ]}
    ]
  }
}
EOF
expect_exit 0 "$MULTIMETA_REPO" "$MULTIMETA_HOME" --apply
# Assert by command, not by index: the repo command is re-added as its own group,
# so positions shift. What matters is that each command appears once, the repo
# one carries the repo metadata, and the live-only one is untouched.
jq -e '[.hooks.SessionStart[].hooks[]? | select(.command == "my-local-hook.sh")] | length == 1' "$MULTIMETA_HOME/settings.json" >/dev/null \
  || fail "a live-only command in a multi-command group must survive untouched"
jq -e '[.hooks.SessionStart[].hooks[]? | select(.command == "shared.sh") | .async] | .[0] == true' "$MULTIMETA_HOME/settings.json" >/dev/null \
  || fail "the shared command should carry the repo metadata (async)"
MULTIMETA_TOTAL=$(jq '[.hooks.SessionStart[].hooks[]?] | length' "$MULTIMETA_HOME/settings.json")
[ "$MULTIMETA_TOTAL" -eq 2 ] || fail "each command exactly once (total hooks=$MULTIMETA_TOTAL)"

# A live-only hook with no repo counterpart keeps its own metadata.
jq -e '[.hooks.SessionStart[].hooks[]? | select(.command == "my-local-hook.sh")] | .[0] | has("async") | not' "$MULTIMETA_HOME/settings.json" >/dev/null \
  || fail "a live-only hook must not inherit metadata from an unrelated repo hook"

# =======================================================================
# Regression: UPGRADING an existing alternate-CLAUDE_HOME install. Its live
# settings.json still holds commands written before the path rewrite
# existed -- the literal "$HOME"/.claude form -- while the repo side is now
# rewritten to the alternate path. Those are the same hook, so without
# normalizing the live side first the rewritten one gets appended and the
# obsolete default-home one stays active: the command runs twice, once from
# a path where nothing was ever deployed.
# =======================================================================
UPGRADE_REPO=$(fake_repo)
cat > "$UPGRADE_REPO/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "\"$HOME\"/.claude/statusline-command.sh"},
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$HOME\"/.claude/hooks/some-hook.sh"}]}
    ]
  }
}
EOF
UPGRADE_TARGET=$(mktemp -d "$SUITE_TMP/upgrade-target.XXXXXX")
# Simulate the PRE-rewrite deployed state: the old literal "$HOME" form.
cat > "$UPGRADE_TARGET/settings.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$HOME\"/.claude/hooks/some-hook.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$UPGRADE_REPO" "$UPGRADE_TARGET" --apply
UPGRADE_TOTAL=$(jq '[.hooks.UserPromptSubmit[].hooks[]] | length' "$UPGRADE_TARGET/settings.json")
[ "$UPGRADE_TOTAL" -eq 1 ] \
  || fail "upgrading an alternate-home install duplicated the hook (count=$UPGRADE_TOTAL): the stale \"\$HOME\" copy was left active alongside the rewritten one"
UPGRADE_CMD=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$UPGRADE_TARGET/settings.json")
[ "$UPGRADE_CMD" = "'$UPGRADE_TARGET'/hooks/some-hook.sh" ] \
  || fail "the surviving hook should be migrated to the alternate path, got: $UPGRADE_CMD"
jq -e '[.. | strings | select(startswith("\"$HOME\"/.claude"))] | length == 0' "$UPGRADE_TARGET/settings.json" >/dev/null \
  || fail "no obsolete \"\$HOME\"/.claude command should remain after an alternate-home upgrade"

# A live-only hook the user pointed at their default home is NOT a
# previously-deployed copy of a repo hook, so it must be left alone rather
# than silently repointed into the alternate home.
LIVEONLY_TARGET=$(mktemp -d "$SUITE_TMP/liveonly-target.XXXXXX")
cat > "$LIVEONLY_TARGET/settings.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$HOME\"/.claude/hooks/my-own-hook.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$UPGRADE_REPO" "$LIVEONLY_TARGET" --apply
jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command == "\"$HOME\"/.claude/hooks/my-own-hook.sh")] | length == 1' "$LIVEONLY_TARGET/settings.json" >/dev/null \
  || fail "a live-only hook with no repo counterpart must keep the path the user gave it"

# =======================================================================
# Regression: deploying to an explicit alternate CLAUDE_HOME rewrites the
# literal "$HOME"/.claude prefix in repo-authored commands (hooks AND
# statusLine) to the actual target -- otherwise the deployed config tells
# Claude Code to run scripts from the wrong (default) location.
# =======================================================================
ALT_REPO=$(fake_repo)
cat > "$ALT_REPO/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "\"$HOME\"/.claude/statusline-command.sh", "refreshInterval": 30},
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"$HOME\"/.claude/hooks/some-hook.sh"}]}
    ]
  }
}
EOF
ALT_TARGET=$(mktemp -d "$SUITE_TMP/alt-target.XXXXXX")
expect_exit 0 "$ALT_REPO" "$ALT_TARGET" --apply
# Rewritten path is shell-quoted (single-quoted via jq's @sh), not spliced in
# raw -- see the space-in-CLAUDE_HOME regression below for why.
expected_status_cmd="'$ALT_TARGET'/statusline-command.sh"
expected_hook_cmd="'$ALT_TARGET'/hooks/some-hook.sh"
jq -e --arg c "$expected_status_cmd" '.statusLine.command == $c' "$ALT_TARGET/settings.json" >/dev/null \
  || fail "statusLine.command should be rewritten (quoted) to the alternate CLAUDE_HOME, got: $(jq -r '.statusLine.command' "$ALT_TARGET/settings.json")"
jq -e --arg c "$expected_hook_cmd" '.hooks.UserPromptSubmit[0].hooks[0].command == $c' "$ALT_TARGET/settings.json" >/dev/null \
  || fail "hook command should also be rewritten (quoted) to the alternate CLAUDE_HOME, got: $(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$ALT_TARGET/settings.json")"

# =======================================================================
# Regression: a CLAUDE_HOME containing a space must still work when its
# rewritten command is later invoked through a shell (Claude Code runs
# hook/statusLine commands via the shell) -- an unquoted rewrite would let
# the space split the path into two argv words and fail to execute.
# =======================================================================
SPACE_REPO=$(fake_repo)
cat > "$SPACE_REPO/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "\"$HOME\"/.claude/statusline-command.sh"}
}
EOF
SPACE_TARGET=$(mktemp -d "$SUITE_TMP/alt target with spaces.XXXXXX")
expect_exit 0 "$SPACE_REPO" "$SPACE_TARGET" --apply
printf '#!/usr/bin/env bash\necho ran-ok\n' > "$SPACE_TARGET/statusline-command.sh"
chmod +x "$SPACE_TARGET/statusline-command.sh"
rewritten_cmd=$(jq -r '.statusLine.command' "$SPACE_TARGET/settings.json")
[ "$(bash -c "$rewritten_cmd")" = "ran-ok" ] \
  || fail "rewritten command with a space in CLAUDE_HOME must execute as one path when run through a shell, got command: $rewritten_cmd"

# =======================================================================
# Regression: a live group that predates a new `if:` predicate must not
# leave the hook registered TWICE. Including `if` in a dedup key made the
# stale live group read as a different trigger, so the repo group was
# appended and the old one kept -- this repo own enforce-git-conventions.sh
# then fired on every Bash call as well as under `Bash(git *)`.
# =======================================================================
IFDUP_REPO=$(fake_repo)
cat > "$IFDUP_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "if": "Bash(git *)", "hooks": [{"type": "command", "command": "guard.sh"}]}
    ]
  }
}
EOF
IFDUP_HOME=$(fake_home)
cat > "$IFDUP_HOME/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}
    ]
  }
}
EOF
expect_exit 0 "$IFDUP_REPO" "$IFDUP_HOME" --apply
IFDUP_N=$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "guard.sh")] | length' "$IFDUP_HOME/settings.json")
[ "$IFDUP_N" -eq 1 ] || fail "guard.sh should be registered exactly once, got $IFDUP_N (stale predicate-less group kept alongside the repo group)"
jq -e '[.hooks.PreToolUse[] | select(.if == "Bash(git *)")] | length == 1' "$IFDUP_HOME/settings.json" >/dev/null \
  || fail "the surviving registration should carry the repo predicate"
# The repo may still ship one command under two DELIBERATE triggers.
TWOTRIG_REPO=$(fake_repo)
cat > "$TWOTRIG_REPO/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "both.sh"}]},
      {"matcher": "Write", "hooks": [{"type": "command", "command": "both.sh"}]}
    ]
  }
}
EOF
TWOTRIG_HOME=$(fake_home)
echo '{}' > "$TWOTRIG_HOME/settings.json"
expect_exit 0 "$TWOTRIG_REPO" "$TWOTRIG_HOME" --apply
[ "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command == "both.sh")] | length' "$TWOTRIG_HOME/settings.json")" -eq 2 ] \
  || fail "a command the repo deliberately ships under two triggers must get both"

# =======================================================================
# Regression: a live hook group with no `hooks` key must not abort the
# merge. The live side iterated `.hooks` unguarded while the repo side used
# `?`, so a hand-edited group produced "Cannot iterate over null", exit 5,
# and a partial apply with no backup pointer printed.
# =======================================================================
NOHOOKS_REPO=$(fake_repo)
NOHOOKS_HOME=$(fake_home)
cat > "$NOHOOKS_HOME/settings.json" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash"}]}}
EOF
expect_exit 0 "$NOHOOKS_REPO" "$NOHOOKS_HOME" --apply
jq -e '.hooks' "$NOHOOKS_HOME/settings.json" >/dev/null \
  || fail "a live group missing its hooks key should not corrupt the merged settings"

# =======================================================================
# Regression: CLAUDE.md and settings.json must not be written THROUGH a
# symlink. The script already defends the overlay dirs, hooks and
# statusline this way; these two paths were missed, so an --apply clobbered
# a file outside CLAUDE_HOME and left the link in place.
# =======================================================================
SYMFILE_REPO=$(fake_repo)
SYMFILE_HOME=$(fake_home)
SYMFILE_OUT=$(mktemp -d "$SUITE_TMP/outside.XXXXXX")
echo 'EXTERNAL CLAUDE.md' > "$SYMFILE_OUT/victim.md"
echo '{"external":"settings"}' > "$SYMFILE_OUT/victim-settings.json"
ln -s "$SYMFILE_OUT/victim.md" "$SYMFILE_HOME/CLAUDE.md"
ln -s "$SYMFILE_OUT/victim-settings.json" "$SYMFILE_HOME/settings.json"
expect_exit 0 "$SYMFILE_REPO" "$SYMFILE_HOME" --apply
[ "$(cat "$SYMFILE_OUT/victim.md")" = "EXTERNAL CLAUDE.md" ] \
  || fail "sync wrote through the CLAUDE.md symlink and clobbered a file outside CLAUDE_HOME"
jq -e '.external == "settings"' "$SYMFILE_OUT/victim-settings.json" >/dev/null \
  || fail "sync wrote through the settings.json symlink and clobbered a file outside CLAUDE_HOME"
[ ! -L "$SYMFILE_HOME/CLAUDE.md" ] || fail "the CLAUDE.md symlink should have been replaced with a real file"
[ ! -L "$SYMFILE_HOME/settings.json" ] || fail "the settings.json symlink should have been replaced with a real file"
[ -f "$SYMFILE_HOME/CLAUDE.md" ] || fail "CLAUDE.md should exist as a real file after the sync"

# =======================================================================
# Coverage note: every branch this suite can reach without mocking a
# missing `jq` binary has an assertion above. Exit codes exercised: 0, 10.
# =======================================================================
echo "sync-claude-config.test.sh: all assertions passed (exit codes exercised:$EXERCISED_EXIT_CODES)"
