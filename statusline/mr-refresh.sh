#!/usr/bin/env bash
# Cache the open GitLab MR for a branch, for the status line's (#MR) link.
# Usage: mr-refresh.sh <cwd> <branch>. Writes ~/.claude/.mr-cache.json {branch,number,url}.
# No-op (leaves cache untouched) if glab is missing or the lookup fails.
set -uo pipefail
cwd="${1:-$PWD}"
branch="${2:-}"
CACHE="$HOME/.claude/.mr-cache.json"
LOCK="$HOME/.claude/.mr-refresh.lock"
command -v glab >/dev/null 2>&1 || exit 0
[ -n "$branch" ] || exit 0

file_age() { m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0); echo $(($(date +%s) - m)); }

# Single-flight across sessions (atomic mkdir); clear a stale lock (>120s).
[ -d "$LOCK" ] && [ "$(file_age "$LOCK")" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Re-check under the lock: skip if a fresh cache for THIS branch already exists.
if [ -f "$CACHE" ] && [ "$(file_age "$CACHE")" -lt 600 ] \
    && [ "$(jq -r '.branch // empty' "$CACHE" 2>/dev/null)" = "$branch" ]; then
    exit 0
fi

json=$(cd "$cwd" 2>/dev/null && glab mr list --source-branch "$branch" --per-page 1 -F json 2>/dev/null) || exit 0
num=$(printf '%s' "$json" | jq -r '.[0].iid // empty' 2>/dev/null)
url=$(printf '%s' "$json" | jq -r '.[0].web_url // empty' 2>/dev/null)

# Always record the branch so the status line knows the lookup ran (empty number = no MR).
jq -n --arg b "$branch" --arg n "$num" --arg u "$url" \
    '{branch:$b, number:(if $n=="" then null else $n end), url:(if $u=="" then null else $u end)}' \
    >"$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE"
