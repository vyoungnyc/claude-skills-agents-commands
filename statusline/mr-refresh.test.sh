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
# MR found: cache written with branch, iid, and web_url.
# =======================================================================
FOUND_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$FOUND_HOME" "$FOUND_JSON")
env HOME="$FOUND_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
CACHE="$FOUND_HOME/.claude/.mr-cache.json"
[ -f "$CACHE" ] || fail "expected .mr-cache.json to be written"
[ "$(jq -r '.branch' "$CACHE")" = "feature/x" ] || fail "cached branch mismatch"
[ "$(jq -r '.number' "$CACHE")" = "42" ] || fail "cached MR number mismatch"
[ "$(jq -r '.url' "$CACHE")" = "https://gitlab.example.com/group/proj/-/merge_requests/42" ] || fail "cached MR url mismatch"

# =======================================================================
# No MR for the branch: cache still records the branch (so the status line
# knows the lookup ran), with number/url null.
# =======================================================================
NONE_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$NONE_HOME" "$NONE_JSON")
env HOME="$NONE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "no-mr-branch"
CACHE="$NONE_HOME/.claude/.mr-cache.json"
[ "$(jq -r '.branch' "$CACHE")" = "no-mr-branch" ] || fail "cached branch mismatch (no-MR case)"
[ "$(jq -r '.number' "$CACHE")" = "null" ] || fail "expected null MR number when no MR exists"
[ "$(jq -r '.url' "$CACHE")" = "null" ] || fail "expected null MR url when no MR exists"

# =======================================================================
# Fresh cache for the SAME branch already exists: skip re-querying glab.
# =======================================================================
SKIP_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$SKIP_HOME" "$FOUND_JSON")
mkdir -p "$SKIP_HOME/.claude"
jq -n '{branch:"feature/x", number: "7", url: "https://example.com/mr/7"}' > "$SKIP_HOME/.claude/.mr-cache.json"
env HOME="$SKIP_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$SKIP_HOME" && fail "a fresh cache for the same branch should skip the glab lookup"
[ "$(jq -r '.number' "$SKIP_HOME/.claude/.mr-cache.json")" = "7" ] || fail "fresh same-branch cache should not have been overwritten"

# =======================================================================
# Cache exists but for a DIFFERENT branch: still re-queries glab.
# =======================================================================
DIFFBRANCH_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$DIFFBRANCH_HOME" "$FOUND_JSON")
mkdir -p "$DIFFBRANCH_HOME/.claude"
jq -n '{branch:"other-branch", number: "7", url: "https://example.com/mr/7"}' > "$DIFFBRANCH_HOME/.claude/.mr-cache.json"
env HOME="$DIFFBRANCH_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$DIFFBRANCH_HOME" || fail "a cache for a different branch should trigger a fresh glab lookup"
[ "$(jq -r '.branch' "$DIFFBRANCH_HOME/.claude/.mr-cache.json")" = "feature/x" ] || fail "cache should now reflect the requested branch"

# =======================================================================
# Regression: cache is scoped to the repo, not just the branch name. Two
# different repos sharing a branch name must not reuse each other's fresh
# cache entry (the global .mr-cache.json is not per-repo on disk).
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
jq -n '{branch:"feature/x", repo:"https://gitlab.example.com/group/repo-a.git", number: "99", url: "https://example.com/mr/99"}' \
  > "$REPOSCOPE_HOME/.claude/.mr-cache.json"

# Same branch name, but requested from repo-b: must NOT be treated as fresh.
env HOME="$REPOSCOPE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$REPO_B" "feature/x"
glab_called "$REPOSCOPE_HOME" || fail "a fresh cache from a DIFFERENT repo with the same branch name should not block a fresh lookup"
[ "$(jq -r '.repo' "$REPOSCOPE_HOME/.claude/.mr-cache.json")" = "https://gitlab.example.com/group/repo-b.git" ] \
  || fail "cache should now record repo-b's identity, not repo-a's"

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
