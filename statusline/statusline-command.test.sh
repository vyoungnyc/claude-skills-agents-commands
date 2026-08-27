#!/bin/bash
# Self-contained test suite for statusline/statusline-command.sh.
# Style follows scripts/sync-claude-config.test.sh: set -euo pipefail, a jq
# guard, a fail() that writes to stderr and exits 1, small expect_*
# wrappers, flat top-level assertion calls, no test framework.
#
# statusline-command.sh hardcodes $HOME/.claude/* paths (no CLAUDE_HOME-style
# override), so isolation here means running it with HOME pointed at a
# throwaway tree via `env HOME=... bash script.sh` — the real ~/.claude is
# never read from or written to by this suite. Sibling helper scripts
# (token-stats.sh, usage-refresh.sh, mr-refresh.sh) are deliberately left
# absent from the fixture HOME unless a specific test needs one, so no
# background refresh jobs fire and every assertion is on synchronous,
# deterministic output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/statusline-command.sh"

command -v jq >/dev/null || { echo "jq is required to run tests" >&2; exit 1; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SUITE_TMP=$(mktemp -d)
SUITE_TMP=$(cd "$SUITE_TMP" && pwd -P)  # resolve macOS's /var -> /private/var symlink so
                                        # git's rev-parse (physical path) matches $cwd exactly
trap 'rm -rf "$SUITE_TMP"' EXIT

# fake_home — a throwaway $HOME with an empty ~/.claude/.
fake_home() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/home.XXXXXX")
  mkdir -p "$dir/.claude"
  printf '%s' "$dir"
}

# fake_glab_stubdir — a PATH directory with a no-op `glab` executable, so
# `command -v glab` succeeds without depending on whether the real `glab` is
# installed on the machine running these tests (offline/stub convention —
# see README's "Offline/stub rule"). None of the tests using this actually
# invoke glab's own lookup (MRREFRESH is never made executable in these
# fixtures, so mr-refresh.sh itself never runs); they only need
# `command -v glab` to succeed so statusline-command.sh reads the
# pre-populated .mr-cache.json fixture instead of skipping that branch.
fake_glab_stubdir() {
  local dir
  dir=$(mktemp -d "$SUITE_TMP/glabstub.XXXXXX")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/glab"
  chmod +x "$dir/glab"
  printf '%s' "$dir"
}

# run_statusline <home> <json> [extra_path_dir] — feeds <json> on stdin with
# HOME=<home> (and, if given, <extra_path_dir> prepended to PATH); captures
# raw stdout into LAST_OUT and an ANSI-stripped copy into LAST_OUT_PLAIN.
# Content assertions match against the stripped copy since a color escape
# can land *between* an emoji and the text it prefixes (the emoji is printed
# outside the color-wrapped segment) — matching raw output would require
# re-deriving exact escape placement in every assertion.
LAST_OUT=""
LAST_OUT_PLAIN=""
LAST_STATUS=0
run_statusline() {
  local home="$1" json="$2" extra_path="${3:-}"
  local path="$PATH"
  [ -n "$extra_path" ] && path="$extra_path:$PATH"
  # Capture the exit status explicitly. A bare `VAR=$(pipeline)` under
  # `set -euo pipefail` is NOT exempt from -e, so a nonzero exit from the script
  # would kill this suite silently -- no FAIL line, no test name. That failure
  # mode has already bitten this PR once. Same shape as run_sync in
  # scripts/sync-claude-config.test.sh.
  set +e
  LAST_OUT=$(printf '%s' "$json" | env HOME="$home" PATH="$path" bash "$SCRIPT")
  LAST_STATUS=$?
  set -e
  [ "$LAST_STATUS" -eq 0 ] || fail "statusline-command.sh exited $LAST_STATUS (input: ${json:0:120})"
  LAST_OUT_PLAIN=$(printf '%s' "$LAST_OUT" | sed 's/\x1b\[[0-9;]*m//g')
}

expect_match() {
  local pattern="$1"
  printf '%s' "$LAST_OUT_PLAIN" | grep -Fq -- "$pattern" || fail "output did not contain '$pattern': $LAST_OUT_PLAIN"
}

expect_not_match() {
  local pattern="$1"
  printf '%s' "$LAST_OUT_PLAIN" | grep -Fq -- "$pattern" && fail "output unexpectedly contained '$pattern': $LAST_OUT_PLAIN"
  return 0
}

