#!/usr/bin/env bash
# Sum a session's token usage from the transcript JSONL (main chain + subagents) and
# derive current context length. Usage: token-stats.sh <transcript_path> <cache_file>
# Writes {input,output,cache_read,cache_write,context_length, main:{...}, agents:{...}}.
# Per-session single-flight lock.
#
# <cache_file> lives under ~/.claude/token_history/<project-slug>/<session_id>.json — one
# subdirectory per project (the caller, statusline-command.sh, builds this path from the
# transcript's own parent directory name, so there's no separate repo lookup here). That
# directory won't necessarily exist yet, unlike the old flat ~/.claude/ location.
#
# Correctness notes (mirrors sirmalloc/ccstatusline):
#  - Streaming writes several rows per API call: intermediate rows have stop_reason:null,
#    the final has a string. Count only finalized rows (truthy stop_reason) plus the last
#    row if it's still null — otherwise partial rows are double-counted.
#  - Skip isApiErrorMessage rows (synthetic, 0 tokens).
#  - context_length = newest MAIN-CHAIN entry (isSidechain != true) by timestamp:
#    input + cache_read + cache_creation. Parallel subtasks land out of order, so newest
#    is chosen by timestamp, not file position.
#  - Subagent usage lives in <dir>/<stem>/subagents/agent-*.jsonl (or <dir>/subagents/);
#    that folder is session-scoped, so all agent-*.jsonl in it belong to this session.
set -uo pipefail
tp="${1:-}"
out="${2:-}"
[ -n "$tp" ] && [ -n "$out" ] || exit 0

