#!/bin/bash
# scripts/sync-claude-config.sh — deploy this repo's agents/skills/commands/rules/
# hooks/CLAUDE.md to the live global Claude Code config (default $HOME/.claude,
# override with CLAUDE_HOME for testing or an alternate target).
#
# Dry run by default: prints what differs and exits 0 without touching
# anything. Pass --apply to actually write. Every file this script overwrites
# is backed up first under <CLAUDE_HOME>/backups/sync-<timestamp>/, so an
# unwanted apply is always recoverable.
#
# agents/, skills/, commands/, rules/, hooks/*.sh are overlay-copied — never
# deleted, so a live-only file not present in the repo survives untouched.
# Any directory about to be modified (agents/skills/commands/rules/hooks) is
# snapshotted whole first, so a rollback is one recursive copy; CLAUDE.md and
# settings.json are backed up per file, same as below.
#
# statusline/*.sh are flat-copied straight into $CLAUDE_HOME (not
# $CLAUDE_HOME/statusline/) — the status-line scripts locate each other, and
# their caches, as siblings in whatever Claude home they were deployed into,
# so they must land at the same level as everything else in $CLAUDE_HOME.
# They are backed up per file, since there is no dedicated directory to
# snapshot.
#
# hooks/*.sh and statusline/*.sh both exclude *.test.sh — those are dev-only
# suites, not runtime scripts, and have no business being deployed to a live
# ~/.claude (they were never referenced there, just deadweight clutter).
#
# CLAUDE.md is fully overwritten (it's meant to be an exact mirror of the
# repo's copy) but only when it differs, and only after backing up the live
# version.
#
# settings.json is never overwritten wholesale: this script merges only the
# `hooks`, `env`, and `statusLine` keys from the repo's root settings.json
# into the live file, leaving every other live-only key (enabledPlugins,
# extraKnownMarketplaces, effortLevel, tui, model,
# skipDangerousModePermissionPrompt, etc.) untouched. The merge is
# idempotent — re-running never duplicates a hook entry, and a hook event
# present only in the live file (not in the repo) is left alone. `statusLine`
# is a full replace when the repo defines one (like CLAUDE.md); a live-only
# `statusLine` survives untouched if the repo has none.
#
# bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "sync-claude-config.sh: jq is required but was not found on PATH" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [--apply]

  (no args)   dry run — print what would change, touch nothing
  --apply     perform the sync; overwritten files are backed up first

Target directory: \$CLAUDE_HOME if set, else \$HOME/.claude
USAGE
      exit 0
      ;;
    *)
      echo "sync-claude-config.sh: unknown argument: $arg" >&2
      exit 10
      ;;
  esac
done

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Per-process suffix so two applies within the same UTC second never share a
# backup path (the per-category existence check would otherwise skip a needed
# snapshot on the second run).
BACKUP_DIR="$CLAUDE_HOME/backups/sync-$TIMESTAMP-$$-${RANDOM}"
BACKED_UP=0