# =======================================================================
# Model group: ⚡ only with fast_mode true, " · effort" only when present.
# =======================================================================
FAST_HOME=$(fake_home)
run_statusline "$FAST_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"fast_mode":true,"workspace":{"current_dir":"/tmp"}}'
expect_match "⚡Opus 4.8 · high"

PLAIN_HOME=$(fake_home)
run_statusline "$PLAIN_HOME" '{"cwd":"/tmp","model":{"display_name":"Sonnet 5"},"fast_mode":false,"workspace":{"current_dir":"/tmp"}}'
expect_match "[Sonnet 5]"
expect_not_match "⚡"

# =======================================================================
# repo/dir + branch: inside a git repo on a named branch.
# =======================================================================
GIT_HOME=$(fake_home)
GIT_REPO="$SUITE_TMP/myrepo"
mkdir -p "$GIT_REPO"
git init -q "$GIT_REPO"
git -C "$GIT_REPO" config user.email "test@example.com"
git -C "$GIT_REPO" config user.name "Test"
git -C "$GIT_REPO" commit -q --allow-empty -m init
git -C "$GIT_REPO" checkout -q -b feature/widget
run_statusline "$GIT_HOME" "$(jq -n --arg cwd "$GIT_REPO" '{cwd:$cwd,model:{display_name:"Sonnet 5"},workspace:{current_dir:$cwd}}')"
expect_match "📁 myrepo"
expect_match "🌿 feature/widget"

# =======================================================================
# Regression: an .mr-cache.json entry for the SAME branch name but a
# DIFFERENT repo must not be shown for this repo. Stubs glab on PATH
# per the offline/stub convention -- must not depend on whether the real
# glab happens to be installed on whatever machine runs this suite.
# =======================================================================
GLAB_STUB=$(fake_glab_stubdir)
MRSCOPE_HOME=$(fake_home)
mkdir -p "$MRSCOPE_HOME/.claude"
MRSCOPE_KEY=$(printf '%s\t%s' "/some/other/repo-not-this-one" "feature/widget")
jq -n --arg k "$MRSCOPE_KEY" --argjson now "$(date +%s)" \
  '{($k): {branch:"feature/widget", repo:"/some/other/repo-not-this-one", number: "55", url: "https://example.com/mr/55", ts: $now}}' \
  > "$MRSCOPE_HOME/.claude/.mr-cache.json"
run_statusline "$MRSCOPE_HOME" "$(jq -n --arg cwd "$GIT_REPO" '{cwd:$cwd,model:{display_name:"Sonnet 5"},workspace:{current_dir:$cwd}}')" "$GLAB_STUB"
expect_match "🌿 feature/widget"
expect_not_match "(#55)"

# =======================================================================
# Same branch, matching repo (toplevel path, since this fixture repo has no
# remote configured): the cached MR number/link IS shown.
# =======================================================================
MRMATCH_HOME=$(fake_home)
mkdir -p "$MRMATCH_HOME/.claude"
MRMATCH_KEY=$(printf '%s\t%s' "$GIT_REPO" "feature/widget")
jq -n --arg k "$MRMATCH_KEY" --arg repo "$GIT_REPO" --argjson now "$(date +%s)" \
  '{($k): {branch:"feature/widget", repo:$repo, number: "77", url: "https://example.com/mr/77", ts: $now}}' \
  > "$MRMATCH_HOME/.claude/.mr-cache.json"
run_statusline "$MRMATCH_HOME" "$(jq -n --arg cwd "$GIT_REPO" '{cwd:$cwd,model:{display_name:"Sonnet 5"},workspace:{current_dir:$cwd}}')" "$GLAB_STUB"
expect_match "(#77)"

# =======================================================================
# Context segment: (NN%) TOK/TOTAL, using the JSON snapshot when no
# transcript-derived cache exists (token-stats.sh absent from fixture HOME).
# =======================================================================
CTX_HOME=$(fake_home)
run_statusline "$CTX_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"},"context_window":{"total_input_tokens":267000,"context_window_size":1000000,"used_percentage":27}}'
expect_match "Context:"
expect_match "267k/1M"
expect_match "(27%)"

