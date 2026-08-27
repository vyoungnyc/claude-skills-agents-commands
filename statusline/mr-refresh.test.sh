#!/bin/bash
# Self-contained test suite for statusline/mr-refresh.sh.
# Style follows scripts/sync-claude-config.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# mr-refresh.sh hardcodes $HOME/.claude/* paths and shells out to `glab`.
# Isolation here means `env HOME=... PATH=<stubdir>:$PATH bash script.sh`
# against a throwaway tree with a stubbed `glab` on PATH — the real
# ~/.claude and gitlab.com are never touched by this suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/mr-refresh.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
SUITE_TMP=$(cd "$SUITE_TMP" && pwd -P)
trap 'rm -rf "$SUITE_TMP"' EXIT

set_mtime() {
  local epoch="$1" file="$2" stamp
  stamp=$(date -d "@$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null) || stamp=$(date -r "$epoch" "+%Y%m%d%H%M.%S" 2>/dev/null)
  touch -t "$stamp" "$file"
}

fake_home() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  mkdir -p "$dir/.claude"
  printf '%s' "$dir"
}

# fake_glab_stubdir <home> <json> — a PATH directory containing a `glab`
# stub that touches "<home>/glab-called" and prints <json> for any
# `glab mr list ...` invocation (ignores args, matching real usage here).
fake_glab_stubdir() {
  local home="$1" json="$2" dir
  dir=$(mktemp -d "$SUITE_TMP/bin.XXXXXX")
  cat > "$dir/glab" <<EOF
#!/usr/bin/env bash
touch "$home/glab-called"
cat <<'JSON'
$json
JSON
EOF
  chmod +x "$dir/glab"
  printf '%s' "$dir"
}

glab_called() { [ -f "$1/glab-called" ]; }

# mr_key <repo_id> <branch> — the cache's per-entry object key, matching the
# script's own "<repo_id>\t<branch>" derivation.
mr_key() { printf '%s\t%s' "$1" "$2"; }

FOUND_JSON='[{"iid": 42, "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/42"}]'
NONE_JSON='[]'

# =======================================================================
# glab missing from PATH: no-op, exit 0, cache untouched.
# =======================================================================
NOGLAB_HOME=$(fake_home)
env HOME="$NOGLAB_HOME" PATH="/usr/bin:/bin" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
[ ! -f "$NOGLAB_HOME/.claude/.mr-cache.json" ] || fail "missing glab should leave no cache file behind"

# =======================================================================
# No branch argument: no-op, exit 0.
# =======================================================================
NOBRANCH_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$NOBRANCH_HOME" "$FOUND_JSON")
env HOME="$NOBRANCH_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" ""
glab_called "$NOBRANCH_HOME" && fail "an empty branch should short-circuit before calling glab"

# =======================================================================
# MR found: cache written keyed by repo+branch, with branch, iid, web_url.
# =======================================================================
FOUND_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$FOUND_HOME" "$FOUND_JSON")
env HOME="$FOUND_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
CACHE="$FOUND_HOME/.claude/.mr-cache.json"
[ -f "$CACHE" ] || fail "expected .mr-cache.json to be written"
KEY=$(mr_key "" "feature/x")
[ "$(jq -r --arg k "$KEY" '.[$k].branch' "$CACHE")" = "feature/x" ] || fail "cached branch mismatch"
[ "$(jq -r --arg k "$KEY" '.[$k].number' "$CACHE")" = "42" ] || fail "cached MR number mismatch"
[ "$(jq -r --arg k "$KEY" '.[$k].url' "$CACHE")" = "https://gitlab.example.com/group/proj/-/merge_requests/42" ] || fail "cached MR url mismatch"

# =======================================================================
# No MR for the branch: cache still records the branch (so the status line
# knows the lookup ran), with number/url null.
# =======================================================================
NONE_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$NONE_HOME" "$NONE_JSON")
env HOME="$NONE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "no-mr-branch"
CACHE="$NONE_HOME/.claude/.mr-cache.json"
KEY=$(mr_key "" "no-mr-branch")
[ "$(jq -r --arg k "$KEY" '.[$k].branch' "$CACHE")" = "no-mr-branch" ] || fail "cached branch mismatch (no-MR case)"
[ "$(jq -r --arg k "$KEY" '.[$k].number' "$CACHE")" = "null" ] || fail "expected null MR number when no MR exists"
[ "$(jq -r --arg k "$KEY" '.[$k].url' "$CACHE")" = "null" ] || fail "expected null MR url when no MR exists"

# =======================================================================
# Fresh entry for the SAME repo+branch already exists: skip re-querying glab.
# =======================================================================
SKIP_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$SKIP_HOME" "$FOUND_JSON")
mkdir -p "$SKIP_HOME/.claude"
KEY=$(mr_key "" "feature/x")
jq -n --arg k "$KEY" --argjson now "$(date +%s)" \
  '{($k): {branch:"feature/x", repo:"", number: "7", url: "https://example.com/mr/7", ts: $now}}' \
  > "$SKIP_HOME/.claude/.mr-cache.json"
env HOME="$SKIP_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$SKIP_HOME" && fail "a fresh entry for the same repo+branch should skip the glab lookup"
[ "$(jq -r --arg k "$KEY" '.[$k].number' "$SKIP_HOME/.claude/.mr-cache.json")" = "7" ] || fail "fresh entry should not have been overwritten"