# SECURITY: refuse an <out> path containing a `..` component. The caller builds
# it as <home>/token_history/<project-slug>/<session-id>.json, where the slug is
# `basename "$(dirname "$transcript")"` — which yields `..` for a transcript path
# like /a/b/../s.jsonl. That escapes to the Claude home ROOT, and the cleanup
# sweep at the bottom of this script (`find <dirname> -name '*.json' -mtime +7
# -delete`) would then delete the user's settings.json, usage-cache.json and
# .mr-cache.json. The caller now validates the slug too; this is the backstop,
# because the destructive operation lives here.
case "/$out/" in
    */../*) exit 0 ;;
esac
# Write a minimal "I ran and failed" cache so the caller stops relaunching us on
# every ~30s render. statusline-command.sh treats an existing cache as fresh for
# 15s, so this bounds a broken transcript to one run per window instead of one
# per render. Mirrors the negative-caching the sibling refreshers already do
# (usage-refresh.sh's backoff file, mr-refresh.sh's `failed` entries) -- this was
# the only one of the three with no such brake.
write_failed_marker() {
    [ -n "${out:-}" ] || return 0
    case "/$out/" in */../*) return 0 ;; esac
    mkdir -p "$(dirname "$out")" 2>/dev/null
    printf '%s\n' '{"input":0,"output":0,"cache_read":0,"cache_write":0,"est_cost":0,"context_length":0,"failed":true,"main":{"input":0,"output":0,"cache_read":0,"cache_write":0,"est_cost":0},"agents":{"input":0,"output":0,"cache_read":0,"cache_write":0,"est_cost":0}}' \
        >"$out.tmp.$$" 2>/dev/null || { rm -f "$out.tmp.$$" 2>/dev/null; return 0; }
    # Never let the marker replace real figures (same rule as the main write).
    if [ -s "$out" ]; then
        rm -f "$out.tmp.$$" 2>/dev/null
        return 0
    fi
    mv "$out.tmp.$$" "$out" 2>/dev/null || rm -f "$out.tmp.$$" 2>/dev/null
    return 0
}

# A missing/unreadable transcript is a failure, not a no-op: mark it.
[ -f "$tp" ] || { write_failed_marker; exit 0; }

# The cache records per-project session paths and token counts; keep it
# owner-only rather than whatever the ambient umask yields. Covers the output
# file, its temp file, and the lock directory.
umask 077

mkdir -p "$(dirname "$out")" 2>/dev/null

lock="$out.lock"
# mtime in epoch seconds. Validate that the result is NUMERIC rather than
# trusting exit status: GNU `stat -f` means --file-system, so on a host with GNU
# coreutils ahead of /usr/bin (common on macOS via Homebrew) the fallback exits
# ZERO and prints a multi-line filesystem report to stdout — so `|| echo 0` never
# fires, `age` returns junk, and under `set -u` the arithmetic aborts and yields
# an empty string. An empty age makes BOTH lock guards below evaluate false,
# which reclaims a lock whose owner is still inside the critical section. Same
# `case` validation already used for the backoff epoch in statusline-command.sh.
age() {
    m=$(stat -c %Y "$1" 2>/dev/null)
    case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;; esac
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    echo $(($(date +%s) - m))
}
# Single-flight (atomic mkdir) with the holder's PID recorded in an `owner`
# file. A purely time-based staleness check is unsafe on both sides: a run that
# outlives the threshold has its LIVE lock stolen, and its unconditional
# `rmdir` trap then deletes whichever newer process holds the lock, admitting a
# third and racing them all on the shared output temp file. A big transcript
# plus many subagent files is a realistic way to exceed a fixed threshold here.
# Reclaim only when the owner is gone; release only while we still own it.
LOCK_GRACE=120  # lock exists but no owner recorded (killed between mkdir and write)
LOCK_HARD=3600  # owner looks alive but the lock is impossibly old -> assume PID reuse
lock_owner() { cat "$lock/owner" 2>/dev/null; }
lock_acquire() {
    if mkdir "$lock" 2>/dev/null; then
        printf '%s' "$$" >"$lock/owner" 2>/dev/null
        return 0
    fi
    # Held. Deciding "this lock is abandoned" and acting on it must happen under
    # mutual exclusion. Neither a plain `rm -rf` + `mkdir` nor an atomic rename
    # is enough: the lock is identified by PATH, not identity, so a contender
    # that decided "abandoned" a moment ago will happily tear down the BRAND-NEW
    # lock a winner has since created at that same path — putting both inside
    # the critical section. rename(2) only guarantees one rename of one
    # directory instance wins, which does not stop that.
    # So serialize the whole decide-and-reclaim on its own atomic mkdir, and
    # re-read the owner UNDER it: a process that reclaimed while we waited has
    # already recorded itself, so we then correctly see a LIVE owner and back off.
    reclaim="$lock.reclaim"
    if ! mkdir "$reclaim" 2>/dev/null; then
        # Another process is reclaiming right now. It is held for only a few
        # filesystem operations, so anything older was abandoned mid-reclaim;
        # clear that and let the next run retry rather than race this one.
        [ "$(age "$reclaim")" -gt 60 ] && rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    owner=$(lock_owner)
    lage=$(age "$lock")
    if { [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$lage" -lt "$LOCK_HARD" ]; } \
       || { [ -z "$owner" ] && [ "$lage" -lt "$LOCK_GRACE" ]; }; then
        rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    rm -rf "$lock" 2>/dev/null
    # A fast-path acquirer can slip in between the rm and this mkdir. If it did,
    # our mkdir fails and it owns the lock -- we must NOT write our own owner
    # over theirs.
    if ! mkdir "$lock" 2>/dev/null; then
        rmdir "$reclaim" 2>/dev/null
        return 1
    fi
    printf '%s' "$$" >"$lock/owner" 2>/dev/null
    rmdir "$reclaim" 2>/dev/null
    return 0
}
lock_release() {
    [ "$(lock_owner)" = "$$" ] && rm -rf "$lock" 2>/dev/null
    return 0
}
lock_acquire || exit 0
trap lock_release EXIT

# Sum finalized usage over one-or-more JSONL files (slurped). Emits {i,o,r,w,c}.
# c = list-price $ estimate: per-entry model pricing, cache read at 0.1x input, cache
# writes split by TTL (5m = 1.25x input, 1h = 2x input). This is a LIST-PRICE estimate,
# not billed cost (subscriptions/credits differ); fast-mode premiums are not modeled.
SUM_FILTER='
  def price($m): ($m // "") as $x
    | if   ($x | test("opus"))          then {i:5,  o:25}
      elif ($x | test("fable|mythos"))  then {i:10, o:50}
      elif ($x | test("sonnet-5"))      then {i:2,  o:10}
      elif ($x | test("sonnet"))        then {i:3,  o:15}
      elif ($x | test("haiku"))         then {i:1,  o:5}
      else {i:5, o:25} end;
  def ecost:
    .message.usage as $u | price(.message.model) as $p
    | (($u.cache_creation.ephemeral_5m_input_tokens) // ($u.cache_creation_input_tokens // 0)) as $c5
    | (($u.cache_creation.ephemeral_1h_input_tokens) // 0) as $c1
    | ( (($u.input_tokens // 0) * $p.i)
      + (($u.output_tokens // 0) * $p.o)
      + (($u.cache_read_input_tokens // 0) * ($p.i * 0.1))
      + ($c5 * ($p.i * 1.25))
      + ($c1 * ($p.i * 2.0)) ) / 1000000;
  [ inputs | select(.message.usage and (.isApiErrorMessage != true)) ] as $u
  | ($u | to_entries
     | map(select(
         # Streaming dedup is decided PER ROW, on whether that row itself
         # carries stop_reason — not by a file-level `any(...)` probe. A
         # transcript can mix schemas (older rows with no stop_reason field at
         # all, newer rows with it, e.g. across a client upgrade); a file-level
         # probe would flip every row into field-aware mode, where an ABSENT
         # field reads as null and the row is discarded as a streaming
         # intermediate — silently dropping every older billable row except
         # whichever fieldless one happened to land last.
         #   field absent          -> finalized (that schema never emitted it)
         #   field present, truthy -> finalized
         #   field present, null   -> streaming intermediate; keep only if it
         #                            is the last row in the file (in flight)
         # Matches the context_length filter below, which already treats an
         # absent stop_reason as finalized.
         (.value.message | has("stop_reason") | not)
         or (.value.message.stop_reason != null)
         or (.key == ($u | length - 1))))
     | map(.value)) as $f
  | { i: ([$f[].message.usage.input_tokens // 0] | add // 0),
      o: ([$f[].message.usage.output_tokens // 0] | add // 0),
      r: ([$f[].message.usage.cache_read_input_tokens // 0] | add // 0),
      w: ([$f[].message.usage.cache_creation_input_tokens // 0] | add // 0),
      c: ([$f[] | ecost] | add // 0) }'

# A transcript is appended to LIVE, so its final line is frequently a partially
# written object. Feeding the file to jq directly aborts the WHOLE parse on that,
# and the zero fallback below then replaced every valid row with zeros --
# publishing a zeroed session to the cache, which is worse than showing nothing.
#
# `-R` reads each line as a raw string and `fromjson?` parses it, with the `?`
# swallowing the error for a line that will not parse. So a malformed row is
# skipped INDIVIDUALLY and every other row still counts. A whole-stream
# `jq -c .` is not sufficient here: it stops at the first bad row and drops
# everything after it, which is not just a torn-tail problem — resuming an
# interrupted session appends valid rows AFTER the partial one, so the damaged
# row sits mid-file and the session would silently stop accumulating from there
# on, permanently. Still a single jq process over the file, so O(n).
rows() { jq -Rc 'fromjson?' "$1" 2>/dev/null; }

main=$(rows "$tp" | jq -n "$SUM_FILTER" 2>/dev/null)
[ -z "$main" ] && main='{"i":0,"o":0,"r":0,"w":0,"c":0}'

# context length: newest main-chain finalized entry by timestamp
ctx=$(jq -rn '
  [ inputs
    | select(.message.usage and (.isSidechain != true) and (.isApiErrorMessage != true) and .timestamp)
    | select(.message | (has("stop_reason") | not) or (.stop_reason != null)) ]
  | sort_by(.timestamp) | last
  | if . then ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)) else 0 end
' <<CTX_ROWS 2>/dev/null
$(rows "$tp")
CTX_ROWS
)
[ -z "$ctx" ] && ctx=0

# subagents: sum every agent-*.jsonl in the session-scoped subagents dir.
# Run SUM_FILTER separately PER FILE, then add the results — not once across
# all files concatenated. Two subagents streaming concurrently can each end
# their own transcript on a billable stop_reason:null row; feeding every file
# into one jq invocation makes `inputs` one continuous stream, so the
# "keep a trailing null row" dedup rule only protects the LAST file in the
# list, silently dropping any earlier file's pending trailing row.
tdir=$(dirname "$tp")
stem=$(basename "$tp" .jsonl)
agents='{"i":0,"o":0,"r":0,"w":0,"c":0}'
for d in "$tdir/$stem/subagents" "$tdir/subagents"; do
    [ -d "$d" ] || continue
    files=$(find "$d" -maxdepth 1 -name 'agent-*.jsonl' 2>/dev/null)
    [ -z "$files" ] && continue
    per_file=$(
        while IFS= read -r af; do
            [ -n "$af" ] || continue
            rows "$af" | jq -n "$SUM_FILTER" 2>/dev/null
        done <<AGENT_FILES
$files
AGENT_FILES
    )
    agents=$(printf '%s' "$per_file" | jq -s '{
        i: (map(.i) | add // 0), o: (map(.o) | add // 0),
        r: (map(.r) | add // 0), w: (map(.w) | add // 0),
        c: (map(.c) | add // 0)
    }' 2>/dev/null)
    [ -z "$agents" ] && agents='{"i":0,"o":0,"r":0,"w":0,"c":0}'
    break
done

jq -n --argjson m "$main" --argjson a "$agents" --argjson ctx "$ctx" '
  {
    input:  ($m.i + $a.i),
    output: ($m.o + $a.o),
    cache_read:  ($m.r + $a.r),
    cache_write: ($m.w + $a.w),
    est_cost: (($m.c + $a.c)),
    context_length: $ctx,
    main:   {input:$m.i, output:$m.o, cache_read:$m.r, cache_write:$m.w, est_cost:$m.c},
    agents: {input:$a.i, output:$a.o, cache_read:$a.r, cache_write:$a.w, est_cost:$a.c}
  }' >"$out.tmp.$$" 2>/dev/null || { rm -f "$out.tmp.$$" 2>/dev/null; write_failed_marker; exit 0; }

# Never replace a populated cache with an all-zero one. A session's cumulative
# totals only ever grow, so zeros on a session that previously had usage mean
# the read failed (an unreadable or wholly unparseable transcript), not that the
# numbers really went to zero. Belt and braces alongside the `rows` pre-pass
# above: publishing zeros is worse than serving the last good figures, because
# it silently misreports cost rather than looking broken.
if [ -s "$out" ]; then
    keep=$(jq -rn --slurpfile old "$out" --slurpfile new "$out.tmp.$$" '
        ($old[0] // {}) as $o | ($new[0] // {}) as $n
        | if (($n.input // 0) + ($n.output // 0) + ($n.cache_read // 0) + ($n.cache_write // 0)) == 0
             and (($o.input // 0) + ($o.output // 0) + ($o.cache_read // 0) + ($o.cache_write // 0)) > 0
          then "keep" else "replace" end' 2>/dev/null)
    if [ "$keep" = "keep" ]; then
        rm -f "$out.tmp.$$" 2>/dev/null
        exit 0
    fi
fi
mv "$out.tmp.$$" "$out"

# Opportunistic cleanup: drop token-stats caches for sessions untouched for a
# week. Scoped by REQUIRING the directory to sit under a `token_history/`
# component, rather than trusting `dirname "$out"`: this is a recursive delete of
# *.json, so it must never be able to run in the Claude home root (where
# settings.json lives) even if the caller hands us a surprising path. Combined
# with the `..` rejection at the top, the sweep can only ever touch a
# token_history project directory.
sweep_dir=$(dirname "$out")
case "$sweep_dir" in
    */token_history/*|*/token_history)
        find "$sweep_dir" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null || true ;;
esac
