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

# SECURITY: strip any userinfo from a remote URL before it becomes a cache
# identity. Credential-bearing HTTPS remotes are common (a PAT or CI token, e.g.
# https://TOKEN@gitlab.com/group/repo.git), and this value is persisted to disk
# as BOTH the JSON key and the `repo` field — writing the raw URL copies the
# token into a long-lived, predictably-named cache file. The `@` is only removed
# from the AUTHORITY component: an `@` can legitimately appear in a path, and
# cutting there would mangle unrelated identities. Reader and writer must derive
# this identically or every lookup misses, so statusline-command.sh carries the
# same function.
sanitize_repo_id() {
    case "$1" in
    *://*)
        # scheme://[user[:pass]@]host[:port]/path
        local scheme rest authority path
        scheme=${1%%://*}
        rest=${1#*://}
        authority=${rest%%/*}
        path=${rest#"$authority"}
        authority=${authority##*@}   # longest match, so user:pa@ss@host -> host
        printf '%s://%s%s' "$scheme" "$authority" "$path" ;;
    *@*:*)
        # scp-like [user@]host:path — userinfo sits before the first ':'
        local pre post
        pre=${1%%:*}
        post=${1#*:}
        pre=${pre##*@}
        printf '%s:%s' "$pre" "$post" ;;
    *)
        printf '%s' "$1" ;;
    esac
}

# Repo identity: the cache is a single file shared by every project, so two
# different repos with the same branch name must not be treated as the same
# entry. Prefer the origin remote URL (stable across worktrees / clone paths
# of the same repo); fall back to the repo root path for a repo with no
# remote configured.
repo_id=$(git -C "$cwd" --no-optional-locks remote get-url origin 2>/dev/null)
[ -z "$repo_id" ] && repo_id=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
repo_id=$(sanitize_repo_id "$repo_id")

# The cache can carry repo identities and MR URLs; keep it owner-only rather
# than whatever the ambient umask yields (observed 0644). Applies to the lock
# directory and the temp file below too, and `mv` carries the temp file's mode
# onto the cache, so an existing 0644 file is replaced by a 0600 one.
umask 077

key="$repo_id"$'\t'"$branch"
now=$(date +%s)

file_age() { m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0); echo $(($(date +%s) - m)); }

# Single-flight across sessions (atomic mkdir), with the holder's PID recorded
# in an `owner` file. A purely time-based staleness check is unsafe on both
# sides: it lets a slow-but-LIVE lookup have its lock stolen, and then that
# process's unconditional `rmdir` trap deletes the newer holder's lock,
# admitting a third and racing them all on the cache temp file. `glab` does
# network I/O, so exceeding a fixed threshold is realistic, not theoretical.
# Reclaim only when the owner is gone; release only while we still own it.
LOCK_GRACE=120  # lock exists but no owner recorded (killed between mkdir and write)
LOCK_HARD=3600  # owner looks alive but the lock is impossibly old -> assume PID reuse
lock_owner() { cat "$LOCK/owner" 2>/dev/null; }
lock_acquire() {
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s' "$$" >"$LOCK/owner" 2>/dev/null
        return 0
    fi
    owner=$(lock_owner)
    age=$(file_age "$LOCK")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$age" -lt "$LOCK_HARD" ]; then
        return 1
    fi
    if [ -z "$owner" ] && [ "$age" -lt "$LOCK_GRACE" ]; then
        return 1
    fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || return 1
    printf '%s' "$$" >"$LOCK/owner" 2>/dev/null
    return 0
}
lock_release() {
    [ "$(lock_owner)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
    return 0
}
lock_acquire || exit 0
trap lock_release EXIT

# Re-check under the lock: skip only if THIS repo+branch's own entry is still
# fresh -- freshness is per-entry (its own "ts" field), not file mtime, since
# another session's write to a different key also bumps the file's mtime.
if [ -f "$CACHE" ]; then
    entry_ts=$(jq -r --arg k "$key" '.[$k].ts // empty' "$CACHE" 2>/dev/null)
    if [ -n "$entry_ts" ] && [ $((now - entry_ts)) -lt "$MAX_AGE" ]; then
        exit 0
    fi
fi

# Bound the lookup so a hung `glab` cannot sit on the lock indefinitely.
# `timeout` is GNU coreutils and is NOT on a stock macOS, so use it only when
# present (gtimeout via Homebrew counts) and run bare otherwise — the
# owner-aware lock above is what keeps a hang from blocking other sessions.
timeout_cmd=""
for t in timeout gtimeout; do
    command -v "$t" >/dev/null 2>&1 && { timeout_cmd="$t"; break; }
done
json=$(cd "$cwd" 2>/dev/null && ${timeout_cmd:+$timeout_cmd 30} glab mr list --source-branch "$branch" --per-page 1 -F json 2>/dev/null) || exit 0
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
    # Actively drop entries whose identity carries URL userinfo. Versions before
    # the sanitization above stored the raw remote, so an existing cache can
    # already hold a token; age-based pruning alone would leave it readable for
    # up to PRUNE_AGE. A sanitized identity never contains userinfo, so any
    # entry that does is stale-by-construction and safe to discard.
    def credentialBearing:
      test("^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]*@")   # scheme://user@host/...
      or test("^[^/:]*@[^/]*:");                  # scp-like user@host:path
    ($existing
      | with_entries(select(
          ((.key | credentialBearing) | not)
          and (((.value.repo // "") | credentialBearing) | not)
          and ((.value.ts // 0) as $t | ($now - $t) < $prune)))) as $pruned |
    $pruned + {($k): {repo:$r, branch:$b, number:(if $n=="" then null else $n end), url:(if $u=="" then null else $u end), ts:$now}}
' >"$CACHE.tmp.$$" 2>/dev/null && mv "$CACHE.tmp.$$" "$CACHE"