# =======================================================================
# Line 1 tail, mutual exclusivity: no usage-cache.json and no rate_limits
# in the JSON -> neither "Limits:" nor "[API Usage]" appears.
# =======================================================================
NONE_HOME=$(fake_home)
run_statusline "$NONE_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}'
expect_not_match "Limits:"
expect_not_match "[API Usage]"

# =======================================================================
# Limits shown, API usage hidden: usage-cache.json has 5h/7d data and
# credits disabled (enabled=false) -- Limits wins, no [API Usage] tail.
# =======================================================================
LIMITS_HOME=$(fake_home)
cat > "$LIMITS_HOME/.claude/usage-cache.json" <<'EOF'
{
  "enabled": false,
  "used": 0,
  "limit": 0,
  "pct": 0,
  "five": {"util": 20, "resets": 9999999999, "severity": "normal"},
  "seven": {"util": 3, "resets": 9999999999, "severity": "normal"}
}
EOF
run_statusline "$LIMITS_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}'
expect_match "Limits:"
expect_match "5h (20%)"
expect_match "7d (3%)"
expect_not_match "[API Usage]"

# =======================================================================
# API usage shown (enabled), Limits hidden even when both are present in
# the cache -- credits-enabled takes priority per the assemble logic.
# =======================================================================
CREDITS_HOME=$(fake_home)
cat > "$CREDITS_HOME/.claude/usage-cache.json" <<'EOF'
{
  "enabled": true,
  "used": 42.5,
  "limit": 100,
  "pct": 42,
  "resets": 9999999999,
  "five": {"util": 20, "resets": 9999999999, "severity": "normal"},
  "seven": {"util": 3, "resets": 9999999999, "severity": "normal"}
}
EOF
run_statusline "$CREDITS_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}'
expect_match "🟢 [API Usage]:"
expect_match "\$42.50 / \$100.00 (42%)"
expect_not_match "Limits:"

# =======================================================================
# API usage shown even though disabled, when there's no subscription data
# to fall back to (nothing else to display).
# =======================================================================
DISABLED_HOME=$(fake_home)
cat > "$DISABLED_HOME/.claude/usage-cache.json" <<'EOF'
{"enabled": false, "used": 10, "limit": 50, "pct": 20, "resets": 9999999999}
EOF
run_statusline "$DISABLED_HOME" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}'
expect_match "🔴 [API Usage]:"
expect_not_match "Limits:"

# =======================================================================
# token_history/<project-slug>/<session_id>.json wiring: statusline-command.sh
# must build TSTATS from the transcript's own parent directory name (the
# project slug), not the old flat ~/.claude/.tokstats-<session_id>.json, and
# render the cumulative counts + context_length found there.
# =======================================================================
TH_HOME=$(fake_home)
PROJECT_SLUG="-Users-test-myproject"
SESSION_ID="deadbeef-session"
TH_DIR="$TH_HOME/.claude/token_history/$PROJECT_SLUG"
mkdir -p "$TH_DIR"
cat > "$TH_DIR/$SESSION_ID.json" <<'EOF'
{
  "input": 2, "output": 130, "cache_read": 266600, "cache_write": 750,
  "context_length": 267000, "est_cost": 0.05,
  "main": {"input": 2, "output": 130, "cache_read": 266600, "cache_write": 750, "est_cost": 0.05},
  "agents": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "est_cost": 0}
}
EOF
STDIN_JSON=$(jq -n \
  --arg sid "$SESSION_ID" \
  --arg transcript "$TH_HOME/.claude/projects/$PROJECT_SLUG/$SESSION_ID.jsonl" \
  '{cwd:"/tmp", model:{display_name:"Opus 4.8"}, workspace:{current_dir:"/tmp"},
    session_id:$sid, transcript_path:$transcript,
    cost:{total_cost_usd:0.05},
    context_window:{context_window_size:1000000}}')
run_statusline "$TH_HOME" "$STDIN_JSON"
expect_match "267k/1M"
expect_match "130 out"
expect_match "266.6k cache-r"
[ ! -f "$TH_HOME/.claude/.tokstats-$SESSION_ID.json" ] || fail "must not write the old flat .tokstats-<session>.json path"

