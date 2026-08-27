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
  mkdir -p "$dir/scripts" "$dir/agents" "$dir/skills" "$dir/commands" "$dir/rules" "$dir/hooks"
  cp "$REAL_SCRIPT" "$dir/scripts/sync-claude-config.sh"
  chmod +x "$dir/scripts/sync-claude-config.sh"
  echo "agent content" > "$dir/agents/example.md"
  echo "skill content" > "$dir/skills/example.md"
  echo "command content" > "$dir/commands/example.md"
  echo "rule content" > "$dir/rules/example.md"
  printf '#!/bin/bash\necho hi\n' > "$dir/hooks/example.sh"
  echo "# CLAUDE.md repo version" > "$dir/CLAUDE.md"
  cat > "$dir/settings.json" <<'EOF'
{
  "env": {"REPO_FLAG": "1"},
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
cp "$SYNCED_REPO/CLAUDE.md" "$SYNCED_HOME/CLAUDE.md"
cat > "$SYNCED_HOME/settings.json" <<'EOF'
{
  "env": {"REPO_FLAG": "1"},
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
expect_stdout_match "CLAUDE.md"
expect_stdout_match "settings.json"
expect_stdout_match "Re-run with --apply"
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
[ ! -d "$APPLY_HOME/backups" ] || fail "first-ever apply with no live files must not create a backup"

jq -e '.hooks.UserPromptSubmit' "$APPLY_HOME/settings.json" >/dev/null \
  || fail "settings.json not created with repo hooks"

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

# =======================================================================
# --apply overlay-copy where a repo file collides with a live file of the
# same name: the live version is backed up before being overwritten, and
# hook scripts are backed up the same way.
# =======================================================================
COLLIDE_REPO=$(fake_repo)
COLLIDE_HOME=$(fake_home)
mkdir -p "$COLLIDE_HOME/agents" "$COLLIDE_HOME/hooks"
echo "live agent content, pre-sync" > "$COLLIDE_HOME/agents/example.md"
printf '#!/bin/bash\necho live-pre-sync\n' > "$COLLIDE_HOME/hooks/example.sh"
printf '#!/bin/bash\necho keep\n' > "$COLLIDE_HOME/hooks/keep.sh"  # live-only, not in repo
ln -s example.sh "$COLLIDE_HOME/hooks/linked.sh"  # live-only symlink hook
expect_exit 0 "$COLLIDE_REPO" "$COLLIDE_HOME" --apply

[ "$(cat "$COLLIDE_HOME/agents/example.md")" = "agent content" ] || fail "colliding agents/ file not overwritten with repo version"
[ "$(cat "$COLLIDE_HOME/hooks/example.sh")" = "#!/bin/bash
echo hi" ] || fail "colliding hooks/ file not overwritten with repo version"

COLLIDE_AGENT_BACKUP=$(find "$COLLIDE_HOME/backups" -path "*/agents/example.md" 2>/dev/null | head -1)
[ -n "$COLLIDE_AGENT_BACKUP" ] || fail "expected a backup of the overwritten agents/example.md"
[ "$(cat "$COLLIDE_AGENT_BACKUP")" = "live agent content, pre-sync" ] || fail "backed-up agents/example.md does not match pre-sync content"

COLLIDE_HOOK_BACKUP=$(find "$COLLIDE_HOME/backups" -path "*/hooks/example.sh" 2>/dev/null | head -1)
[ -n "$COLLIDE_HOOK_BACKUP" ] || fail "expected a backup of the overwritten hooks/example.sh"
[ "$(cat "$COLLIDE_HOOK_BACKUP")" = "#!/bin/bash
echo live-pre-sync" ] || fail "backed-up hooks/example.sh does not match pre-sync content"

# Whole-directory snapshot: the live-only hook (never in the repo) is captured
# in the hooks backup too, and survives in place after the overlay.
COLLIDE_HOOK_LIVEONLY=$(find "$COLLIDE_HOME/backups" -path "*/hooks/keep.sh" 2>/dev/null | head -1)
[ -n "$COLLIDE_HOOK_LIVEONLY" ] || fail "hooks backup is not a whole-directory snapshot (live-only keep.sh missing)"
[ -f "$COLLIDE_HOME/hooks/keep.sh" ] || fail "overlay must not delete a live-only hook"

# Symlink preservation: a live symlinked hook must be backed up AS a symlink
# (cp -R, not -r, which follows links on BSD), so a restore recreates the link
# rather than a dereferenced regular file.
COLLIDE_HOOK_LINK=$(find "$COLLIDE_HOME/backups" -path "*/hooks/linked.sh" 2>/dev/null | head -1)
[ -L "$COLLIDE_HOOK_LINK" ] || fail "hooks backup dereferenced a symlink instead of preserving it"
[ "$(readlink "$COLLIDE_HOOK_LINK")" = "example.sh" ] || fail "backed-up symlink target changed"

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
BACKUP_MD=$(find "$MD_HOME/backups" -name "CLAUDE.md" 2>/dev/null | head -1)
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

ST_BACKUP=$(find "$ST_HOME/backups" -name "settings.json" 2>/dev/null | head -1)
[ -n "$ST_BACKUP" ] || fail "expected a settings.json backup"
jq -e '.hooks.PreToolUse[0].hooks[0].command == "live-only-hook.sh" and (.hooks.UserPromptSubmit | not)' "$ST_BACKUP" >/dev/null \
  || fail "backed-up settings.json does not match pre-merge content"

# =======================================================================
# Idempotency: running --apply a second time makes no further change and
# does not duplicate the merged hook entry.
# =======================================================================
expect_exit 0 "$ST_REPO" "$ST_HOME" --apply
expect_stdout_match "Already in sync"
UPS_COUNT=$(jq '.hooks.UserPromptSubmit | length' "$ST_HOME/settings.json")
[ "$UPS_COUNT" -eq 1 ] || fail "second apply duplicated the merged hook entry (count=$UPS_COUNT)"

# =======================================================================
# Coverage note: every branch this suite can reach without mocking a
# missing `jq` binary has an assertion above. Exit codes exercised: 0, 10.
# =======================================================================
echo "sync-claude-config.test.sh: all assertions passed (exit codes exercised:$EXERCISED_EXIT_CODES)"
