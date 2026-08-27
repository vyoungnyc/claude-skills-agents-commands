#!/usr/bin/env bash
# Cache the open GitLab MR for a branch, for the status line's (#MR) link.
# Usage: mr-refresh.sh <cwd> <branch>. Writes ~/.claude/.mr-cache.json: a
# single JSON object keyed by "<repo_id>\t<branch>", one entry per repo+
# branch pair -- so two concurrent sessions (different repos, or different
# branches of the same repo) each own their own slot instead of overwriting
# one shared entry and fighting over freshness.
# No-op (leaves cache untouched) if glab is missing or the lookup fails.
set -uo pipefail
cwd="${1:-$PWD}"
branch="${2:-}"
# Which Claude home this script was DEPLOYED into, so an install under an
# alternate CLAUDE_HOME keeps its cache/lock beside itself instead of in the
# DEFAULT home. Same resolution order as statusline-command.sh: explicit
# CLAUDE_HOME, else this script's own directory when a sibling settings.json
# marks it as a deployed Claude home, else $HOME/.claude.
resolve_claude_home() {
    if [ -n "${CLAUDE_HOME:-}" ]; then printf '%s' "$CLAUDE_HOME"; return; fi
    local d
    d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || d=""
    if [ -n "$d" ] && [ -f "$d/settings.json" ]; then printf '%s' "$d"; return; fi
    printf '%s' "$HOME/.claude"
}
CLAUDE_DIR=$(resolve_claude_home)
CACHE="$CLAUDE_DIR/.mr-cache.json"
LOCK="$CLAUDE_DIR/.mr-refresh.lock"
MAX_AGE=600      # per-entry freshness window (seconds)
PRUNE_AGE=86400  # entries older than this are dropped on write, to bound file growth
command -v glab >/dev/null 2>&1 || exit 0
[ -n "$branch" ] || exit 0

# Repo identity: the cache is a single file shared by every project, so two
# different repos with the same branch name must not be treated as the same
# entry. Prefer the origin remote URL (stable across worktrees / clone paths
# of the same repo); fall back to the repo root path for a repo with no
# remote configured.
repo_id=$(git -C "$cwd" --no-optional-locks remote get-url origin 2>/dev/null)
[ -z "$repo_id" ] && repo_id=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)

key="$repo_id"$'\t'"$branch"
now=$(date +%s)

file_age() { m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0); echo $(($(date +%s) - m)); }

# Single-flight across sessions (atomic mkdir); clear a stale lock (>120s).
[ -d "$LOCK" ] && [ "$(file_age "$LOCK")" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Re-check under the lock: skip only if THIS repo+branch's own entry is still
# fresh -- freshness is per-entry (its own "ts" field), not file mtime, since
# another session's write to a different key also bumps the file's mtime.
if [ -f "$CACHE" ]; then
    entry_ts=$(jq -r --arg k "$key" '.[$k].ts // empty' "$CACHE" 2>/dev/null)
    if [ -n "$entry_ts" ] && [ $((now - entry_ts)) -lt "$MAX_AGE" ]; then
        exit 0
    fi
fi

json=$(cd "$cwd" 2>/dev/null && glab mr list --source-branch "$branch" --per-page 1 -F json 2>/dev/null) || exit 0
num=$(printf '%s' "$json" | jq -r '.[0].iid // empty' 2>/dev/null)
url=$(printf '%s' "$json" | jq -r '.[0].web_url // empty' 2>/dev/null)

# Merge this repo+branch's entry into the existing cache object -- never
# replace the whole file, since other repo/branch entries must survive --
# pruning anything old enough to just be noise. If the existing file is
# missing, corrupt, or in the old (pre-keyed) flat shape, treat it as empty:
# a `.value` that isn't itself an object (as every old flat top-level value
# was) fails the type check below and the whole file is discarded rather
# than carried forward malformed.
existing="{}"
if [ -f "$CACHE" ]; then
    candidate=$(jq -c 'if (type == "object") and ([.[] | type] | all(. == "object")) then . else {} end' "$CACHE" 2>/dev/null) \
        && [ -n "$candidate" ] && existing="$candidate"
fi
jq -n --argjson existing "$existing" --arg k "$key" --arg r "$repo_id" --arg b "$branch" \
    --arg n "$num" --arg u "$url" --argjson now "$now" --argjson prune "$PRUNE_AGE" '
    ($existing | with_entries(select((.value.ts // 0) as $t | ($now - $t) < $prune))) as $pruned |
    $pruned + {($k): {repo:$r, branch:$b, number:(if $n=="" then null else $n end), url:(if $u=="" then null else $u end), ts:$now}}
' >"$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"
