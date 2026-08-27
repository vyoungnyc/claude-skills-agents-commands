#!/usr/bin/env bash
# Fetch account usage/credit data from the endpoint the /usage command uses.
# Reads the OAuth token from ~/.claude/.credentials.json or the macOS Keychain.
# Token is never printed; only the API response body is emitted on stdout.
set -uo pipefail

# Which Claude home this script was DEPLOYED into (same resolution order as
# statusline-command.sh: explicit CLAUDE_HOME, else this script's own directory
# when a sibling settings.json marks it as a deployed Claude home, else
# $HOME/.claude). Checked BEFORE the default home below, so an alternate-home
# install reads its own credentials rather than the default home's.
resolve_claude_home() {
    if [ -n "${CLAUDE_HOME:-}" ]; then printf '%s' "$CLAUDE_HOME"; return; fi
    local d
    d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || d=""
    if [ -n "$d" ] && [ -f "$d/settings.json" ]; then printf '%s' "$d"; return; fi
    printf '%s' "$HOME/.claude"
}
CLAUDE_DIR=$(resolve_claude_home)

get_token() {
    # Try the deployed home first, then the default home — an alternate-home
    # deploy may hold config only, with the OAuth login still in $HOME/.claude.
    for creds in "$CLAUDE_DIR/.credentials.json" "$HOME/.claude/.credentials.json"; do
        [ -f "$creds" ] || continue
        # jq exits 0 on a valid-JSON file even when none of the token fields
        # are present (the `// empty` just yields an empty string) — only
        # return early on an actual non-empty token, or a present-but-empty
        # credentials file permanently blocks the Keychain fallback below.
        file_tok=$(jq -r '.claudeAiOauth.accessToken // .accessToken // .oauth.accessToken // empty' \
            "$creds" 2>/dev/null)
        if [ -n "$file_tok" ] && [ "$file_tok" != "null" ]; then
            printf '%s' "$file_tok"
            return 0
        fi
    done
    if command -v security >/dev/null 2>&1; then
        security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
            | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null
    fi
}

tok=$(get_token)
if [ -z "${tok:-}" ] || [ "$tok" = "null" ]; then
    echo "ERROR: no OAuth token found (checked ~/.claude/.credentials.json and Keychain)" >&2
    exit 1
fi

url="${1:-https://api.anthropic.com/api/oauth/usage}"

# Retry transient throttling/5xx a few times, honoring Retry-After. Emits the last
# response body + __HTTP_STATUS__ line on stdout; caller decides whether to trust it.
attempt=0
max=3
while :; do
    attempt=$((attempt + 1))
    resp=$(curl -sS -D /tmp/.usage-hdrs.$$ -w '\n__HTTP_STATUS__%{http_code}\n' "$url" \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/plain, */*" \
        -H "User-Agent: claude-code/2.1.246")
    code=$(printf '%s' "$resp" | sed -n 's/^__HTTP_STATUS__//p')
    if [ "$code" = "429" ] || [ "$code" -ge 500 ] 2>/dev/null; then
        if [ "$attempt" -lt "$max" ]; then
            ra=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]*\).*/\1/p' /tmp/.usage-hdrs.$$ 2>/dev/null | head -1)
            [ -z "$ra" ] && ra=$((attempt * 2))
            [ "$ra" -gt 30 ] 2>/dev/null && ra=30
            sleep "$ra"
            continue
        fi
    fi
    rm -f /tmp/.usage-hdrs.$$ 2>/dev/null
    printf '%s\n' "$resp"
    break
done
