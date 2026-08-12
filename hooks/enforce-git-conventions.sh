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
#
# Architecture: the command string is split into quote-aware SEGMENTS at
# unquoted separators (&&, ||, ;, |, &, newline), and every check runs
# per segment — a chained `cd x && git push --force` is enforced exactly
# like a bare one, and a segment merely MENTIONING a dangerous command
# inside quotes is never treated as one. Within a git segment, checks
# operate on TOKENS (quotes removed, content kept, commit-message values
# dropped): shell quoting is invisible to git, so `git push origin "main"`
# and `git commit "--no-verify"` are exactly equivalent to their unquoted
# forms and must be caught, while a commit MESSAGE that quotes a dangerous
# command remains plain text because message values never enter the token
# view the checks read.

INPUT=$(cat)

# Fast path: skip jq parsing entirely when "git" appears nowhere. A bare
# substring probe over-triggers on commands merely mentioning git, but
# those fall through the segment classification below harmlessly. (A
# stricter '"git ' probe was a real bypass: it only matched commands
# STARTING with git, so chained invocations skipped every check.)
[[ "$INPUT" == *git* ]] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- Segment machinery -------------------------------------------------

# Split into segments at unquoted separators. Quote-aware: separators
# inside quotes are content. Known accepted limitation: an unquoted
# heredoc body containing a bare `git commit` line would be seen as a
# segment — commit heredocs are conventionally wrapped in "$(cat <<'EOF'
# ...)" where quotes protect them.
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

# Token view of a segment: one token per line, quote CHARACTERS removed
# but their CONTENT kept (shell quoting is invisible to git), and
# -m/--message VALUES dropped so free-text commit messages can never trip
# the argument checks. Multi-line quoted content stays inside one token
# (newline only separates tokens outside quotes).
_seg_tokens() {
  local cmd="$1" i c q="" tok="" tok_started=0 skip_next=0 n
  n=${#cmd}
  _flush() {
    [ "$tok_started" -eq 1 ] || return 0
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
    else
      case "$tok" in
        -m|--message) skip_next=1; printf '%s\n' "$tok" ;;
        --message=*)  printf '%s\n' "--message=<msg>" ;;
        -m?*)         printf '%s\n' "-m<msg>" ;;
        *)            printf '%s\n' "$tok" ;;
      esac
    fi
    tok=""; tok_started=0
  }
  for ((i = 0; i < n; i++)); do
    c="${cmd:$i:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""; else tok="$tok$c"; fi
      continue
    fi
    case "$c" in
      \"|\') q="$c"; tok_started=1 ;;
      ' '|'	'|'
') _flush ;;
      '('|')'|'{'|'}') _flush ;;  # shell grouping metacharacters are token
                                  # boundaries: (git push origin main) must
                                  # tokenize as git/push/origin/main, not
                                  # leave "(git" and "main)" glued together
      *) tok="$tok$c"; tok_started=1 ;;
    esac
  done
  _flush
}