# =======================================================================
# Regression: an install under an alternate CLAUDE_HOME must read ITS OWN
# caches, not the default $HOME/.claude ones. The sync script deploys
# statusline scripts FLAT into CLAUDE_HOME alongside settings.json, so the
# script resolves its home from its own directory when a sibling
# settings.json is present. Both homes get a usage-cache.json here with
# DIFFERENT values, so the assertion proves which one was actually read
# rather than merely that some cache was found.
# =======================================================================
ALT_DEPLOY=$(mktemp -d "$SUITE_TMP/alt-deploy.XXXXXX")
cp "$SCRIPT" "$ALT_DEPLOY/statusline-command.sh"
echo '{}' > "$ALT_DEPLOY/settings.json"   # the marker that says "deployed Claude home"
cat > "$ALT_DEPLOY/usage-cache.json" <<'EOF'
{"enabled": true, "used": 77.25, "limit": 200, "pct": 38, "resets": 9999999999}
EOF
ALTDEFAULT_HOME=$(fake_home)
cat > "$ALTDEFAULT_HOME/.claude/usage-cache.json" <<'EOF'
{"enabled": true, "used": 11.50, "limit": 50, "pct": 23, "resets": 9999999999}
EOF
ALT_OUT=$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}' \
  | env HOME="$ALTDEFAULT_HOME" bash "$ALT_DEPLOY/statusline-command.sh" | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$ALT_OUT" | grep -Fq '$77.25 / $200.00 (38%)' \
  || fail "an alternate-home install must read the usage cache beside itself, got: $ALT_OUT"
printf '%s' "$ALT_OUT" | grep -Fq '$11.50' \
  && fail "an alternate-home install must NOT read the default \$HOME/.claude cache, got: $ALT_OUT"

# The same copied script with NO sibling settings.json is not a deployed
# Claude home -- it must fall back to $HOME/.claude (this is the repo-checkout
# case, and what every other test in this suite relies on).
NOMARKER_DEPLOY=$(mktemp -d "$SUITE_TMP/nomarker.XXXXXX")
cp "$SCRIPT" "$NOMARKER_DEPLOY/statusline-command.sh"
cat > "$NOMARKER_DEPLOY/usage-cache.json" <<'EOF'
{"enabled": true, "used": 77.25, "limit": 200, "pct": 38, "resets": 9999999999}
EOF
NOMARKER_OUT=$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}' \
  | env HOME="$ALTDEFAULT_HOME" bash "$NOMARKER_DEPLOY/statusline-command.sh" | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$NOMARKER_OUT" | grep -Fq '$11.50 / $50.00 (23%)' \
  || fail "without a sibling settings.json the script must fall back to \$HOME/.claude, got: $NOMARKER_OUT"

# An explicit CLAUDE_HOME in the environment wins over both.
ENVHOME_DEPLOY=$(mktemp -d "$SUITE_TMP/envhome.XXXXXX")
cat > "$ENVHOME_DEPLOY/usage-cache.json" <<'EOF'
{"enabled": true, "used": 5.00, "limit": 25, "pct": 20, "resets": 9999999999}
EOF
ENVHOME_OUT=$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}' \
  | env HOME="$ALTDEFAULT_HOME" CLAUDE_HOME="$ENVHOME_DEPLOY" bash "$ALT_DEPLOY/statusline-command.sh" | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$ENVHOME_OUT" | grep -Fq '$5.00 / $25.00 (20%)' \
  || fail "an explicit CLAUDE_HOME must win over both the script directory and \$HOME/.claude, got: $ENVHOME_OUT"

# =======================================================================
# SECURITY round-trip across BOTH scripts: mr-refresh.sh writes the cache
# key and statusline-command.sh looks it up, so they must sanitize a
# credential-bearing origin URL identically -- otherwise either the token
# gets persisted, or the identities diverge and every lookup silently
# misses (no MR link, and a refresh fired on every single render). Runs the
# real mr-refresh.sh against a repo whose origin embeds a token.
# =======================================================================
CRED_REPO="$SUITE_TMP/credrepo"
mkdir -p "$CRED_REPO"
git init -q "$CRED_REPO"
git -C "$CRED_REPO" config user.email "test@example.com"
git -C "$CRED_REPO" config user.name "Test"
git -C "$CRED_REPO" commit -q --allow-empty -m init
git -C "$CRED_REPO" checkout -q -b feature/tokenized
git -C "$CRED_REPO" remote add origin "https://glpat-ROUNDTRIP999@gitlab.example.com/group/proj.git"

