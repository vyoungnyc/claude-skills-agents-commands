#!/bin/bash
# PreToolUse hook: Enforce git workflow conventions.
# Triggered on: Bash commands matching git operations.
#
# Enforces:
# 1. Conventional commit messages (feat/fix/refactor/test/docs/chore)
# 2. Branch naming (feature/*, fix/*, refactor/*)
# 3. Block force-push
# 4. Block push to main/master directly
# 5. Block --no-verify

INPUT=$(cat)

# Fast path: skip jq parsing entirely when "git" appears nowhere. The
# previous pattern ('"git ') only matched commands STARTING with git, so
# any chained invocation ("cd x && git push --force ...") bypassed every
# check in this hook. A substring probe over-triggers on commands merely
# mentioning git, but those fall through the real parsing below harmlessly.
[[ "$INPUT" == *git* ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Normalize: strip git global options so enforcement matches the subcommand.
# Handles: -c key=val, --no-pager, --git-dir=path, -C path, -p, etc.
# After stripping, NORMALIZED starts with "git <subcommand> ..."
# Note: use POSIX character classes — macOS sed does not support \s / \S in ERE
#
# Global flags that take a mandatory argument (consume next token):
#   -C <path>, -c <key=val>, --git-dir <path>, --work-tree <path>,
#   --namespace <name>, --super-prefix <path>, --config-env <name=envvar>
# Global flags that are standalone (do NOT consume next token):
#   -p/--paginate, -P/--no-pager, --no-replace-objects, --bare,
#   --literal-pathspecs, --glob-pathspecs, --noglob-pathspecs,
#   --no-optional-locks, --no-lazy-fetch, --html-path, --man-path, --info-path
NORMALIZED="$COMMAND"
# Iteratively strip global options from the front (after "git ")
while true; do
  PREV="$NORMALIZED"
  # Strip flags that take a mandatory argument: -C, -c, --git-dir, --work-tree, --namespace, --super-prefix, --config-env
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)(-[Cc]|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)[[:space:]]+[^[:space:]]+[[:space:]]+/\1/')
  # Strip standalone flags: -p, -P, --paginate, --no-pager, --bare, --no-replace-objects, etc.
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)(-[pP]|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--no-optional-locks|--no-lazy-fetch|--html-path|--man-path|--info-path)[[:space:]]+/\1/')
  # Strip long options with = value (e.g. --git-dir=/foo)
  NORMALIZED=$(echo "$NORMALIZED" | sed -E 's/^(git[[:space:]]+)--[a-zA-Z][a-zA-Z0-9_-]*=[^[:space:]]+[[:space:]]+/\1/')
  [ "$NORMALIZED" = "$PREV" ] && break
done

# Quote-stripped view for the whole-string greps below: with the fast path
# widened to any command containing "git", a command merely QUOTING e.g.
# "git push --force" in an echo/commit message must not trip the push or
# no-verify checks. Real arguments are never quoted away by this (refspecs
# and flags are unquoted in practice).
UNQUOTED=$(printf '%s' "$NORMALIZED" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# --- Push-specific checks (skip for non-push commands) ---
if echo "$UNQUOTED" | grep -qE 'git\s+push(\s|$)'; then

  # Block force push
  HAS_FORCE=false
  HAS_FORCE_FLAG=false
  HAS_PLUS_REFSPEC=false
  HAS_LEASE=false
  echo "$UNQUOTED" | grep -qE '(^|[[:space:]])--force-with-lease([=[:space:]]|$)' && HAS_LEASE=true
  _STRIPPED_LEASE=$(echo "$UNQUOTED" | sed -E 's/--force-with-lease(=[^[:space:]]+)?//g')
  echo "$_STRIPPED_LEASE" | grep -qE 'git\s+push\s+(.*\s)?(--force(\s|=|$)|-[a-zA-Z]*f[a-zA-Z]*(\s|$))' && { HAS_FORCE=true; HAS_FORCE_FLAG=true; }

  # Detect + refspec prefix (per-ref force push)
  _PUSH_ARGS=$(echo "$UNQUOTED" | sed -E 's/^git[[:space:]]+push[[:space:]]*//')
  if echo "$_PUSH_ARGS" | grep -qE '(^|[[:space:]])\+[^[:space:]]+'; then
    HAS_FORCE=true
    HAS_PLUS_REFSPEC=true
  fi

  if $HAS_FORCE; then
    if $HAS_FORCE_FLAG && $HAS_LEASE; then
      REASON="Cannot combine --force with --force-with-lease: --force overrides the lease safety. Use --force-with-lease alone."
    elif $HAS_PLUS_REFSPEC; then
      if $HAS_LEASE; then
        REASON="Force push via + refspec prefix overrides --force-with-lease safety. Remove the + prefix and rely on --force-with-lease instead."
      else
        REASON="Force push via + refspec prefix is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
      fi
    else
      REASON="Force push is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
    fi
    jq -n --arg reason "$REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi

  # Block push to main/master (including refspecs, --delete, --all, --mirror)
  if echo "$UNQUOTED" | grep -qE 'git\s+push\s+(-\S+\s+)*(\S+\s+)?(refs/heads/)?(main|master)(\s|$)' || \
     echo "$UNQUOTED" | grep -qE 'git\s+push\s+.*:(refs/heads/)?(main|master)(\s|$)' || \
     echo "$UNQUOTED" | grep -qE 'git\s+push\s+.*(-d|--delete)\s+(refs/heads/)?(main|master)(\s|$)' || \
     echo "$UNQUOTED" | grep -qE 'git\s+push\s+.*\s(--all|--mirror)(\s|$)'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Direct push to main/master is not allowed (including --all/--mirror which can update protected branches). Use a feature branch and create a PR."
      }
    }'
    exit 0
  fi