# Strip env-assignment/env prefixes and git global options from a
# token-view string so classification can anchor on "git <subcommand>".
# Quoted assignment values are a known limitation of the sed-based strip;
# unquoted values cover the practical cases.
_normalize_git() {
  local s="$1" prev
  while true; do
    prev="$s"
    s=$(echo "$s" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
    s=$(echo "$s" | sed -E 's/^env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
    # Command-position shell wrappers: `if git ...`, `then git ...`,
    # `command git ...`, `exec git ...` all execute git — leaving the
    # keyword attached made the anchored ^git match skip every check.
    s=$(echo "$s" | sed -E 's/^(if|then|else|elif|while|until|do|command|builtin|exec|nohup|time|!)[[:space:]]+//')
    s=$(echo "$s" | sed -E 's/^(git[[:space:]]+)(-[Cc]|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)[[:space:]]+[^[:space:]]+[[:space:]]+/\1/')
    s=$(echo "$s" | sed -E 's/^(git[[:space:]]+)(-[pP]|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--no-optional-locks|--no-lazy-fetch|--html-path|--man-path|--info-path)[[:space:]]+/\1/')
    s=$(echo "$s" | sed -E 's/^(git[[:space:]]+)--[a-zA-Z][a-zA-Z0-9_-]*=[^[:space:]]+[[:space:]]+/\1/')
    [ "$s" = "$prev" ] && break
  done
  printf '%s' "$s"
}

# Extract the FIRST -m/--message value from a segment by ordered,
# quote-aware tokenization — git constructs the message in argument order,
# and -m / --message are aliases. Known accepted limitation:
# backslash-escaped quotes are not interpreted.
_first_commit_msg() {
  # n is assigned separately: within a single `local` command, bash
  # expands every word BEFORE performing any assignment, so `n=${#cmd}`
  # on the declaration line would read the caller's cmd and set n=0.
  local cmd="$1" i c q="" tok="" want=0 n
  n=${#cmd}
  _emit_tok() {
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

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# --- Per-segment enforcement -------------------------------------------

while IFS= read -r -d $'\x01' SEG; do
  [ -n "${SEG//[[:space:]]/}" ] || continue

  # Token view: quotes dissolved into content, message values masked.
  SEG_ARGS=$(_seg_tokens "$SEG" | tr '\n' ' ')
  # Classify on the normalized token view — a segment whose git spelling
  # lives only inside a quoted string never reaches here as ^git.
  SEG_NORM=$(_normalize_git "$SEG_ARGS")
  printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]' || continue

  # --- Push checks ---
  if printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]+push([[:space:]]|$)'; then
    HAS_FORCE=false
    HAS_FORCE_FLAG=false
    HAS_PLUS_REFSPEC=false
    HAS_LEASE=false
    echo "$SEG_NORM" | grep -qE '(^|[[:space:]])--force-with-lease([=[:space:]]|$)' && HAS_LEASE=true
    _STRIPPED_LEASE=$(echo "$SEG_NORM" | sed -E 's/--force-with-lease(=[^[:space:]]+)?//g')
    echo "$_STRIPPED_LEASE" | grep -qE '^git[[:space:]]+push[[:space:]]+(.*[[:space:]])?(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))' && { HAS_FORCE=true; HAS_FORCE_FLAG=true; }

    _PUSH_ARGS=$(echo "$SEG_NORM" | sed -E 's/^git[[:space:]]+push[[:space:]]*//')
    if echo "$_PUSH_ARGS" | grep -qE '(^|[[:space:]])\+[^[:space:]]+'; then
      HAS_FORCE=true
      HAS_PLUS_REFSPEC=true
    fi

    if $HAS_FORCE; then
      if $HAS_FORCE_FLAG && $HAS_LEASE; then
        deny "Cannot combine --force with --force-with-lease: --force overrides the lease safety. Use --force-with-lease alone."
      elif $HAS_PLUS_REFSPEC; then
        if $HAS_LEASE; then
          deny "Force push via + refspec prefix overrides --force-with-lease safety. Remove the + prefix and rely on --force-with-lease instead."
        else
          deny "Force push via + refspec prefix is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
        fi
      else
        deny "Force push is not allowed. Use --force-with-lease if absolutely necessary, or rebase instead."
      fi
    fi

    if echo "$SEG_NORM" | grep -qE '^git[[:space:]]+push[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([^[:space:]]+[[:space:]]+)?(refs/heads/)?(main|master)([[:space:]]|$)' || \
       echo "$SEG_NORM" | grep -qE '^git[[:space:]]+push[[:space:]]+.*:(refs/heads/)?(main|master)([[:space:]]|$)' || \
       echo "$SEG_NORM" | grep -qE '^git[[:space:]]+push[[:space:]]+.*(-d|--delete)[[:space:]]+(refs/heads/)?(main|master)([[:space:]]|$)' || \
       echo "$SEG_NORM" | grep -qE '^git[[:space:]]+push[[:space:]]+.*[[:space:]](--all|--mirror)([[:space:]]|$)'; then
      deny "Direct push to main/master is not allowed (including --all/--mirror which can update protected branches). Use a feature branch and create a PR."
    fi
  fi

  # --- --no-verify / -n (commit/push) ---
  # SEG_NORM's message values are masked, so a "-n" or "--no-verify"
  # inside free message text can never false-positive here — and a QUOTED
  # real argument ("--no-verify") is dissolved into a real token.
  if printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]+(commit|push)([[:space:]]|$)'; then
    if echo "$SEG_NORM" | grep -qE '^git[[:space:]]+(commit|push)[[:space:]]+.*--no-verify' || \
       echo "$SEG_NORM" | grep -qE '^git[[:space:]]+commit[[:space:]]+.*[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
      deny "Skipping hooks with --no-verify is not allowed. Fix the underlying issue instead."
    fi
  fi

  # --- Conventional commit message ---
  if printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]+commit([[:space:]]|$)'; then
    COMMIT_MSG=$(_first_commit_msg "$SEG" || true)
    # A message built by command substitution (-m "$(cat <<'EOF' ...)")
    # is opaque to the tokenizer — fall through to the heredoc extractor.
    case "$COMMIT_MSG" in '$('*) COMMIT_MSG="" ;; esac
    # Only the subject (first line) is format-validated — bodies are free text.
    COMMIT_MSG=$(printf '%s\n' "$COMMIT_MSG" | head -1)

    if [ -z "$COMMIT_MSG" ]; then
      COMMIT_MSG=$(printf '%s\n' "$SEG" | sed -n "/<<[[:space:]]*['\"]\\{0,1\\}EOF['\"]\\{0,1\\}/,/^[[:space:]]*EOF/{/EOF/d;/^[[:space:]]*$/d;p;}" | head -1 | sed 's/^[[:space:]]*//')
    fi

    if [ -z "$COMMIT_MSG" ]; then
      deny "Commit must include an inline message (-m or heredoc) so conventional format can be validated. Use: git commit -m \"type(scope): subject\""
    fi

    # type(scope): subject — scope may be a comma-separated list.
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
  fi

  # --- Branch naming on checkout -b / switch -c ---
  if printf '%s' "$SEG_NORM" | grep -qE '^git[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+'; then
    BRANCH_NAME=$(echo "$SEG_NORM" | sed -En 's/.*(checkout[[:space:]]+-b|switch[[:space:]]+-c)[[:space:]]+([^[:space:]]*).*/\2/p')
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
done < <(_split_segments "$COMMAND")

# All checks passed
exit 0