backup_once() {
  # Creates BACKUP_DIR on first call only; safe to call repeatedly.
  if [ "$BACKED_UP" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR"
    BACKED_UP=1
  fi
}

CHANGED=0
PLANNED=""

note() {
  PLANNED="$PLANNED
- $1"
}

# --- directories synced by overlay copy (adds/updates; never deletes) ---
for name in agents skills commands rules; do
  src="$REPO_ROOT/$name"
  dst="$CLAUDE_HOME/$name"
  [ -d "$src" ] || continue

  # A symlinked category root would make the overlay write through the link
  # into the external referent and leave the link in place. Record the link,
  # replace it with a real directory, and deploy the repo contents there; the
  # external referent is left untouched (rm drops the link, not its target).
  if [ -L "$dst" ]; then
    note "$name/ (replacing symlinked root)"
    CHANGED=1
    if [ "$APPLY" -eq 1 ]; then
      backup_once
      cp -P "$dst" "$BACKUP_DIR/$name.rootlink"
      rm -f "$dst"
      mkdir -p "$dst"
      cp -R "$src/." "$dst/"
    fi
    continue
  fi

  if [ -d "$dst" ]; then
    diff_out=$(diff -rq "$src" "$dst" 2>&1 || true)
  else
    diff_out="(missing at destination)"
  fi
  [ -z "$diff_out" ] && continue

  n_lines=$(printf '%s\n' "$diff_out" | grep -c .)
  note "$name/ — $n_lines difference(s) from $dst/ (overwritten files backed up first)"
  CHANGED=1
  if [ "$APPLY" -eq 1 ]; then
    if [ -d "$dst" ]; then
      backup_once
      mkdir -p "$BACKUP_DIR/$name"
      cp -R "$dst/." "$BACKUP_DIR/$name/"
    fi
    mkdir -p "$dst"
    # Clear destination symlinks that collide with a repo path so the copy
    # writes a real file/dir instead of following the link and overwriting its
    # external target. The snapshot above already preserved them (as links).
    ( cd "$src" && find . -print0 ) | while IFS= read -r -d '' rel; do
      d="$dst/${rel#./}"
      if [ -L "$d" ]; then rm -f "$d"; fi
    done
    cp -R "$src/." "$dst/"
  fi
done

# --- hooks/*.sh (scripts only, never *.test.sh — settings.json handled separately below) ---
src_hooks="$REPO_ROOT/hooks"
dst_hooks="$CLAUDE_HOME/hooks"
if [ -d "$src_hooks" ]; then
  for f in "$src_hooks"/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in *.test.sh) continue ;; esac
    dst_f="$dst_hooks/$base"
    if [ -L "$dst_f" ] || [ ! -f "$dst_f" ] || ! cmp -s "$f" "$dst_f"; then
      note "hooks/$base -> $dst_f"
      CHANGED=1
      if [ "$APPLY" -eq 1 ]; then
        # Whole-directory snapshot of the live hooks dir, once, before the
        # first change — same restore-with-one-copy model as the dirs above.
        if [ -d "$dst_hooks" ] && [ ! -e "$BACKUP_DIR/hooks" ]; then
          backup_once
          mkdir -p "$BACKUP_DIR/hooks"
          cp -R "$dst_hooks/." "$BACKUP_DIR/hooks/"
        fi
        mkdir -p "$dst_hooks"
        # Drop a destination symlink first so cp writes a real file instead of
        # following the link and overwriting its external referent.
        if [ -L "$dst_f" ]; then rm -f "$dst_f"; fi
        cp "$f" "$dst_f"
        chmod +x "$dst_f"
      fi
    fi
  done
fi

# --- statusline/*.sh: flat-copied into $CLAUDE_HOME itself (not a subdirectory), never *.test.sh ---
src_statusline="$REPO_ROOT/statusline"
if [ -d "$src_statusline" ]; then
  for f in "$src_statusline"/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in *.test.sh) continue ;; esac
    dst_f="$CLAUDE_HOME/$base"
    # A symlinked destination is treated as needing replacement, same as the
    # hooks loop above: these land flat in $CLAUDE_HOME, so the same
    # write-through-the-link hazard applies.
    if [ -L "$dst_f" ] || [ ! -f "$dst_f" ] || ! cmp -s "$f" "$dst_f"; then
      note "statusline/$base -> $dst_f$( [ -f "$dst_f" ] && echo " (backed up first)" || true)"
      CHANGED=1
      if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$CLAUDE_HOME"
        # Per-file backup: these land in $CLAUDE_HOME's root alongside
        # unrelated files, so there is no dedicated directory to snapshot.
        if [ -f "$dst_f" ] && [ ! -L "$dst_f" ]; then
          backup_once
          cp "$dst_f" "$BACKUP_DIR/$base"
        elif [ -L "$dst_f" ]; then
          backup_once
          cp -P "$dst_f" "$BACKUP_DIR/$base.link"
        fi
        # Drop a destination symlink first so cp writes a real file instead of
        # following the link and overwriting its external referent.
        if [ -L "$dst_f" ]; then rm -f "$dst_f"; fi
        cp "$f" "$dst_f"
        chmod +x "$dst_f"
      fi
    fi
  done
fi

# --- CLAUDE.md: full overwrite, only when it differs, backed up first ---
src_claude_md="$REPO_ROOT/CLAUDE.md"
dst_claude_md="$CLAUDE_HOME/CLAUDE.md"
# A symlinked destination counts as needing replacement: the overlay dirs, the
# hooks loop and the statusline loop all defend against writing THROUGH a link
# into an external referent, and these two file paths were the gap.
if [ -f "$src_claude_md" ] && { [ -L "$dst_claude_md" ] || [ ! -f "$dst_claude_md" ] || ! cmp -s "$src_claude_md" "$dst_claude_md"; }; then
  note "CLAUDE.md -> $dst_claude_md (differs$( [ -f "$dst_claude_md" ] && echo "; backed up first" || true))"
  CHANGED=1
  if [ "$APPLY" -eq 1 ]; then
    if [ -L "$dst_claude_md" ]; then
      backup_once
      cp -P "$dst_claude_md" "$BACKUP_DIR/CLAUDE.md.link"
      rm -f "$dst_claude_md"
    elif [ -f "$dst_claude_md" ]; then
      backup_once
      cp "$dst_claude_md" "$BACKUP_DIR/CLAUDE.md"
    fi
    cp "$src_claude_md" "$dst_claude_md"
  fi