fi

# --- Block --no-verify / -n (commit/push) ---
if echo "$UNQUOTED" | grep -qE 'git\s+(commit|push)(\s|$)'; then
  # --no-verify: check full command (long form can't appear unquoted inside -m "...")
  # -n shorthand: only check options before -m to avoid false positives in message text
  # Note: -n means --no-verify for commit, --dry-run for push — only check commit
  OPTS_BEFORE_MSG=$(echo "$UNQUOTED" | sed -E 's/(-m|--message)[[:space:]]+.*//')
  if echo "$UNQUOTED" | grep -qE 'git\s+(commit|push)\s+.*--no-verify' || \
     echo "$OPTS_BEFORE_MSG" | grep -qE 'git\s+commit\s+.*\s-[a-zA-Z]*n[a-zA-Z]*(\s|$)'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Skipping hooks with --no-verify is not allowed. Fix the underlying issue instead."
      }
    }'
    exit 0
  fi
fi

# --- Validate conventional commit messages ---
# The command string may chain several invocations (`git add . && git
# commit -m A ; git commit -m B`) — validating only the first commit would
# let every later one bypass the hook. Split into segments at unquoted
# separators (&&, ||, ;, |, &, newline) and validate EVERY segment that is
# a git commit. Quote-aware: separators inside quotes are content. Known
# accepted limitation: an unquoted heredoc body containing a bare `git
# commit` line would be seen as a segment — commit heredocs are
# conventionally wrapped in "$(cat <<'EOF' ...)" where quotes protect them.
_split_segments() {
  local cmd="$1" i c q="" seg="" n
  n=${#cmd}
  for ((i = 0; i < n; i++)); do
    c="${cmd:$i:1}"
    if [ -n "$q" ]; then
      seg="$seg$c"
      [ "$c" = "$q" ] && q=""
      continue
    fi
    case "$c" in
      \"|\') q="$c"; seg="$seg$c" ;;
      '&'|'|'|';'|'
') printf '%s\x01' "$seg"; seg="" ;;
      *) seg="$seg$c" ;;
    esac
  done
  printf '%s\x01' "$seg"
}

# _normalize_git <segment> — strip git global options from a single
# segment, same iterative stripping applied to the whole command above.
_normalize_git() {
  local s="$1" prev
  while true; do
    prev="$s"
    # Strip environment-assignment prefixes (FOO=1 git ..., env FOO=1
    # git ...) — leaving them in place made the anchored ^git match skip
    # validation entirely, a full bypass. Quoted assignment values are a
    # known limitation (the sed stops at the first space); unquoted
    # values cover the practical cases.
    s=$(echo "$s" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
    s=$(echo "$s" | sed -E 's/^env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
    s=$(echo "$s" | sed -E 's/^[[:space:]]*//; s/^(git[[:space:]]+)(-[Cc]|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)[[:space:]]+[^[:space:]]+[[:space:]]+/\1/')
    s=$(echo "$s" | sed -E 's/^(git[[:space:]]+)(-[pP]|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--no-optional-locks|--no-lazy-fetch|--html-path|--man-path|--info-path)[[:space:]]+/\1/')
    s=$(echo "$s" | sed -E 's/^(git[[:space:]]+)--[a-zA-Z][a-zA-Z0-9_-]*=[^[:space:]]+[[:space:]]+/\1/')
    [ "$s" = "$prev" ] && break
  done
  printf '%s' "$s"
}

if echo "$NORMALIZED" | grep -qE 'git\s+commit'; then
  # Extract the FIRST -m/--message value by tokenizing the command as
  # ordered, quote-aware shell words — git constructs the message in
  # argument order, and -m / --message are aliases. A raw substring
  # search (the previous approach) had two failure modes: a subject
  # CONTAINING the literal text " --message" was mistaken for the option,
  # and any --message occurrence was preferred over an earlier -m. The
  # tokenizer only treats a spelling as an option when it is a whole
  # unquoted token, and takes whichever message flag appears first.
  # Known accepted limitation: backslash-escaped quotes are not
  # interpreted (rare in commit commands; the subject line is virtually
  # always before any such construct).
  _first_commit_msg() {
    # n is assigned in a separate statement: within a single `local`
    # command, bash expands every word BEFORE performing any of the
    # assignments, so `n=${#cmd}` on the same line would read the
    # caller's (usually unset) cmd and set n=0, skipping the whole loop.
    local cmd="$1" i c q="" tok="" want=0 n
    n=${#cmd}
    _emit_tok() {
      # $tok is complete. Returns 0 (and prints) when it yields the message.
      if [ "$want" -eq 1 ]; then printf '%s' "$tok"; return 0; fi
      case "$tok" in
        -m|--message) want=1 ;;
        --message=*)  printf '%s' "${tok#--message=}"; return 0 ;;
        --*)          : ;;
        -m*)          printf '%s' "${tok#-m}"; return 0 ;;
        -[a-zA-Z]*m)  want=1 ;;  # combined short flags ending in m (-am, -sm)
      esac
      return 1
    }
    for ((i = 0; i < n; i++)); do
      c="${cmd:$i:1}"
      if [ -n "$q" ]; then
        if [ "$c" = "$q" ]; then q=""; else tok="$tok$c"; fi
        continue
      fi
      case "$c" in
        \") q='"' ;;
        \') q="'" ;;
        ' '|'	'|'