RT_HOME=$(fake_home)
RT_BIN=$(mktemp -d "$SUITE_TMP/rtbin.XXXXXX")
cat > "$RT_BIN/glab" <<'EOF'
#!/usr/bin/env bash
echo '[{"iid": 88, "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/88"}]'
EOF
chmod +x "$RT_BIN/glab"
cp "$SCRIPT_DIR/mr-refresh.sh" "$RT_HOME/.claude/mr-refresh.sh"
chmod +x "$RT_HOME/.claude/mr-refresh.sh"
# Writer: populate the cache from the credential-bearing remote.
env HOME="$RT_HOME" PATH="$RT_BIN:$PATH" bash "$RT_HOME/.claude/mr-refresh.sh" "$CRED_REPO" "feature/tokenized"
RT_CACHE="$RT_HOME/.claude/.mr-cache.json"
[ -f "$RT_CACHE" ] || fail "round-trip setup: mr-refresh.sh wrote no cache"
grep -q 'glpat-ROUNDTRIP999' "$RT_CACHE" \
  && fail "the token was persisted into the cache by mr-refresh.sh"
# Reader: statusline-command.sh must find that entry and render the MR link.
run_statusline "$RT_HOME" "$(jq -n --arg cwd "$CRED_REPO" '{cwd:$cwd,model:{display_name:"Sonnet 5"},workspace:{current_dir:$cwd}}')" "$RT_BIN"
expect_match "(#88)"
# And the token must not leak into the rendered status line either.
printf '%s' "$LAST_OUT_PLAIN" | grep -q 'glpat-ROUNDTRIP999' \
  && fail "the token leaked into the rendered status line"

# =======================================================================
# Reader side of the failure cooldown: a `failed` entry must count as fresh
# (so a broken glab is not relaunched on every ~30s render) while it is
# inside the short cooldown, and must NOT be treated as fresh once that
# cooldown expires -- even though the same age would still be "fresh" under
# the 600s success window. A real mr-refresh.sh stand-in records whether it
# was launched.
# =======================================================================
mr_relaunch_probe() {
  # <cache_ts> <failed 0|1> -> "launched" | "suppressed"
  local ts="$1" failed="$2" home probe
  home=$(fake_home)
  probe="$home/.claude/mr-refresh.sh"
  cat > "$probe" <<EOF
#!/usr/bin/env bash
touch "$home/refresh-launched"
EOF
  chmod +x "$probe"
  local key
  key=$(printf '%s\t%s' "$GIT_REPO" "feature/widget")
  jq -n --arg k "$key" --arg repo "$GIT_REPO" --argjson t "$ts" --argjson f "$failed" \
    '{($k): ({branch:"feature/widget", repo:$repo, number:null, url:null, ts:$t}
             + (if $f == 1 then {failed:true} else {} end))}' \
    > "$home/.claude/.mr-cache.json"
  run_statusline "$home" "$(jq -n --arg cwd "$GIT_REPO" '{cwd:$cwd,model:{display_name:"Sonnet 5"},workspace:{current_dir:$cwd}}')" "$GLAB_STUB"
  # The backgrounded relaunch is async; give it a moment to land.
  local i=0
  while [ "$i" -lt 20 ] && [ ! -f "$home/refresh-launched" ]; do i=$((i+1)); /bin/sleep 0.05; done
  [ -f "$home/refresh-launched" ] && printf 'launched' || printf 'suppressed'
}

NOW_EPOCH=$(date +%s)
# Failed entry, 10s old: inside the 120s cooldown -> no relaunch.
RES=$(mr_relaunch_probe "$((NOW_EPOCH - 10))" 1)
[ "$RES" = "suppressed" ] \
  || fail "a fresh failed entry must suppress the relaunch, or a broken glab is respawned on every render (got: $RES)"
# Failed entry, 300s old: past the 120s cooldown but still inside the 600s
# success window -> must relaunch, so only the failure window explains it.
RES=$(mr_relaunch_probe "$((NOW_EPOCH - 300))" 1)
[ "$RES" = "launched" ] \
  || fail "an expired failed entry must be retried -- a transient failure must not hide a real MR (got: $RES)"