# =======================================================================
# Cache has an entry for a DIFFERENT branch (same repo): still re-queries
# glab, and the other branch's own entry survives the write untouched (a
# per-key merge, not a whole-file replace).
# =======================================================================
DIFFBRANCH_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$DIFFBRANCH_HOME" "$FOUND_JSON")
mkdir -p "$DIFFBRANCH_HOME/.claude"
KEY_OTHER=$(mr_key "" "other-branch")
jq -n --arg k "$KEY_OTHER" --argjson now "$(date +%s)" \
  '{($k): {branch:"other-branch", repo:"", number: "7", url: "https://example.com/mr/7", ts: $now}}' \
  > "$DIFFBRANCH_HOME/.claude/.mr-cache.json"
env HOME="$DIFFBRANCH_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$DIFFBRANCH_HOME" || fail "a cache with no entry for this branch should trigger a fresh glab lookup"
KEY_NEW=$(mr_key "" "feature/x")
[ "$(jq -r --arg k "$KEY_NEW" '.[$k].branch' "$DIFFBRANCH_HOME/.claude/.mr-cache.json")" = "feature/x" ] || fail "cache should now have an entry for the requested branch"
[ "$(jq -r --arg k "$KEY_OTHER" '.[$k].branch' "$DIFFBRANCH_HOME/.claude/.mr-cache.json")" = "other-branch" ] \
  || fail "the other branch's existing entry must survive the merge, not be replaced"

# =======================================================================
# Regression: cache is scoped to the repo, not just the branch name. Two
# different repos sharing a branch name must not reuse each other's fresh
# cache entry, and refreshing one repo's entry must not clobber the other's
# (each repo+branch owns its own key in the same shared file).
# =======================================================================
REPO_A="$SUITE_TMP/repo-a"
REPO_B="$SUITE_TMP/repo-b"
mkdir -p "$REPO_A" "$REPO_B"
git init -q "$REPO_A"
git -C "$REPO_A" remote add origin "https://gitlab.example.com/group/repo-a.git"
git init -q "$REPO_B"
git -C "$REPO_B" remote add origin "https://gitlab.example.com/group/repo-b.git"

REPOSCOPE_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$REPOSCOPE_HOME" "$FOUND_JSON")
mkdir -p "$REPOSCOPE_HOME/.claude"
KEY_A=$(mr_key "https://gitlab.example.com/group/repo-a.git" "feature/x")
jq -n --arg k "$KEY_A" --argjson now "$(date +%s)" \
  '{($k): {branch:"feature/x", repo:"https://gitlab.example.com/group/repo-a.git", number: "99", url: "https://example.com/mr/99", ts: $now}}' \
  > "$REPOSCOPE_HOME/.claude/.mr-cache.json"

# Same branch name, but requested from repo-b: must NOT be treated as fresh.
env HOME="$REPOSCOPE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$REPO_B" "feature/x"
glab_called "$REPOSCOPE_HOME" || fail "a fresh entry from a DIFFERENT repo with the same branch name should not block a fresh lookup"
KEY_B=$(mr_key "https://gitlab.example.com/group/repo-b.git" "feature/x")
[ "$(jq -r --arg k "$KEY_B" '.[$k].repo' "$REPOSCOPE_HOME/.claude/.mr-cache.json")" = "https://gitlab.example.com/group/repo-b.git" ] \
  || fail "cache should now have repo-b's own entry"
[ "$(jq -r --arg k "$KEY_A" '.[$k].number' "$REPOSCOPE_HOME/.claude/.mr-cache.json")" = "99" ] \
  || fail "repo-a's entry must survive untouched -- concurrent sessions on different repos must not clobber each other's cache entry"

# =======================================================================
# Backward compatibility: a pre-upgrade flat-format cache (a single
# unkeyed {branch,repo,number,url} object, no per-entry "ts") is discarded
# rather than crashing the jq merge or corrupting the write.
# =======================================================================
LEGACY_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$LEGACY_HOME" "$FOUND_JSON")
mkdir -p "$LEGACY_HOME/.claude"
jq -n '{branch:"feature/x", repo:"", number: "7", url: "https://example.com/mr/7"}' > "$LEGACY_HOME/.claude/.mr-cache.json"
env HOME="$LEGACY_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
KEY=$(mr_key "" "feature/x")
[ "$(jq -r --arg k "$KEY" '.[$k].number' "$LEGACY_HOME/.claude/.mr-cache.json")" = "42" ] \
  || fail "a legacy flat-format cache should be discarded and replaced with the new keyed entry, not break the write"

# =======================================================================
# Single-flight lock: a held (fresh) lock skips the lookup.
# =======================================================================
LOCK_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$LOCK_HOME" "$FOUND_JSON")
mkdir -p "$LOCK_HOME/.claude"
mkdir "$LOCK_HOME/.claude/.mr-refresh.lock"
env HOME="$LOCK_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$LOCK_HOME" && fail "a held lock should have prevented the lookup from running"
rmdir "$LOCK_HOME/.claude/.mr-refresh.lock"

# =======================================================================
# Stale lock (>120s) is reclaimed, and released again after a successful
# run.
# =======================================================================
STALE_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$STALE_HOME" "$FOUND_JSON")
mkdir -p "$STALE_HOME/.claude"
mkdir "$STALE_HOME/.claude/.mr-refresh.lock"
set_mtime "$(($(date +%s) - 200))" "$STALE_HOME/.claude/.mr-refresh.lock"
env HOME="$STALE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$STALE_HOME" || fail "a stale (>120s) lock should have been reclaimed"
[ ! -d "$STALE_HOME/.claude/.mr-refresh.lock" ] || fail "lock should be released after a successful run"

echo "mr-refresh.test.sh: all assertions passed"
