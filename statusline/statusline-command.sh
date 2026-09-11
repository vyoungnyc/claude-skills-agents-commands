#!/usr/bin/env bash
# Claude Code status line.
# Layout:  <model> <repo/dir> <branch> | Context: NNk/NNM NN% | <limits/api-usage>
#
# Last group depends on plan:
#   API/credit billing only : [API Usage]: $used / $limit (NN%) resets <date>
#   Max/Pro only            : Limits: 5h (NN%) resets in Xh · 7d (NN%) resets <clock>
#   Max/Pro + API usage     : Limits: 5h ... · 7d ... · [API Usage] $used / $limit (NN%) resets <date>
#
# Data sources:
#   - model / dir / branch / Context : the status-line JSON on stdin (context_window.total_input_tokens,
#     .context_window_size, .used_percentage).
#   - Limits (5h/7d) AND [API Usage] credits : NOT in the JSON. Both read from ~/.claude/usage-cache.json,
#     which usage-refresh.sh populates from api.anthropic.com/api/oauth/usage using the OAuth token
#     (that endpoint returns five_hour/seven_day.{utilization,resets_at} — null unless on Max/Pro — plus
#     spend credits). The status line reads the cache (fast) and kicks a background refresh when stale.

# Which Claude home this script was DEPLOYED into. The sync script supports
# installing to an explicit alternate CLAUDE_HOME and rewrites the entrypoint
# path in settings.json accordingly — but every cache and helper path below
# used to be hardcoded to $HOME/.claude, so an alternate-home install started
# correctly and then read the DEFAULT home's caches and looked for its helper
# scripts (mr-refresh.sh, token-stats.sh, usage-refresh.sh) somewhere they
# were never installed: usage, token, and MR data never refreshed.
# Resolution order:
#   1. An explicit CLAUDE_HOME in the environment always wins.
#   2. Else this script's own directory, when it looks like a deployed Claude
#      home — the sync script lands statusline scripts FLAT in CLAUDE_HOME,
#      so a sibling settings.json means "I am installed in a Claude home".
#   3. Else $HOME/.claude — the default install, and the repo checkout, where
#      these scripts live in statusline/ with no sibling settings.json.
resolve_claude_home() {
    if [ -n "${CLAUDE_HOME:-}" ]; then printf '%s' "$CLAUDE_HOME"; return; fi
    local d
    d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || d=""
    if [ -n "$d" ] && [ -f "$d/settings.json" ]; then printf '%s' "$d"; return; fi
    printf '%s' "$HOME/.claude"
}
CLAUDE_DIR=$(resolve_claude_home)