# Successful entry, 300s old: inside the 600s window -> no relaunch.
RES=$(mr_relaunch_probe "$((NOW_EPOCH - 300))" 0)
[ "$RES" = "suppressed" ] \
  || fail "a successful entry within the 600s window must not trigger a relaunch (got: $RES)"

# =======================================================================
# Regression: the .usage-backoff file is "<until_epoch> <kind>". This reader
# used to `cat` the whole line into `-ge`, which is an integer-expression
# error -- so the condition never fired and the automatic refresh stayed
# suppressed permanently once any cooldown had ever been written, including
# long after it expired. The EXPIRED case is the one that was broken.
#
# The backoff file here is produced by the REAL usage-refresh.sh (via a 429)
# rather than hand-written, so this asserts the two scripts agree on the
# format instead of pinning a literal that could drift from the writer.
# =======================================================================
usage_relaunch_probe() {
  # <backoff_file_contents...> -> "launched" | "suppressed"
  local home probe
  home=$(fake_home)
  probe="$home/.claude/usage-refresh.sh"
  cat > "$probe" <<EOF
#!/usr/bin/env bash
touch "$home/usage-refresh-launched"
EOF
  chmod +x "$probe"
  # A stale cache, so only the backoff gate can suppress the relaunch.
  echo '{"enabled": false, "used": 0, "limit": 0, "pct": 0}' > "$home/.claude/usage-cache.json"
  local stamp
  stamp=$(date -d "@$(( $(date +%s) - 4000 ))" "+%Y%m%d%H%M.%S" 2>/dev/null) \
    || stamp=$(date -r "$(( $(date +%s) - 4000 ))" "+%Y%m%d%H%M.%S" 2>/dev/null)
  touch -t "$stamp" "$home/.claude/usage-cache.json"
  printf '%s\n' "$1" > "$home/.claude/.usage-backoff"
  run_statusline "$home" '{"cwd":"/tmp","model":{"display_name":"Opus 4.8"},"workspace":{"current_dir":"/tmp"}}'
  local i=0
  while [ "$i" -lt 20 ] && [ ! -f "$home/usage-refresh-launched" ]; do i=$((i+1)); /bin/sleep 0.05; done
  [ -f "$home/usage-refresh-launched" ] && printf 'launched' || printf 'suppressed'
}

# Derive a real backoff line from the actual writer, so the format under test
# is whatever usage-refresh.sh currently produces.
BOGEN_HOME=$(mktemp -d "$SUITE_TMP/bogen.XXXXXX")
mkdir -p "$BOGEN_HOME/.claude"
cat > "$BOGEN_HOME/.claude/fetch-usage.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"error":"throttled"}'
printf '__HTTP_STATUS__429\n'
EOF
chmod +x "$BOGEN_HOME/.claude/fetch-usage.sh"
env HOME="$BOGEN_HOME" bash "$SCRIPT_DIR/usage-refresh.sh" --force >/dev/null 2>&1 || true
[ -f "$BOGEN_HOME/.claude/.usage-backoff" ] || fail "backoff-format setup: usage-refresh.sh wrote no backoff file"
REAL_BACKOFF_LINE=$(cat "$BOGEN_HOME/.claude/.usage-backoff")
# Sanity: it really is the multi-field shape this test exists to handle.
case "$REAL_BACKOFF_LINE" in
  *' '*) : ;;
  *) fail "expected usage-refresh.sh to write a '<epoch> <kind>' backoff line, got: $REAL_BACKOFF_LINE" ;;
esac

# Active cooldown (as written by the real script): refresh suppressed.
RES=$(usage_relaunch_probe "$REAL_BACKOFF_LINE")
[ "$RES" = "suppressed" ] \
  || fail "an active typed cooldown must suppress the refresh (got: $RES)"
