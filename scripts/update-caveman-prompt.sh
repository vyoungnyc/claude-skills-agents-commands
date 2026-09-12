#!/bin/bash
# scripts/update-caveman-prompt.sh — vendor the caveman-mode prompt from
# upstream so the omp caveman extension's injected rules track the canonical
# skill definition instead of a hand-copied, drift-prone snapshot.
#
# Source of truth: skills/caveman/SKILL.md in
#   https://github.com/JuliusBrussee/caveman
# Vendored to:     omp-extensions/caveman/prompts/caveman.SKILL.md
#
# The extension reads that vendored file at runtime and injects its body (minus
# YAML frontmatter) into the system prompt. "Staying updated" is therefore one
# command: re-run this script, review the diff, commit.
#
# Usage:
#   scripts/update-caveman-prompt.sh          # fetch upstream, write if changed
#   scripts/update-caveman-prompt.sh --check   # exit 3 if the vendored copy is
#                                              # stale (writes nothing) — for CI
#   scripts/update-caveman-prompt.sh -h
#
# Exit codes: 0 up-to-date or updated · 2 usage · 3 stale (--check) · 1 missing
#   curl · 4 fetch failed · 5 fetched content failed the sanity guard.
#
# Env overrides (used by the test suite; also handy for pinning a ref):
#   CAVEMAN_UPSTREAM_REF   git ref to fetch (default: main)
#   CAVEMAN_UPSTREAM_URL   full raw URL (overrides REF-derived default)
#   CAVEMAN_PROMPT_DEST    destination path (default: the vendored path above)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${CAVEMAN_UPSTREAM_REF:-main}"
URL="${CAVEMAN_UPSTREAM_URL:-https://raw.githubusercontent.com/JuliusBrussee/caveman/$REF/skills/caveman/SKILL.md}"
DEST="${CAVEMAN_PROMPT_DEST:-$REPO_ROOT/omp-extensions/caveman/prompts/caveman.SKILL.md}"

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help)
      sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "update-caveman-prompt.sh: unknown argument '$arg' (use --check, -h)" >&2
      exit 2
      ;;
  esac
done

command -v curl >/dev/null 2>&1 || {
  echo "update-caveman-prompt.sh: curl is required but was not found on PATH" >&2
  exit 1
}

TMP="$(mktemp "${TMPDIR:-/tmp}/caveman-prompt.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL "$URL" -o "$TMP"; then
  echo "update-caveman-prompt.sh: failed to fetch $URL" >&2
  exit 4
fi

# Sanity guard: a 404 HTML page or a truncated body would otherwise overwrite a
# good vendored copy. Require the skill's own frontmatter marker before writing.
if ! grep -q '^name: caveman$' "$TMP"; then
  echo "update-caveman-prompt.sh: fetched content is missing the 'name: caveman' frontmatter — refusing to write (URL: $URL)" >&2
  exit 5
fi

if [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
  echo "Already up to date: $DEST"
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "STALE: $DEST differs from upstream ($URL). Re-run without --check to update." >&2
  exit 3
fi

mkdir -p "$(dirname "$DEST")"
cp "$TMP" "$DEST"
echo "Updated $DEST"
echo "  from $URL"
