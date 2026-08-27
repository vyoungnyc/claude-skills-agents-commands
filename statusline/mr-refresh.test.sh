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
# SECURITY regression: a credential-bearing origin URL must never be
# persisted into the cache. `https://TOKEN@host/...` remotes are common
# (PATs, CI tokens), and the raw value used to be written as BOTH the JSON
# key and the `repo` field -- copying the token into a long-lived,
# predictably-named file. The stored identity must be the sanitized URL.
# =======================================================================
CREDS_REPO="$SUITE_TMP/creds-repo"
mkdir -p "$CREDS_REPO"
git init -q "$CREDS_REPO"
git -C "$CREDS_REPO" remote add origin "https://glpat-SECRETTOKEN123@gitlab.example.com/group/repo.git"
CREDS_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$CREDS_HOME" "$FOUND_JSON")
env HOME="$CREDS_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$CREDS_REPO" "feature/x"
CREDS_CACHE="$CREDS_HOME/.claude/.mr-cache.json"
[ -f "$CREDS_CACHE" ] || fail "credential test setup: expected a cache file"
grep -q 'glpat-SECRETTOKEN123' "$CREDS_CACHE" \
  && fail "the origin URL's credential was persisted into the MR cache: $(cat "$CREDS_CACHE")"
SANITIZED_KEY=$(printf '%s\t%s' "https://gitlab.example.com/group/repo.git" "feature/x")
[ "$(jq -r --arg k "$SANITIZED_KEY" '.[$k].number' "$CREDS_CACHE")" = "42" ] \
  || fail "the entry should be keyed by the sanitized URL, got keys: $(jq -r 'keys[]' "$CREDS_CACHE")"
[ "$(jq -r --arg k "$SANITIZED_KEY" '.[$k].repo' "$CREDS_CACHE")" = "https://gitlab.example.com/group/repo.git" ] \
  || fail "the stored repo field should be the sanitized URL"

# The cache must be owner-only, not whatever the ambient umask yields.
CREDS_MODE=$(stat -c %a "$CREDS_CACHE" 2>/dev/null || stat -f %Lp "$CREDS_CACHE" 2>/dev/null)
[ "$CREDS_MODE" = "600" ] || fail "the MR cache should be mode 600, got $CREDS_MODE"

# An `@` inside the PATH is legitimate and must NOT be treated as userinfo.
ATPATH_REPO="$SUITE_TMP/atpath-repo"
mkdir -p "$ATPATH_REPO"
git init -q "$ATPATH_REPO"
git -C "$ATPATH_REPO" remote add origin "https://gitlab.example.com/group/we@ird.git"
ATPATH_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$ATPATH_HOME" "$FOUND_JSON")
env HOME="$ATPATH_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$ATPATH_REPO" "feature/x"
ATPATH_KEY=$(printf '%s\t%s' "https://gitlab.example.com/group/we@ird.git" "feature/x")
[ "$(jq -r --arg k "$ATPATH_KEY" '.[$k].number' "$ATPATH_HOME/.claude/.mr-cache.json")" = "42" ] \
  || fail "an @ in the URL path must be preserved, not cut as userinfo; got keys: $(jq -r 'keys[]' "$ATPATH_HOME/.claude/.mr-cache.json")"

# A credential-bearing entry left by an EARLIER version is purged on the next
# write, rather than lingering until the age-based prune.
LEGACYCRED_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$LEGACYCRED_HOME" "$FOUND_JSON")
LEGACYCRED_KEY=$(printf '%s\t%s' "https://glpat-OLDTOKEN@gitlab.example.com/group/other.git" "some-branch")
SCP_KEY=$(printf '%s\t%s' "git@gitlab.example.com:group/third.git" "scp-branch")
jq -n --arg k "$LEGACYCRED_KEY" --arg s "$SCP_KEY" --argjson now "$(date +%s)" \
  '{($k): {repo:"https://glpat-OLDTOKEN@gitlab.example.com/group/other.git", branch:"some-branch", number:"7", url:"https://e/7", ts:$now},
    ($s): {repo:"git@gitlab.example.com:group/third.git", branch:"scp-branch", number:"8", url:"https://e/8", ts:$now}}' \
  > "$LEGACYCRED_HOME/.claude/.mr-cache.json"