fi

# --- settings.json: merge hooks + env only, preserve every other live key ---
repo_settings="$REPO_ROOT/settings.json"
live_settings="$CLAUDE_HOME/settings.json"
# Repo-authored hook/statusLine commands hardcode the literal, UNexpanded
# text `"$HOME"/.claude/...` — portable for the default deploy target, since
# Claude Code expands $HOME itself at hook-invocation time on whatever
# machine ends up running it. That portability assumption breaks when
# deploying to an explicit alternate CLAUDE_HOME (a real, documented use of
# this script, not just for tests): the scripts land under $CLAUDE_HOME, but
# the merged settings.json would still tell Claude Code to run them from
# $HOME/.claude, the wrong (default) location. Passed to both jq invocations
# below as $rewrite_home (empty when CLAUDE_HOME is the default — a no-op —
# so the normal deploy path keeps the portable, unexpanded "$HOME" form);
# applied only to freshly-read $repo content, never to pre-existing live
# commands. Doing this as a jq `walk` over decoded string values (rather
# than raw sed/text substitution on the JSON file) sidesteps having to
# hand-match JSON's own backslash-escaping of the embedded quote characters.
rewrite_home=""
[ "$CLAUDE_HOME" != "$HOME/.claude" ] && rewrite_home="$CLAUDE_HOME"
# Single-quoted: $HOME and $marker below are literal jq source, not shell
# expansion. Inside JQ's own string literal, \" is an escaped literal quote,
# so $marker's jq-string VALUE is `"$HOME"/.claude` (real quote characters) —
# exactly what a decoded JSON command string looks like once parsed.
#
# $rh is shell-quoted via jq's @sh (not spliced in raw) before replacing the
# marker: these rewritten commands are later invoked through a shell, so a
# CLAUDE_HOME containing a space or other shell metacharacter must stay one
# word. @sh wraps it in single quotes (escaping any embedded ones), matching
# up against the unquoted "/.claude/..." suffix that follows -- adjacent
# quoted+unquoted segments concatenate into a single shell word, same as the
# original `"$HOME"/.claude` marker's own mixed quoting.
# rewriteHomeStr rewrites ONE string; rewriteHome walks a whole document with
# it. The scalar form is also applied to LIVE commands (see the merge below) to
# recognize a previously-deployed copy of a repo hook that predates this
# rewrite, so keep the two in lockstep.
REWRITE_HOME_JQ='
  def rewriteHomeStr($rh):
    ("\"$HOME\"/.claude") as $marker |
    if ($rh != "") and (type == "string") and startswith($marker)
    then ($rh | @sh) + .[($marker | length):]
    else . end;
  def rewriteHome($rh):
    if $rh == "" then . else walk(rewriteHomeStr($rh)) end;
  # A hook group MINUS its command list: everything that defines WHEN the
  # group fires (matcher, if, and any field Claude Code adds later). Empty and
  # null values are dropped so an explicit `matcher: ""` and an absent matcher
  # compare equal — both mean "no matcher" — instead of reading as two
  # different triggers and duplicating the command on every sync.
  def groupKey: del(.hooks) | with_entries(select(.value != null and .value != ""));
'

