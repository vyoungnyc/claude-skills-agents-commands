#!/bin/bash
# scripts/update-caveman-prompt.test.sh — tests for the caveman prompt updater.
#
# Style follows the other *.test.sh suites: set -euo pipefail, fail() to stderr,
# mktemp -d sandbox, cleanup trap, flat assertions, no framework. No network:
# the script fetches with curl, so fixtures are served via file:// URLs and the
# destination is redirected with CAVEMAN_PROMPT_DEST.

set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo "curl is required to run tests" >&2; exit 1; }

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$THIS_DIR/update-caveman-prompt.sh"
[ -f "$SCRIPT" ] || { echo "cannot find update-caveman-prompt.sh next to test" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

SUITE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$SUITE_TMP"; }
trap cleanup EXIT

# A valid upstream fixture: the sanity guard requires a literal `name: caveman`.
GOOD="$SUITE_TMP/good.md"
cat > "$GOOD" <<'EOF'
---
name: caveman
description: test fixture
---
Respond terse like smart caveman.
EOF

# A bogus fixture (e.g. a 404 HTML body) with no caveman frontmatter.
BAD="$SUITE_TMP/bad.md"
printf '<!doctype html><title>404</title>\n' > "$BAD"

run() { bash "$SCRIPT" "$@"; }

# ============================================================ (1) fetch writes DEST
DEST="$SUITE_TMP/dest1.md"
CAVEMAN_UPSTREAM_URL="file://$GOOD" CAVEMAN_PROMPT_DEST="$DEST" run >/dev/null 2>&1 \
  || fail "(1) update exited nonzero on a valid fetch"
[ -f "$DEST" ] || fail "(1) DEST not written"
cmp -s "$GOOD" "$DEST" || fail "(1) DEST content differs from fetched upstream"

# ============================================================ (2) idempotent re-run
OUT="$(CAVEMAN_UPSTREAM_URL="file://$GOOD" CAVEMAN_PROMPT_DEST="$DEST" run 2>&1)"
echo "$OUT" | grep -q "Already up to date" || fail "(2) second run not idempotent: $OUT"

# ============================================================ (3) --check clean == 0
CAVEMAN_UPSTREAM_URL="file://$GOOD" CAVEMAN_PROMPT_DEST="$DEST" run --check >/dev/null 2>&1 \
  || fail "(3) --check reported drift when vendored copy matches upstream"

# ============================================================ (4) --check stale == 3, no write
printf 'stale local edit\n' > "$DEST"
set +e
CAVEMAN_UPSTREAM_URL="file://$GOOD" CAVEMAN_PROMPT_DEST="$DEST" run --check >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "(4) --check on stale copy exited $rc, expected 3"
grep -q "stale local edit" "$DEST" || fail "(4) --check must not modify DEST"

# ============================================================ (5) sanity guard == 5, no write
DEST5="$SUITE_TMP/dest5.md"
set +e
CAVEMAN_UPSTREAM_URL="file://$BAD" CAVEMAN_PROMPT_DEST="$DEST5" run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 5 ] || fail "(5) fetch of content missing frontmatter exited $rc, expected 5"
[ -e "$DEST5" ] && fail "(5) guard must not write DEST from bogus content"

# ============================================================ (6) fetch failure == 4
DEST6="$SUITE_TMP/dest6.md"
set +e
CAVEMAN_UPSTREAM_URL="file://$SUITE_TMP/does-not-exist.md" CAVEMAN_PROMPT_DEST="$DEST6" run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "(6) failed fetch exited $rc, expected 4"
[ -e "$DEST6" ] && fail "(6) failed fetch must not write DEST"

# ============================================================ (7) bad arg == 2
set +e
run --bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "(7) unknown arg exited $rc, expected 2"

# ============================================================ (8) missing curl == 1
# Build a PATH mirroring the real one MINUS curl; skip if curl can't be hidden.
NOCURL_BIN="$SUITE_TMP/nocurl-bin"
mkdir -p "$NOCURL_BIN"
_oldifs="$IFS"; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for tool in bash sed grep cmp mktemp cp mkdir basename dirname rm; do
    [ -e "$d/$tool" ] && [ ! -e "$NOCURL_BIN/$tool" ] && ln -s "$d/$tool" "$NOCURL_BIN/$tool"
  done
done
IFS="$_oldifs"
if command -v curl >/dev/null 2>&1 && ! PATH="$NOCURL_BIN" command -v curl >/dev/null 2>&1; then
  set +e
  PATH="$NOCURL_BIN" CAVEMAN_UPSTREAM_URL="file://$GOOD" CAVEMAN_PROMPT_DEST="$SUITE_TMP/dest8.md" \
    bash "$SCRIPT" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "(8) missing curl exited $rc, expected 1"
fi

echo "PASS: update-caveman-prompt.test.sh (8 cases)"