env HOME="$LEGACYCRED_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$CREDS_REPO" "feature/x"
grep -q 'glpat-OLDTOKEN' "$LEGACYCRED_HOME/.claude/.mr-cache.json" \
  && fail "a credential-bearing entry from an earlier version should be purged, not carried forward"
# The scp-like `git@host:path` form carries a username, not a secret, but it is
# still not what the sanitizer now produces, so it is dropped as stale too.
[ "$(jq -r --arg s "$SCP_KEY" 'has($s)' "$LEGACYCRED_HOME/.claude/.mr-cache.json")" = "false" ] \
  || fail "an unsanitized scp-form key should be dropped as stale-by-construction"

# =======================================================================
# Regression: a FAILING lookup (auth error, network down, unknown host,
# timeout) must still record an entry. It used to exit writing nothing, so
# the reader saw no fresh entry and relaunched this script on every
# status-line render (~30s), respawning the failing CLI and re-hitting the
# network indefinitely. The entry is marked `failed` so both sides treat it
# as fresh only for the short FAIL_COOLDOWN window.
# =======================================================================
fake_failing_glab_stubdir() {
  local home="$1" dir
  dir=$(mktemp -d "$SUITE_TMP/failbin.XXXXXX")
  cat > "$dir/glab" <<EOF
#!/usr/bin/env bash
touch "$home/glab-called"
echo "error: authentication failed" >&2
exit 1
EOF
  chmod +x "$dir/glab"
  printf '%s' "$dir"
}

FAIL_HOME=$(fake_home)
STUBDIR=$(fake_failing_glab_stubdir "$FAIL_HOME")
env HOME="$FAIL_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$FAIL_HOME" || fail "failure test setup: glab should have been invoked"
FAIL_CACHE="$FAIL_HOME/.claude/.mr-cache.json"
[ -f "$FAIL_CACHE" ] || fail "a failed lookup must still write a cache entry, or it is retried on every render"
FAIL_KEY=$(mr_key "" "feature/x")
[ "$(jq -r --arg k "$FAIL_KEY" '.[$k].failed' "$FAIL_CACHE")" = "true" ] \
  || fail "the entry from a failed lookup should be marked failed:true"
[ "$(jq -r --arg k "$FAIL_KEY" '.[$k].number' "$FAIL_CACHE")" = "null" ] \
  || fail "a failed lookup must not invent an MR number"

# Within the cooldown, a second run does NOT re-invoke glab.
rm -f "$FAIL_HOME/glab-called"
env HOME="$FAIL_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$FAIL_HOME" \
  && fail "a fresh failed entry should suppress the retry -- otherwise the failing CLI is respawned every render"

# Once the cooldown has expired, it retries (a transient failure must not
# hide a real MR indefinitely). Backdate the entry past FAIL_COOLDOWN=120
# but keep it inside the 600s success window, so only the failure-specific
# window can explain a retry.
jq --arg k "$FAIL_KEY" --argjson t "$(($(date +%s) - 300))" '.[$k].ts = $t' "$FAIL_CACHE" > "$FAIL_CACHE.new" \
  && mv "$FAIL_CACHE.new" "$FAIL_CACHE"
rm -f "$FAIL_HOME/glab-called"
STUBDIR_OK=$(fake_glab_stubdir "$FAIL_HOME" "$FOUND_JSON")
env HOME="$FAIL_HOME" PATH="$STUBDIR_OK:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$FAIL_HOME" || fail "an expired failed entry should be retried (120s cooldown, not the 600s success window)"
[ "$(jq -r --arg k "$FAIL_KEY" '.[$k].number' "$FAIL_CACHE")" = "42" ] \
  || fail "a successful retry should replace the failed entry with the real MR"
