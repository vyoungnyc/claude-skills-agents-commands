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
run_statusline() {
  local home="$1" json="$2" extra_path="${3:-}"
  local path="$PATH"
  [ -n "$extra_path" ] && path="$extra_path:$PATH"
  LAST_OUT=$(printf '%s' "$json" | env HOME="$home" PATH="$path" bash "$SCRIPT")
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
jq -n '{branch:"feature/widget", repo:"/some/other/repo-not-this-one", number: "55", url: "https://example.com/mr/55"}' \
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
jq -n --arg repo "$GIT_REPO" '{branch:"feature/widget", repo:$repo, number: "77", url: "https://example.com/mr/77"}' \
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

echo "statusline-command.test.sh: all assertions passed"
