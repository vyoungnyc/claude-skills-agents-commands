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
[ -f "$tp" ] || exit 0

mkdir -p "$(dirname "$out")" 2>/dev/null

lock="$out.lock"
age() { m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0); echo $(($(date +%s) - m)); }
[ -d "$lock" ] && [ "$(age "$lock")" -gt 120 ] && rmdir "$lock" 2>/dev/null
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT

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

main=$(jq -n "$SUM_FILTER" "$tp" 2>/dev/null)
[ -z "$main" ] && main='{"i":0,"o":0,"r":0,"w":0,"c":0}'

# context length: newest main-chain finalized entry by timestamp
ctx=$(jq -rn '
  [ inputs
    | select(.message.usage and (.isSidechain != true) and (.isApiErrorMessage != true) and .timestamp)
    | select(.message | (has("stop_reason") | not) or (.stop_reason != null)) ]
  | sort_by(.timestamp) | last
  | if . then ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)) else 0 end
' "$tp" 2>/dev/null)
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
            jq -n "$SUM_FILTER" "$af" 2>/dev/null
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
  }' >"$out.tmp" 2>/dev/null && mv "$out.tmp" "$out"

# opportunistic cleanup: drop token-stats caches for sessions untouched for a week, scoped
# to this session's own project subdirectory under token_history/.
find "$(dirname "$out")" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null || true