if [ -f "$repo_settings" ]; then
  if [ -f "$live_settings" ]; then
    merged=$(jq -s --arg rh "$rewrite_home" "$REWRITE_HOME_JQ"'
      .[0] as $live | (.[1] | rewriteHome($rh)) as $repo |
      ($live.hooks // {}) as $liveHooks |
      ($repo.hooks // {}) as $repoHooks |
      # Hook merge rule: THE REPO OWNS THE COMPLETE TRIGGER SET FOR ITS OWN
      # COMMANDS. For each event, every live hook whose command is one the repo
      # also defines is removed, then the repo groups are appended verbatim.
      # Live-only hooks (commands the repo does not ship) are never touched.
      #
      # This single rule replaces three mechanisms that previously stacked up
      # here -- a (command, trigger) dedup, an "adopt the repo hook object" pass
      # to deploy execution metadata, and a path migration -- and it fixes what
      # they got wrong between them:
      #   - Keying dedup on the trigger (matcher + `if`) meant a live group that
      #     predated a new `if:` read as a DIFFERENT trigger, so the repo group
      #     was appended and the stale one kept. This repo own settings.json hit
      #     exactly that: enforce-git-conventions.sh ended up registered twice,
      #     firing on every Bash call as well as under `Bash(git *)`.
      #   - Keying on command alone instead would drop a command the repo
      #     deliberately ships under two different triggers.
      # Replacing wholesale sidesteps both: whatever set of groups the repo
      # declares for a command IS the deployed set, so adding, removing or
      # re-triggering a hook all work, and re-running stays idempotent.
      #
      # Commands are compared after rewriteHomeStr normalization, so a live copy
      # still carrying the pre-rewrite literal `"$HOME"/.claude/...` form is
      # recognized as the same hook and replaced rather than left behind.
      #
      # Deliberate tradeoff: a user who hand-added an extra trigger for a
      # repo-shipped hook loses it on sync. That matches how CLAUDE.md and
      # statusLine already deploy (repo wins), and the live file is backed up
      # first. A hook the user wrote themselves is unaffected.
      # Repo-owned commands are collected across ALL events and stripped from
      # ALL live events before the repo groups are appended. Scoping the strip
      # per-event was not enough: a command the repo MOVED from one event to
      # another kept its old live registration under the previous event while
      # the new one was appended, so it fired on both triggers -- the same
      # defect this rule exists to prevent, one scope up.
      ([$repoHooks[]? | .[]? | (.hooks // [])[]? | .command]) as $ownedCmds |
      (reduce ($liveHooks | keys_unsorted[]) as $ev ($liveHooks;
        .[$ev] = ([$liveHooks[$ev][]?
          | .hooks = [((.hooks // [])[]?)
              | . as $lh
              | select((($lh.command // "") | rewriteHomeStr($rh)) as $rw
                       | ([$rw] - $ownedCmds) | length > 0)]
          | select((.hooks | length) > 0)
        ])
      )) as $strippedLive |
      # Drop events left with no groups at all, so stripping does not leave a
      # bare `"PreToolUse": []` behind in the user file.
      ($strippedLive | with_entries(select((.value | length) > 0))) as $strippedLive |
      (reduce ($repoHooks | keys_unsorted[]) as $ev ($strippedLive;
        .[$ev] = (( .[$ev] // []) + [$repoHooks[$ev][]?])
      )) as $mergedHooks |
      # statusLine: repo wins when it defines one (full replace, like CLAUDE.md);
      # otherwise keep whatever live has (including having none — never introduce
      # a stray `statusLine: null` key when neither side defines it).
      ($repo.statusLine // $live.statusLine // null) as $sl |
      $live + {hooks: $mergedHooks, env: (($live.env // {}) + ($repo.env // {}))}
        + (if $sl == null then {} else {statusLine: $sl} end)
    ' "$live_settings" "$repo_settings")

    if [ "$(printf '%s' "$merged" | jq -S .)" != "$(jq -S . "$live_settings")" ]; then
      note "settings.json: merge hooks+env+statusLine from repo into $live_settings (other live keys preserved; backed up first)"
      CHANGED=1
      if [ "$APPLY" -eq 1 ]; then
        backup_once
        cp "$live_settings" "$BACKUP_DIR/settings.json"
        # Drop a symlinked destination first, so the redirect below writes a real
        # file here instead of following the link and rewriting its referent.
        if [ -L "$live_settings" ]; then
          cp -P "$live_settings" "$BACKUP_DIR/settings.json.link"
          rm -f "$live_settings"
        fi
        printf '%s\n' "$merged" | jq '.' > "$live_settings"
      fi
    fi
  else
    note "settings.json: create $live_settings from repo (no live file existed)"
    CHANGED=1
    if [ "$APPLY" -eq 1 ]; then
      mkdir -p "$CLAUDE_HOME"
      [ -L "$live_settings" ] && rm -f "$live_settings"
      jq --arg rh "$rewrite_home" "$REWRITE_HOME_JQ"'rewriteHome($rh)' "$repo_settings" > "$live_settings"
    fi
  fi
fi

echo "Target: $CLAUDE_HOME"

if [ "$CHANGED" -eq 0 ]; then
  echo "Already in sync — nothing to do."
  exit 0
fi

if [ "$APPLY" -eq 1 ]; then
  echo "Applied:$PLANNED"
  if [ "$BACKED_UP" -eq 1 ]; then
    echo ""
    echo "Backups: $BACKUP_DIR"
  fi
else
  echo "Dry run — would apply:$PLANNED"
  echo ""
  echo "Re-run with --apply to write."
fi
