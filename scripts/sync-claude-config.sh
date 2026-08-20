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
# Any file/dir about to be overwritten is backed up first, same as CLAUDE.md
# and settings.json below.
#
# CLAUDE.md is fully overwritten (it's meant to be an exact mirror of the
# repo's copy) but only when it differs, and only after backing up the live
# version.
#
# settings.json is never overwritten wholesale: this script merges only the
# `hooks` and `env` keys from the repo's root settings.json into the live
# file, leaving every other live-only key (enabledPlugins,
# extraKnownMarketplaces, effortLevel, tui, model,
# skipDangerousModePermissionPrompt, etc.) untouched. The merge is
# idempotent — re-running never duplicates a hook entry, and a hook event
# present only in the live file (not in the repo) is left alone.
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
BACKUP_DIR="$CLAUDE_HOME/backups/sync-$TIMESTAMP"
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

  if [ -d "$dst" ]; then
    diff_out=$(diff -rq "$src" "$dst" 2>&1 || true)
  else
    diff_out="(missing at destination)"
  fi
  [ -z "$diff_out" ] && continue

  n_lines=$(printf '%s\n' "$diff_out" | grep -c .)
  note "$name/ — $n_lines difference(s) from $dst/"
  CHANGED=1
  if [ "$APPLY" -eq 1 ]; then
    if [ -d "$dst" ]; then
      backup_once
      mkdir -p "$BACKUP_DIR/$name"
      cp -r "$dst/." "$BACKUP_DIR/$name/"
    fi
    mkdir -p "$dst"
    cp -r "$src/." "$dst/"
  fi
done

# --- hooks/*.sh (scripts only — settings.json handled separately below) ---
src_hooks="$REPO_ROOT/hooks"
dst_hooks="$CLAUDE_HOME/hooks"
if [ -d "$src_hooks" ]; then
  for f in "$src_hooks"/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    dst_f="$dst_hooks/$base"
    if [ ! -f "$dst_f" ] || ! cmp -s "$f" "$dst_f"; then
      note "hooks/$base -> $dst_f"
      CHANGED=1
      if [ "$APPLY" -eq 1 ]; then
        if [ -f "$dst_f" ]; then
          backup_once
          mkdir -p "$BACKUP_DIR/hooks"
          cp "$dst_f" "$BACKUP_DIR/hooks/$base"
        fi
        mkdir -p "$dst_hooks"
        cp "$f" "$dst_f"
        chmod +x "$dst_f"
      fi
    fi
  done
fi

# --- CLAUDE.md: full overwrite, only when it differs, backed up first ---
src_claude_md="$REPO_ROOT/CLAUDE.md"
dst_claude_md="$CLAUDE_HOME/CLAUDE.md"
if [ -f "$src_claude_md" ] && { [ ! -f "$dst_claude_md" ] || ! cmp -s "$src_claude_md" "$dst_claude_md"; }; then
  note "CLAUDE.md -> $dst_claude_md (differs$( [ -f "$dst_claude_md" ] && echo "; backed up first" || true))"
  CHANGED=1
  if [ "$APPLY" -eq 1 ]; then
    if [ -f "$dst_claude_md" ]; then
      backup_once
      cp "$dst_claude_md" "$BACKUP_DIR/CLAUDE.md"
    fi
    cp "$src_claude_md" "$dst_claude_md"
  fi
fi

# --- settings.json: merge hooks + env only, preserve every other live key ---
repo_settings="$REPO_ROOT/settings.json"
live_settings="$CLAUDE_HOME/settings.json"
if [ -f "$repo_settings" ]; then
  if [ -f "$live_settings" ]; then
    merged=$(jq -s '
      .[0] as $live | .[1] as $repo |
      ($live.hooks // {}) as $liveHooks |
      ($repo.hooks // {}) as $repoHooks |
      (reduce ($repoHooks | keys_unsorted[]) as $ev ($liveHooks;
        if has($ev) then
          .[$ev] += ([$repoHooks[$ev][] | select(
            . as $g | ($liveHooks[$ev] // []) | any(.hooks == $g.hooks) | not
          )])
        else
          .[$ev] = $repoHooks[$ev]
        end
      )) as $mergedHooks |
      $live + {hooks: $mergedHooks, env: (($live.env // {}) + ($repo.env // {}))}
    ' "$live_settings" "$repo_settings")

    if [ "$(printf '%s' "$merged" | jq -S .)" != "$(jq -S . "$live_settings")" ]; then
      note "settings.json: merge hooks+env from repo into $live_settings (other live keys preserved; backed up first)"
      CHANGED=1
      if [ "$APPLY" -eq 1 ]; then
        backup_once
        cp "$live_settings" "$BACKUP_DIR/settings.json"
        printf '%s\n' "$merged" | jq '.' > "$live_settings"
      fi
    fi
  else
    note "settings.json: create $live_settings from repo (no live file existed)"
    CHANGED=1
    if [ "$APPLY" -eq 1 ]; then
      mkdir -p "$CLAUDE_HOME"
      cp "$repo_settings" "$live_settings"
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
