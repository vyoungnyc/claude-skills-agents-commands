#!/usr/bin/env bash
# Fetch account usage/credit data from the endpoint the /usage command uses.
# Reads the OAuth token from ~/.claude/.credentials.json or the macOS Keychain.
# Token is never printed; only the API response body is emitted on stdout.
set -uo pipefail

get_token() {
    if [ -f "$HOME/.claude/.credentials.json" ]; then
        jq -r '.claudeAiOauth.accessToken // .accessToken // .oauth.accessToken // empty' \
            "$HOME/.claude/.credentials.json" 2>/dev/null && return 0
    fi
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