') if [ -n "$tok" ]; then _emit_tok && return 0; tok=""; fi ;;
        *) tok="$tok$c" ;;
      esac
    done
    [ -n "$tok" ] && { _emit_tok && return 0; }
    return 1
  }
  # Validate EVERY git-commit segment independently — command boundaries
  # matter: only checking the first would let `git commit -m "fix: ok" &&
  # git commit -m "junk"` slip the second one through.
  while IFS= read -r -d $'\x01' SEG; do
    # Is this segment a git commit? Test with quoted spans removed so a
    # segment merely MENTIONING "git commit" inside a string is not
    # validated as one.
    SEG_UNQUOTED=$(printf '%s' "$SEG" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
    printf '%s' "$SEG_UNQUOTED" | grep -qE '(^|[[:space:]])git[[:space:]]' || continue
    SEG_NORM=$(_normalize_git "${SEG#"${SEG%%[![:space:]]*}"}")
    printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]+commit([[:space:]]|$)' || continue

    COMMIT_MSG=$(_first_commit_msg "$SEG" || true)
    # A message built by command substitution (-m "$(cat <<'EOF' ...)")
    # is opaque to the tokenizer — fall through to the heredoc extractor.
    case "$COMMIT_MSG" in '$('*) COMMIT_MSG="" ;; esac
    # Only the subject (first line) is format-validated — bodies are free text.
    COMMIT_MSG=$(printf '%s\n' "$COMMIT_MSG" | head -1)

    # 2. Heredoc-style: $(cat <<'EOF' ... EOF) — first non-blank line after the marker
    if [ -z "$COMMIT_MSG" ]; then
      COMMIT_MSG=$(printf '%s\n' "$SEG" | sed -n "/<<[[:space:]]*['\"]\\{0,1\\}EOF['\"]\\{0,1\\}/,/^[[:space:]]*EOF/{/EOF/d;/^[[:space:]]*$/d;p;}" | head -1 | sed 's/^[[:space:]]*//')
    fi

    if [ -z "$COMMIT_MSG" ]; then
      # No message extractable — editor-based commit or --amend without -m.
      # Deny so the user provides an inline message we can validate.
      jq -n '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "Commit must include an inline message (-m or heredoc) so conventional format can be validated. Use: git commit -m \"type(scope): subject\""
        }
      }'
      exit 0
    fi

    # Check conventional commit format: type(scope): subject. Scope may be a
    # comma-separated list (fix(hooks,scripts): ...) — common practice for
    # changes spanning a few areas, and previously rejected.
    if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|refactor|test|docs|chore|ci|perf|build|style|revert)(\([a-zA-Z0-9_-]+(,[a-zA-Z0-9_-]+)*\))?(!)?:\s+.+'; then
      jq -n --arg msg "$COMMIT_MSG" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Commit message does not follow conventional commits format.\nGot: \"" + $msg + "\"\nExpected: type(scope): subject\nValid types: feat, fix, refactor, test, docs, chore, ci, perf, build, style, revert")
        }
      }'
      exit 0
    fi
  done < <(_split_segments "$COMMAND")
fi

# --- Validate branch naming on checkout -b / switch -c ---
# Use NORMALIZED so global options (git -C repo checkout -b ...) don't bypass the check
if echo "$UNQUOTED" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)\s+'; then
  BRANCH_NAME=$(echo "$UNQUOTED" | sed -En 's/.*(checkout[[:space:]]*-b|switch[[:space:]]*-c)[[:space:]]+([^[:space:]]*).*/\2/p')
  if [ -n "$BRANCH_NAME" ]; then
    if ! echo "$BRANCH_NAME" | grep -qE '^(feature|fix|refactor|hotfix|release)/[a-zA-Z0-9_.-]+$'; then
      jq -n --arg branch "$BRANCH_NAME" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Branch name does not follow naming convention.\nGot: \"" + $branch + "\"\nExpected: feature/*, fix/*, refactor/*, hotfix/*, release/*")
        }
      }'
      exit 0
    fi
  fi
fi

# All checks passed
exit 0