# Strip any userinfo from a git remote URL before using it as an MR-cache
# identity. Must stay byte-for-byte equivalent to mr-refresh.sh's copy: that
# script writes the cache key, this one looks it up, so any divergence turns
# every lookup into a miss. Only the authority component is cut, because an
# `@` can legitimately appear in a URL path.
sanitize_repo_id() {
    case "$1" in
    *://*)
        local scheme rest authority path
        scheme=${1%%://*}
        rest=${1#*://}
        authority=${rest%%/*}
        path=${rest#"$authority"}
        authority=${authority##*@}
        printf '%s://%s%s' "$scheme" "$authority" "$path" ;;
    *@*:*)
        local pre post
        pre=${1%%:*}
        post=${1#*:}
        pre=${pre##*@}
        printf '%s:%s' "$pre" "$post" ;;
    *)
        printf '%s' "$1" ;;
    esac
}

input=$(cat)
# Validate the payload ONCE. Every field read below is its own `jq` call, so
# an unparseable payload otherwise produced ~26 `jq: parse error` lines on
# stderr -- straight into the user's terminal, on every ~30s render. Falling
# back to an empty object degrades to a minimal status line instead, which is
# the right failure mode for a cosmetic component.
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    input='{}'
fi
now=$(date +%s)
model=$(echo "$input" | jq -r '.model.display_name // empty')
[ -n "$model" ] || model="?"
session_id=$(echo "$input" | jq -r '.session_id // empty')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
fast=$(echo "$input" | jq -r '.fast_mode // false')
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
worktree=$(echo "$input" | jq -r '.worktree.name // .workspace.git_worktree // empty')
repo_host=$(echo "$input" | jq -r '.workspace.repo.host // empty')
repo_owner=$(echo "$input" | jq -r '.workspace.repo.owner // empty')
repo_name=$(echo "$input" | jq -r '.workspace.repo.name // empty')
pr=$(echo "$input" | jq -r '.pr.number // empty')
pr_url=$(echo "$input" | jq -r '.pr.url // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
# An empty cwd would make every `git -C ""` a no-op against the PROCESS's own
# directory, so the status line would confidently show an unrelated repo with
# a live hyperlink. Fall back explicitly instead.
[ -n "$cwd" ] || cwd="$PWD"

# OSC 8 terminal hyperlink: hlink <url> <text>. Renders as plain text where unsupported.
hlink() { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }

# repo/dir: git repo-root basename + relative subpath; plain cwd basename outside a repo
dir=""
if root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null); then
    repo=$(basename "$root")
    rel=${cwd#"$root"}
    rel=${rel#/}
    if [ -n "$rel" ]; then dir="$repo/$rel"; else dir="$repo"; fi
else
    dir=$(basename "$cwd")
fi

# branch (+ PR/MR # if the JSON carries it — GitHub-shaped; usually empty on GitLab)
branch=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
fi

ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctxused=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctxtotal=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
cu_in=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // empty')
cu_out=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // empty')
cu_cw=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')
cu_cr=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')

# context total -> "NNk" / "N.NM" (raw under 1000)
kfmt() { awk -v t="$1" 'BEGIN{ if (t>=1000000) printf "%gM", t/1000000; else if (t>=1000) printf "%.0fk", t/1000; else printf "%d", t }'; }

# token breakdown -> one-decimal "4.8k" / "15.0m" (raw under 1000)
tfmt() { awk -v t="$1" 'BEGIN{ if (t>=1000000) printf "%.1fm", t/1000000; else if (t>=1000) printf "%.1fk", t/1000; else printf "%d", t }'; }

# date helpers: GNU (-d @epoch) first, BSD (-r epoch) fallback
_dfmt() {
    o=$(date -d "@$1" "$2" 2>/dev/null) || o=""
    [ -z "$o" ] && o=$(date -r "$1" "$2" 2>/dev/null)
    printf '%s' "$o" | sed -e 's/  */ /g' -e 's/^ //' -e 's/AM/am/g' -e 's/PM/pm/g'
}

# Coerce a value to a non-negative integer, else 0. Every arithmetic sink in this
# file reads from a JSON cache or the stdin payload, and bash `$(( ))` evaluates
# the VALUE as an arithmetic expression -- so a non-numeric value is not merely
# wrong, it is executable: `x[$(cmd)]` runs `cmd` via the array-subscript rule.
# Also stops "value too great for base" / "invalid number" errors leaking to the
# terminal and stops a bare word silently evaluating to 0 ("resets in 0m" lie).
# Leading zeros are stripped because bash reads them as OCTAL inside $(( )):
# `$((08))` is "value too great for base", the same stderr noise this guard
# exists to prevent. `10#` prefixing would work too but does not survive being
# passed around as a plain value.
int_or0() {
    case "${1:-}" in ''|*[!0-9]*) printf '0'; return ;; esac
    _v="${1#"${1%%[!0]*}"}"   # drop leading zeros
    printf '%s' "${_v:-0}"
}

# mtime in epoch seconds, or 0. Validates that the output is NUMERIC instead of
# trusting exit status: GNU `stat -f` means --file-system, so with GNU coreutils
# ahead of /usr/bin (common on macOS via Homebrew) the fallback exits ZERO and
# prints a multi-line filesystem report on stdout, meaning `|| echo 0` never
# fires and the caller does arithmetic on junk.
mtime_or0() {
    _m=$(stat -c %Y "$1" 2>/dev/null)
    case "$_m" in ''|*[!0-9]*) _m=$(stat -f %m "$1" 2>/dev/null) ;; esac
    case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
    printf '%s' "$_m"
}

# Unified reset formatter, granularity by distance from now:
#   <24h  -> relative   "in 2h02m" / "in 45m"
#   <7d   -> weekday+clock "Sat 6:00pm"
#   else  -> date       "Tue Sep 1"
fmt_reset() {
    epoch=$(int_or0 "$1")
    [ "$epoch" -eq 0 ] && { printf 'unknown'; return; }
    d=$((epoch - now))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -lt 86400 ]; then
        if [ "$d" -ge 3600 ]; then
            printf "in %dh%02dm" $((d / 3600)) $(((d % 3600) / 60))
        else
            printf "in %dm" $((d / 60))
        fi
    elif [ "$d" -lt 604800 ]; then
        _dfmt "$(((epoch + 30) / 60 * 60))" "+%a %l:%M%p"
    else
        _dfmt "$epoch" "+%a %b %-d"
    fi
}