[ "$(jq -r --arg k "$FAIL_KEY" '.[$k].failed' "$FAIL_CACHE")" = "null" ] \
  || fail "the failed marker must be cleared once the lookup succeeds"

# A failed lookup must not disturb another repo/branch's entry.
OTHERKEY=$(mr_key "https://gitlab.example.com/group/untouched.git" "other")
FAILMERGE_HOME=$(fake_home)
STUBDIR=$(fake_failing_glab_stubdir "$FAILMERGE_HOME")
jq -n --arg k "$OTHERKEY" --argjson now "$(date +%s)" \
  '{($k): {repo:"https://gitlab.example.com/group/untouched.git", branch:"other", number:"5", url:"https://e/5", ts:$now}}' \
  > "$FAILMERGE_HOME/.claude/.mr-cache.json"
env HOME="$FAILMERGE_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
[ "$(jq -r --arg k "$OTHERKEY" '.[$k].number' "$FAILMERGE_HOME/.claude/.mr-cache.json")" = "5" ] \
  || fail "a failed lookup must merge its entry, not replace the whole cache"

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
glab_called "$STALE_HOME" || fail "a stale (>120s) lock with no recorded owner should have been reclaimed"
[ ! -d "$STALE_HOME/.claude/.mr-refresh.lock" ] || fail "lock should be released after a successful run"

# =======================================================================
# A lock held by a LIVE process is never reclaimed, however old it is:
# `glab` does network I/O and can outlive any fixed staleness threshold, and
# stealing its lock starts a concurrent lookup whose exit then tears down
# the newer holder's lock. This suite's own pid stands in for that live
# holder (never a backgrounded sleep -- it would inherit this suite's stdout
# and wedge the caller on any early exit). A dead owner is still reclaimed.
# =======================================================================
LIVEOWNER_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$LIVEOWNER_HOME" "$FOUND_JSON")
mkdir -p "$LIVEOWNER_HOME/.claude"
LIVEOWNER_LOCK="$LIVEOWNER_HOME/.claude/.mr-refresh.lock"
mkdir "$LIVEOWNER_LOCK"
printf '%s' "$$" > "$LIVEOWNER_LOCK/owner"
set_mtime "$(($(date +%s) - 400))" "$LIVEOWNER_LOCK"
env HOME="$LIVEOWNER_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$LIVEOWNER_HOME" \
  && fail "a lock owned by a LIVE process was reclaimed despite its age -- that admits a concurrent lookup"
[ -d "$LIVEOWNER_LOCK" ] || fail "the live owner's lock must still exist"
[ "$(cat "$LIVEOWNER_LOCK/owner")" = "$$" ] || fail "the live owner's lock was taken over"

( : ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
DEADOWNER_HOME=$(fake_home)
STUBDIR=$(fake_glab_stubdir "$DEADOWNER_HOME" "$FOUND_JSON")
mkdir -p "$DEADOWNER_HOME/.claude"
DEADOWNER_LOCK="$DEADOWNER_HOME/.claude/.mr-refresh.lock"
mkdir "$DEADOWNER_LOCK"
printf '%s' "$DEAD_PID" > "$DEADOWNER_LOCK/owner"
env HOME="$DEADOWNER_HOME" PATH="$STUBDIR:$PATH" bash "$SCRIPT" "$SUITE_TMP" "feature/x"
glab_called "$DEADOWNER_HOME" || fail "a lock whose owner is dead must be reclaimed rather than deadlocking"
[ ! -d "$DEADOWNER_LOCK" ] || fail "lock should be released after reclaiming from a dead owner"
LEFTOVER=$(find "$DEADOWNER_HOME/.claude" -name '.mr-cache.json.tmp*' 2>/dev/null)
[ -z "$LEFTOVER" ] || fail "a cache temp file was left behind: $LEFTOVER"

echo "mr-refresh.test.sh: all assertions passed"
