---
name: worktree-git-commands
description: In worktree-isolated runs, git commands must be issued as separate plain Bash calls — no compound chains, redirects, or heredocs combined with other commands
metadata:
  type: feedback
---

When running as a worktree-isolated agent in this repo, issue git commands as **separate, plain** Bash calls. `git add -A && git commit -F - <<'EOF' ... EOF | tail -5` is refused; `git add -A` then `git commit -F - <<'EOF' ... EOF` alone works.

**Why:** the isolation guard has to verify every git operation targets this agent's own worktree, and it refuses commands it cannot statically parse (chained `&&`, pipes, redirects around a heredoc). This is a hard refusal, not a warning — the command does not run at all.

**How to apply:** stage in one call, commit in the next. The commit body must still use the `git commit -F -` heredoc form, because the repo's conventional-commits hook cannot parse a multi-line `-m`. Combining the two constraints: one bare `git add -A`, then one bare heredoc commit, then a separate call for any `git log`/`git status` verification.