# severity -> ANSI color; empty severity falls back to a percentage threshold.
# normal=magenta(limits)/cyan(credits via arg3), warning=yellow, critical=red.
sev_color() {
    sev=$1
    pct=$2
    base=${3:-"\e[01;35m"}
    case "$sev" in
    critical) printf '\e[01;31m' ;;
    warning) printf '\e[01;33m' ;;
    normal) printf '%b' "$base" ;;
    *) if [ "${pct:-0}" -ge 80 ] 2>/dev/null; then printf '\e[01;31m'; elif [ "${pct:-0}" -ge 50 ] 2>/dev/null; then printf '\e[01;33m'; else printf '%b' "$base"; fi ;;
    esac
}

# [⚡Model · effort]
mstr="$model"
[ -n "$effort" ] && mstr="$mstr · $effort"
[ "$fast" = "true" ] && mstr="⚡$mstr"
out=$(printf "\e[01;36m[%s]\e[00m" "$mstr")

# repo root URL: prefer JSON workspace.repo; else parse `git remote origin`
# (JSON is null on GitLab for this user). Used to make the repo NAME clickable.
repo_url=""
if [ -n "$repo_host" ] && [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
    repo_url="https://$repo_host/$repo_owner/$repo_name"
else
    ru=$(git -C "$cwd" --no-optional-locks remote get-url origin 2>/dev/null)
    ru=${ru%.git}
    case "$ru" in
    git@*) rhost=${ru#git@}; rhost=${rhost%%:*}; rpath=${ru#*:} ;;
    *://*) rest=${ru#*://}; rest=${rest#*@}; rhost=${rest%%/*}; rpath=${rest#*/} ;;
    *) rhost=""; rpath="" ;;
    esac
    [ -n "$rhost" ] && [ -n "$rpath" ] && repo_url="https://$rhost/$rpath"
fi

# 📁 <repo-name, clickable to repo root>
dtext=$(printf "\e[01;34m%s\e[00m" "$dir")
[ -n "$repo_url" ] && dtext=$(hlink "$repo_url" "$dtext")
out="$out  $(printf "📁 %s" "$dtext")"

# (#N), hyperlinked when a URL is known. Used both beside a branch name and
# standalone when no branch is available.
pr_badge() {
    _t=$(printf "\e[01;33m(#%s)\e[00m" "$1")
    [ -n "${2:-}" ] && _t=$(hlink "$2" "$_t")
    printf '%s' "$_t"
}

# | 🌿 branch [(#PR/MR)] [🌲worktree] — branch is plain; PR/MR number links out.
# The PR/MR number is resolved OUTSIDE the branch guard: `.pr.number` comes from
# the stdin JSON and needs no git, so a detached HEAD, a mid-rebase checkout or a
# non-repo cwd must not silently discard it. Only the branch NAME depends on git.
num=""; nurl=""
if [ -n "$pr" ]; then
    num="$pr"; nurl="$pr_url"