# EXPIRED cooldown in the same format: refresh MUST run. This is the case the
# unparsed comparison broke -- it failed as an integer error and suppressed
# the refresh forever.
EXPIRED_KIND=${REAL_BACKOFF_LINE#* }
RES=$(usage_relaunch_probe "1 $EXPIRED_KIND")
[ "$RES" = "launched" ] \
  || fail "an EXPIRED typed cooldown must not suppress the refresh -- the cache would stay stale indefinitely (got: $RES)"
# No backoff file at all: refresh runs.
RES=$(usage_relaunch_probe "0")
[ "$RES" = "launched" ] || fail "with no active cooldown the refresh should run (got: $RES)"

# =======================================================================
# SECURITY regression: a non-numeric value must never reach `$(( ))`.
# Bash evaluates the VALUE as an arithmetic expression, so `x[$(cmd)]`
# executes cmd via the array-subscript rule -- turning a cache field into
# code that runs on every ~30s render. Carrier: the `ts` field of an entry
# in .mr-cache.json.
# =======================================================================
INJ_REPO="$SUITE_TMP/injrepo"
mkdir -p "$INJ_REPO"
git init -q "$INJ_REPO"
git -C "$INJ_REPO" config user.email "test@example.com"
git -C "$INJ_REPO" config user.name "Test"
git -C "$INJ_REPO" commit -q --allow-empty -m init
git -C "$INJ_REPO" checkout -q -b feature/inj
git -C "$INJ_REPO" remote add origin "https://gitlab.example.com/g/r.git"
INJ_HOME=$(fake_home)
# mr-refresh.sh must be present and executable for the freshness branch to run.
printf '#!/usr/bin/env bash\nexit 0\n' > "$INJ_HOME/.claude/mr-refresh.sh"
chmod +x "$INJ_HOME/.claude/mr-refresh.sh"
INJ_CANARY="$SUITE_TMP/injection-canary"
rm -f "$INJ_CANARY"
INJ_KEY=$(printf '%s\t%s' "https://gitlab.example.com/g/r.git" "feature/inj")
jq -n --arg k "$INJ_KEY" --arg ts "x[\$(touch $INJ_CANARY)]" \
  '{($k): {repo:"https://gitlab.example.com/g/r.git", branch:"feature/inj", number:"9", url:"https://e/9", ts:$ts}}' \
  > "$INJ_HOME/.claude/.mr-cache.json"
run_statusline "$INJ_HOME" "$(jq -n --arg cwd "$INJ_REPO" '{cwd:$cwd,model:{display_name:"S"},workspace:{current_dir:$cwd}}')" "$GLAB_STUB"
[ ! -f "$INJ_CANARY" ] \
  || fail "a non-numeric ts in the MR cache reached \$(( )) and executed code"

# A non-numeric reset epoch must not emit a bash arithmetic error, and must
# not silently render a confident "resets in 0m" lie.
BADRESET_HOME=$(fake_home)
cat > "$BADRESET_HOME/.claude/usage-cache.json" <<'EOF'
{"enabled": false, "used": 0, "limit": 0, "pct": 0,
 "five": {"util": 42, "resets": "2026-08-28T10:00:00Z", "severity": "normal"},
 "seven": {"util": 9, "resets": "soon", "severity": "normal"}}
EOF
BADRESET_ERR="$SUITE_TMP/badreset.err"
printf '%s' '{"cwd":"/tmp","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"}}' \
  | env HOME="$BADRESET_HOME" bash "$SCRIPT" >/dev/null 2>"$BADRESET_ERR"
[ ! -s "$BADRESET_ERR" ] \
  || fail "a non-numeric reset value leaked an error to stderr: $(head -2 "$BADRESET_ERR")"
run_statusline "$BADRESET_HOME" '{"cwd":"/tmp","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"}}'
expect_not_match "resets in 0m"

# A garbage utilization must not emit a printf error either.
BADUTIL_HOME=$(fake_home)
cat > "$BADUTIL_HOME/.claude/usage-cache.json" <<'EOF'
{"enabled": false, "used": 0, "limit": 0, "pct": 0,
 "five": {"util": "n/a", "resets": 9999999999, "severity": "normal"},
 "seven": {"util": 3, "resets": 9999999999, "severity": "normal"}}
EOF
BADUTIL_ERR="$SUITE_TMP/badutil.err"
printf '%s' '{"cwd":"/tmp","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"}}' \
  | env HOME="$BADUTIL_HOME" bash "$SCRIPT" >/dev/null 2>"$BADUTIL_ERR"
[ ! -s "$BADUTIL_ERR" ] \
  || fail "a non-numeric util leaked a printf error to stderr: $(head -2 "$BADUTIL_ERR")"

# =======================================================================
# SECURITY regression: a traversing project slug or session id must not
# produce a token_history path outside its project directory -- token-stats
# runs a `find ... -delete` sweep in that directory.
# =======================================================================
TRAV_HOME=$(fake_home)
TRAV_PROBE="$SUITE_TMP/traversal-argv"
rm -f "$TRAV_PROBE"
cat > "$TRAV_HOME/.claude/token-stats.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$TRAV_PROBE"
EOF
chmod +x "$TRAV_HOME/.claude/token-stats.sh"
run_statusline "$TRAV_HOME" "$(jq -n --arg t '/a/b/../sess.jsonl' \
  '{cwd:"/tmp",model:{display_name:"X"},workspace:{current_dir:"/tmp"},session_id:"s1",transcript_path:$t}')"
i=0; while [ "$i" -lt 20 ] && [ ! -f "$TRAV_PROBE" ]; do i=$((i+1)); /bin/sleep 0.05; done
if [ -f "$TRAV_PROBE" ]; then
  grep -q '\.\.' "$TRAV_PROBE" && fail "a traversing transcript path produced an out-of-tree cache path: $(cat "$TRAV_PROBE")"
fi
# A traversing session id is likewise rejected rather than passed through.
rm -f "$TRAV_PROBE"
run_statusline "$TRAV_HOME" "$(jq -n --arg t "$TRAV_HOME/.claude/projects/-p/s.jsonl" \
  '{cwd:"/tmp",model:{display_name:"X"},workspace:{current_dir:"/tmp"},session_id:"../../escape",transcript_path:$t}')"
i=0; while [ "$i" -lt 10 ] && [ ! -f "$TRAV_PROBE" ]; do i=$((i+1)); /bin/sleep 0.05; done
if [ -f "$TRAV_PROBE" ]; then
  grep -q '\.\.' "$TRAV_PROBE" && fail "a traversing session id produced an out-of-tree cache path: $(cat "$TRAV_PROBE")"
fi

# =======================================================================
# Regression: the PR/MR number comes from stdin and needs no git, so it
# must render even when the branch name is unavailable (detached HEAD,
# mid-rebase, non-repo cwd). It used to be nested inside the branch guard.
# =======================================================================
DETACH_REPO="$SUITE_TMP/detachrepo"
mkdir -p "$DETACH_REPO"
git init -q "$DETACH_REPO"
git -C "$DETACH_REPO" config user.email "test@example.com"
git -C "$DETACH_REPO" config user.name "Test"
git -C "$DETACH_REPO" commit -q --allow-empty -m one
git -C "$DETACH_REPO" commit -q --allow-empty -m two
git -C "$DETACH_REPO" checkout -q --detach HEAD~1
[ -z "$(git -C "$DETACH_REPO" branch --show-current)" ] || fail "detached-HEAD fixture is not actually detached"
DETACH_HOME=$(fake_home)
run_statusline "$DETACH_HOME" "$(jq -n --arg cwd "$DETACH_REPO" \
  '{cwd:$cwd,model:{display_name:"X"},workspace:{current_dir:$cwd},pr:{number:"123",url:"https://e/pull/123"}}')"
expect_match "(#123)"
# Same for a cwd that is not a git repo at all.
NONREPO_HOME=$(fake_home)
run_statusline "$NONREPO_HOME" '{"cwd":"/tmp","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"},"pr":{"number":"77","url":"https://e/pull/77"}}'
expect_match "(#77)"

# =======================================================================
# Regression: before the token cache exists, the Session breakdown must
# fall back to the current-response snapshot rather than printing zeros
# beside a real dollar figure (it read m_*/a_*, while the fallback was
# being written to variables nothing consumed).
# =======================================================================
FALLBACK_HOME=$(fake_home)
run_statusline "$FALLBACK_HOME" '{"cwd":"/tmp","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"},
  "cost":{"total_cost_usd":1.50},
  "context_window":{"context_window_size":1000000,"total_input_tokens":100000,"used_percentage":10,
    "current_usage":{"input_tokens":1234,"output_tokens":567,"cache_read_input_tokens":98000,"cache_creation_input_tokens":2000}}}'
expect_match '$1.50'
expect_not_match 'main $1.50 (0 in · 0 out · 0 cache-r · 0 cache-w)'
expect_match "1.2k in"

echo "statusline-command.test.sh: all assertions passed"