fi
if [ -n "$branch" ]; then
    bseg=$(printf "\e[01;33m%s\e[00m" "$branch")
    # MR lookup is legitimately branch-scoped: the cache is keyed by branch.
    if [ -z "$num" ] && command -v glab >/dev/null 2>&1; then
        MRCACHE="$CLAUDE_DIR/.mr-cache.json"
        MRREFRESH="$CLAUDE_DIR/mr-refresh.sh"
        # Repo identity, same derivation as mr-refresh.sh. The cache is one
        # file shared by every session, keyed by "<repo>\t<branch>" so this
        # session only ever reads/triggers-refresh-for its own entry -- a
        # concurrent session on a different repo or branch has its own slot
        # and can't mark this one fresh, stale, or overwrite it.
        mr_repo_id=$(git -C "$cwd" --no-optional-locks remote get-url origin 2>/dev/null)
        [ -z "$mr_repo_id" ] && mr_repo_id=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
        # Strip URL userinfo, exactly as mr-refresh.sh does when it writes the
        # key: a credential-bearing remote (https://TOKEN@host/...) must not be
        # persisted into the cache, and reader and writer have to derive the
        # same identity or every lookup misses. The `@` is only cut from the
        # authority component, since an `@` can legitimately appear in a path.
        mr_repo_id=$(sanitize_repo_id "$mr_repo_id")
        if [ -n "$mr_repo_id" ]; then
            mr_key="$mr_repo_id"$'\t'"$branch"
            if [ -x "$MRREFRESH" ]; then
                mrstale=1
                if [ -f "$MRCACHE" ]; then
                    # Freshness is this entry's own "ts" field, not file mtime
                    # -- another session's write to a different key also
                    # bumps mtime without making THIS entry any fresher.
                    # A `failed` entry (glab auth/network/host error) counts as
                    # fresh for a SHORTER window: without honoring it at all we
                    # would relaunch the failing lookup on every render, and
                    # treating it as fresh for the full window would hide a real
                    # MR long after a transient failure cleared. Both windows
                    # must match mr-refresh.sh's MAX_AGE / FAIL_COOLDOWN.
                    mr_entry=$(jq -r --arg k "$mr_key" '(.[$k] // {}) | "\(.ts // "")\t\(if .failed then 1 else 0 end)"' "$MRCACHE" 2>/dev/null)
                    entry_ts=$(int_or0 "${mr_entry%%$'\t'*}")
                    entry_failed=${mr_entry##*$'\t'}
                    mr_window=600
                    [ "$entry_failed" = "1" ] && mr_window=120
                    [ -n "$entry_ts" ] && [ $((now - entry_ts)) -lt "$mr_window" ] && mrstale=0
                fi
                [ "$mrstale" -eq 1 ] && ("$MRREFRESH" "$cwd" "$branch" >/dev/null 2>&1 &)
            fi
            if [ -f "$MRCACHE" ]; then
                num=$(jq -r --arg k "$mr_key" '.[$k].number // empty' "$MRCACHE" 2>/dev/null)
                nurl=$(jq -r --arg k "$mr_key" '.[$k].url // empty' "$MRCACHE" 2>/dev/null)
            fi
        fi
    fi
    if [ -n "$num" ]; then
        bseg="$bseg $(pr_badge "$num" "$nurl")"
    fi
    out="$out | $(printf "🌿 %s" "$bseg")"
elif [ -n "$num" ]; then
    # No branch name available (detached HEAD, mid-rebase, non-repo cwd) but the
    # harness gave us a PR number: still show it rather than dropping the link.
    out="$out | $(pr_badge "$num" "$nurl")"
fi
[ -n "$worktree" ] && out="$out $(printf "\e[01;35m🌲%s\e[00m" "$worktree")"

# --- transcript-derived stats (cumulative session tokens + robust context length) ---
# token-stats.sh sums EVERY usage entry (incl. subagent/sidechain turns, any model) for the
# cumulative counts, and takes context_length from the newest MAIN-CHAIN entry by timestamp
# (parallel subtasks land out of order, so file order is unreliable). Cached per session,
# single-flight, refreshed in the background when >15s stale.
#
# Cache path: ~/.claude/token_history/<project-slug>/<session_id>.json — one subdirectory
# per project so sessions from different repos don't pile up together in ~/.claude/ root.
# project-slug reuses Claude Code's own transcript directory naming (transcript_path is
# ~/.claude/projects/<project-slug>/<session_id>.jsonl), so no separate repo lookup is needed.
TSTATS=""
if [ -n "$session_id" ] && [ -n "$transcript" ]; then
    project_slug=$(basename "$(dirname "$transcript")")
    # Both components land in a filesystem path that token-stats.sh then runs a
    # `find ... -delete` sweep inside, so neither may contain a traversal or a
    # separator. `basename` of a path like /a/b/../s.jsonl yields `..`, which
    # would escape token_history/ into the Claude home root where settings.json
    # lives. Reject anything outside a conservative charset rather than trying
    # to sanitise it.
    case "$project_slug" in
        ''|.|..|*/*|*'\'*) project_slug="" ;;
    esac
    case "$session_id" in
        ''|.|..|*/*|*'\'*) session_id="" ;;
    esac
    if [ -n "$project_slug" ] && [ -n "$session_id" ]; then
        TSTATS="$CLAUDE_DIR/token_history/$project_slug/$session_id.json"
    fi
fi
TSREFRESH="$CLAUDE_DIR/token-stats.sh"
if [ -n "$TSTATS" ] && [ -n "$transcript" ] && [ -x "$TSREFRESH" ]; then
    tsstale=1
    if [ -f "$TSTATS" ]; then
        tmt=$(mtime_or0 "$TSTATS")
        [ $((now - tmt)) -lt 15 ] && tsstale=0
    fi
    [ "$tsstale" -eq 1 ] && ("$TSREFRESH" "$transcript" "$TSTATS" >/dev/null 2>&1 &)
fi
# Cumulative counts + context length from the cache. Until the cache exists the
# main-chain numbers fall back to the CURRENT-RESPONSE snapshot from stdin, so
# the Session line never shows a real dollar amount beside fabricated zeros --
# which it did while the fallback was being written to `t_in`/`t_out`/`t_cr`/
# `t_cw`, variables the Session segment does not read (orphaned when the
# standalone Tokens segment was removed). Agents have no stdin equivalent, so
# they legitimately start at 0.
m_in=$(int_or0 "${cu_in:-0}"); m_out=$(int_or0 "${cu_out:-0}")
m_cr=$(int_or0 "${cu_cr:-0}");  m_cw=$(int_or0 "${cu_cw:-0}")
t_ctx=""; m_cost=""; a_cost=""; a_in=0; a_out=0; a_cr=0; a_cw=0
if [ -n "$TSTATS" ] && [ -f "$TSTATS" ]; then
    t_ctx=$(jq -r '.context_length // empty' "$TSTATS" 2>/dev/null)
    m_cost=$(jq -r '.main.est_cost // empty' "$TSTATS" 2>/dev/null)
    a_cost=$(jq -r '.agents.est_cost // empty' "$TSTATS" 2>/dev/null)
    m_in=$(jq -r '.main.input // 0' "$TSTATS" 2>/dev/null)
    m_out=$(jq -r '.main.output // 0' "$TSTATS" 2>/dev/null)
    m_cr=$(jq -r '.main.cache_read // 0' "$TSTATS" 2>/dev/null)
    m_cw=$(jq -r '.main.cache_write // 0' "$TSTATS" 2>/dev/null)
    a_in=$(jq -r '.agents.input // 0' "$TSTATS" 2>/dev/null)
    a_out=$(jq -r '.agents.output // 0' "$TSTATS" 2>/dev/null)
    a_cr=$(jq -r '.agents.cache_read // 0' "$TSTATS" 2>/dev/null)
    a_cw=$(jq -r '.agents.cache_write // 0' "$TSTATS" 2>/dev/null)
fi

# Session cost segment. Real billed total (cost.total_cost_usd) apportioned main/agents by the
# list-price est ratio; per-chain tokens as "IN in · OUT out · CR cache-r · CW cache-w".
# The (NN% cached) prefix is the LAST response's hit rate (current_usage), colored.
# Falls back to raw ~est dollars if the JSON carries no total.
hit=$(awk -v r="${cu_cr:-0}" -v w="${cu_cw:-0}" -v i="${cu_in:-0}" 'BEGIN{d=r+w+i; if(d>0) printf "%d", (r/d)*100; else print ""}')
cached_prefix=""
if [ -n "$hit" ]; then
    hc="\e[01;31m"
    [ "$hit" -ge 70 ] 2>/dev/null && hc="\e[01;33m"
    [ "$hit" -ge 90 ] 2>/dev/null && hc="\e[01;32m"
    cached_prefix=$(printf "${hc}(%s%% cached)\e[00m " "$hit")
fi
session_seg=""
SESSION_AWK='
    function tf(t){ if(t>=1000000) return sprintf("%.1fm",t/1000000); else if(t>=1000) return sprintf("%.1fk",t/1000); else return sprintf("%d",t) }
    function chain(ti,to,tcr,tcw){ return sprintf("%s in · %s out · %s cache-r · %s cache-w", tf(ti), tf(to), tf(tcr), tf(tcw)) }'
if [ -n "$total_cost" ]; then
    body=$(awk -v tot="$total_cost" -v mc="${m_cost:-0}" -v ac="${a_cost:-0}" \
        -v mi="$m_in" -v mo="$m_out" -v mcr="$m_cr" -v mcw="$m_cw" \
        -v ai="$a_in" -v ao="$a_out" -v acr="$a_cr" -v acw="$a_cw" "$SESSION_AWK"'
        BEGIN{ d=mc+ac; if(d>0){mr=mc/d}else{mr=1}; ms=tot*mr; as=tot-ms;
               printf "$%.2f — main $%.2f (%s) · agents $%.2f (%s)", tot, ms, chain(mi,mo,mcr,mcw), as, chain(ai,ao,acr,acw) }')
    session_seg=$(printf "Session: %s\e[33m%s\e[00m" "$cached_prefix" "$body")
elif [ -n "$m_cost" ] || [ -n "$a_cost" ]; then
    body=$(awk -v mc="${m_cost:-0}" -v ac="${a_cost:-0}" \
        -v mi="$m_in" -v mo="$m_out" -v mcr="$m_cr" -v mcw="$m_cw" \
        -v ai="$a_in" -v ao="$a_out" -v acr="$a_cr" -v acw="$a_cw" "$SESSION_AWK"'
        BEGIN{ printf "~est: main $%.2f (%s) · agents $%.2f (%s)", mc, chain(mi,mo,mcr,mcw), ac, chain(ai,ao,acr,acw) }')
    session_seg=$(printf "Session %s\e[33m%s\e[00m" "$cached_prefix" "$body")
fi

# context: prefer transcript-derived context length (newest main-chain entry); JSON fallback.
clen=""; cpct=""
if [ -n "$t_ctx" ] && [ "$t_ctx" -gt 0 ] 2>/dev/null; then
    clen="$t_ctx"
    [ -n "$ctxtotal" ] && [ "$ctxtotal" -gt 0 ] 2>/dev/null && cpct=$(awk -v c="$t_ctx" -v t="$ctxtotal" 'BEGIN{printf "%d", (c/t)*100}')
elif [ -n "$ctxused" ]; then
    clen="$ctxused"
fi
[ -z "$cpct" ] && [ -n "$ctx" ] && cpct=$(printf "%.0f" "$ctx" 2>/dev/null)
case "$cpct" in ''|*[!0-9]*) cpct="" ;; esac
if [ -n "$cpct" ] || [ -n "$clen" ]; then
    cc="\e[01;32m"
    [ -n "$cpct" ] && [ "$cpct" -ge 80 ] 2>/dev/null && cc="\e[01;31m"
    toks=""
    if [ -n "$clen" ] && [ -n "$ctxtotal" ]; then
        toks="$(kfmt "$clen")/$(kfmt "$ctxtotal")"
    elif [ -n "$clen" ]; then
        toks="$(kfmt "$clen")"
    fi
    if [ -n "$toks" ] && [ -n "$cpct" ]; then
        out="$out $(printf "| Context: ${cc}(%s%%) %s\e[00m" "$cpct" "$toks")"
    elif [ -n "$cpct" ]; then
        out="$out $(printf "| Context: ${cc}(%s%%)\e[00m" "$cpct")"
    elif [ -n "$toks" ]; then
        out="$out $(printf "| Context: ${cc}%s\e[00m" "$toks")"
    fi
fi

# (Standalone Tokens segment removed — token detail now lives in the Session segment on line 2.)

# ---- everything below is sourced from the usage cache (background-refreshed) ----
UCACHE="$CLAUDE_DIR/usage-cache.json"
REFRESH="$CLAUDE_DIR/usage-refresh.sh"
BACKOFF="$CLAUDE_DIR/.usage-backoff"
cache_age=""
if [ -f "$UCACHE" ]; then
    mt=$(mtime_or0 "$UCACHE")
    cache_age=$((now - mt))
fi
# Trigger a background refresh when the cache is >10 min old — unless a backoff
# window is still active. This reader honors the window regardless of KIND
# (throttle or error); only usage-refresh.sh itself distinguishes them, and
# only to decide what --force may bypass. Comment previously said "throttle",
# which no longer matched the code.
if [ -x "$REFRESH" ]; then
    # The backoff file is "<until_epoch> <kind>" (see usage-refresh.sh). Read
    # ONLY the epoch field: `cat`ing the whole line here fed "<epoch> <kind>"
    # into `-ge`, which is an integer-expression error, so the condition never
    # fired and the automatic refresh stayed suppressed for good once any
    # cooldown had ever been written -- including long after it expired.
    bo=0
    [ -f "$BACKOFF" ] && { read -r bo _ < "$BACKOFF" 2>/dev/null || true; }
    case "$bo" in ''|*[!0-9]*) bo=0 ;; esac
    if { [ -z "$cache_age" ] || [ "$cache_age" -ge 600 ]; } && [ "$now" -ge "$bo" ]; then
        ("$REFRESH" >/dev/null 2>&1 &)
    fi
fi
# Stale marker: cache older than 30 min (endpoint likely throttled/unreachable).
stale_tag=""
if [ -n "$cache_age" ] && [ "$cache_age" -ge 1800 ]; then
    stale_tag=$(printf ' \e[02m(%dm old)\e[00m' $((cache_age / 60)))
fi

# 5h/7d limits: prefer the usage cache; fall back to CC statusline JSON rate_limits.* if absent.
# (cache is populated on Max/Pro; JSON rate_limits is the belt-and-suspenders source — schema
#  assumed used_percentage + resets_at, still unverified against a real subscription payload.)
fu=""; fr=""; fsev=""; su=""; sr=""; ssev=""
if [ -f "$UCACHE" ]; then
    fu=$(jq -r '.five.util // empty' "$UCACHE" 2>/dev/null)
    fr=$(jq -r '.five.resets // empty' "$UCACHE" 2>/dev/null)
    fsev=$(jq -r '.five.severity // empty' "$UCACHE" 2>/dev/null)
    su=$(jq -r '.seven.util // empty' "$UCACHE" 2>/dev/null)
    sr=$(jq -r '.seven.resets // empty' "$UCACHE" 2>/dev/null)
    ssev=$(jq -r '.seven.severity // empty' "$UCACHE" 2>/dev/null)
fi
# Fallback: CC's own statusline JSON carries a cached snapshot of the SAME endpoint data
# under rate_limits, reshaped — field is .used_percentage (int; endpoint calls it utilization)
# and .resets_at is a numeric epoch (endpoint returns ISO). Verified by live diff 2026-08-26:
# reset epochs matched to the second; percentages matched (7d lagged 1% as CC's copy is cached).
# No severity and no credit/$ data here — those stay endpoint-only.
if [ -z "$fu" ]; then
    fu=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
    fr=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    fr=${fr%%.*}
fi
if [ -z "$su" ]; then
    su=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
    sr=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
    sr=${sr%%.*}
fi

limits=""
if [ -n "$fu" ]; then
    fi5=$(printf "%.0f" "$fu" 2>/dev/null); fi5=$(int_or0 "$fi5")
    c5=$(sev_color "$fsev" "$fi5")
    r5=""
    [ -n "$fr" ] && r5=" resets $(fmt_reset "$fr")"
    limits=$(printf "${c5}5h (%s%%)%s\e[00m" "$fi5" "$r5")
fi
if [ -n "$su" ]; then
    fi7=$(printf "%.0f" "$su" 2>/dev/null); fi7=$(int_or0 "$fi7")
    c7=$(sev_color "$ssev" "$fi7")
    r7=""
    [ -n "$sr" ] && r7=" resets $(fmt_reset "$sr")"
    seg7=$(printf "${c7}7d (%s%%)%s\e[00m" "$fi7" "$r7")
    limits="${limits:+$limits · }$seg7"
fi

# ---- API-usage credits from cache ----
# Show whenever usage data exists (limit > 0), even when spend is disabled — a colored
# on/off tag makes the enabled state explicit. Color from spend.severity, else % threshold.
api_content=""     # colored "$used / $limit (NN%) resets <date>" (no label, no emoji)
api_emoji=""       # 🟢 enabled / 🔴 disabled
api_enabled=""     # "true"/"false" — whether credit spend is enabled
if [ -f "$UCACHE" ]; then
    ul=$(jq -r '.limit // 0' "$UCACHE" 2>/dev/null)
    has=$(awk -v l="$ul" 'BEGIN{print (l>0)?1:0}')
    if [ "$has" = "1" ]; then
        uu=$(jq -r '.used // 0' "$UCACHE")
        up=$(jq -r '.pct // 0' "$UCACHE")
        ur=$(jq -r '.resets // empty' "$UCACHE")
        usev=$(jq -r '.severity // empty' "$UCACHE")
        api_enabled=$(jq -r '.enabled // false' "$UCACHE")
        api_color=$(sev_color "$usev" "$up" "\e[01;36m")
        rd=""
        [ -n "$ur" ] && rd=" resets $(_dfmt "$ur" "+%b %-d")"
        [ "$api_enabled" = "true" ] && api_emoji="🟢" || api_emoji="🔴"
        body=$(awk -v u="$uu" -v l="$ul" -v p="$up" 'BEGIN{printf "$%.2f / $%.2f (%d%%)", u, l, p}')
        api_content=$(printf "${api_color}%s%s\e[00m" "$body" "$rd")
    fi
fi

# ---- assemble ----
# Line 1 tail = EITHER API usage OR 5h/7d limits (never both):
#   - credits enabled -> show API usage (🟢)
#   - else if on a subscription (limits present) -> show Limits (credits hidden)
#   - else (no limits) -> show API usage anyway, even if disabled (🔴; nothing else to show)
# Line 2 = Session cost only.
if [ "$api_enabled" = "true" ] && [ -n "$api_content" ]; then
    out="$out | $(printf "%s [API Usage]: %s" "$api_emoji" "$api_content")"
elif [ -n "$limits" ]; then
    out="$out | Limits: $limits"
elif [ -n "$api_content" ]; then
    out="$out | $(printf "%s [API Usage]: %s" "$api_emoji" "$api_content")"
fi

line2=""
[ -n "$session_seg" ] && line2="$session_seg"
[ -n "$line2" ] && line2="$line2$stale_tag"

if [ -n "$line2" ]; then
    printf "%s\n%s" "$out" "$line2"
else
    printf "%s" "$out"
fi
