---
name: pr-fix-loop
description: "Push fixes to a PR, resolve addressed threads, and poll for new feedback from Codex and users in a fix-review loop until clean."
args:
  - name: pr_number
    type: number
    required: true
    description: "The PR number to fix and monitor (e.g. 42)."
  - name: poll_interval
    type: number
    required: false
    description: "Minutes between polls (default: 5)."
  - name: max_poll_time
    type: number
    required: false
    description: "Maximum minutes to poll before stopping (default: 15)."
---

# Command: /pr-fix-loop

You manage an automated fix-review-poll loop for a GitHub PR with automated code review bots.

## Supported review bots

Recognize comments from any of these bot reviewers (match by author login):
- **Codex:** `chatgpt-codex-connector[bot]`
- **Cursor BugBot:** `cursor-bugbot[bot]` or similar Cursor review bot accounts
- **GitLab Copilot:** `gitlab-copilot[bot]` or similar GitLab AI reviewer accounts

When identifying bot review threads, match against all known bot logins above. Treat all bot reviewers equally — the same triage logic applies regardless of which bot posted the comment.

## Inputs

- `pr_number`: `{pr_number}`
- `poll_interval`: `{poll_interval}` (default: 5 minutes)
- `max_poll_time`: `{max_poll_time}` (default: 15 minutes)

## Mission

Automate the cycle of: fix review comments → push → poll for new comments → repeat until clean. Review bots automatically review on every push — no manual trigger needed.

## Setup

1. Detect the repo owner/name from `git remote -v`.
2. Detect the current branch from `git branch --show-current`.
3. Fetch the PR to confirm it exists and get its head branch.
4. Check `git status` for uncommitted local changes.

## Phase 0: Assess starting state

Determine what to do first based on the combination of local changes and remote review state:

| Local changes? | Unresolved threads? | Action |
|---|---|---|
| Yes | Any | Commit and push local changes first (review bots will auto-review the push), then proceed to Phase 1 |
| No | Yes | **Fresh PR with existing comments** — go to Phase 1 to fix them |
| No | No | **Clean PR** — go to Phase 3 (poll) and wait for review bots to review |

This means `/pr-fix-loop` works on:
- A PR you just pushed fixes to (commit + resolve + poll)
- A fresh PR with existing comments but no local changes (fix + push + resolve + poll)
- A clean PR with no comments yet (just poll and wait for bot auto-review)

## Phase 1: Fix and push

1. **Fetch unresolved review threads** on PR `{pr_number}` using the GitHub GraphQL API:
   ```
   gh api graphql ... reviewThreads ... select(.isResolved == false)
   ```

2. **If there are unresolved threads from any reviewer** (any supported review bot OR human users):
   a. Read each comment to understand the requested change — pay attention to the file path, line number, and the specific issue described.
   b. Read the referenced file(s) to understand current code.
   c. **Triage each comment** into one of three categories. Apply the same triage logic regardless of whether the comment is from a bot or a human user:

   ### Category A: Agree — fix it
   The comment is correct and actionable. Implement the fix.

   ### Category B: Disagree — push back
   The comment is wrong, conflicts with a previous fix, misunderstands the code, or would introduce a regression. **Do NOT fix it.** Instead:
   - If from Codex: reply with your explanation of why you disagree, what your current solution does, and why it's correct (or better), then end with `@codex review the feedback`.
   - If from another bot or a human user: reply with your explanation of why you disagree, what your current solution does, and why it's correct (or better).
   - Include specific reasoning: what the reviewer missed, what constraint they didn't account for, or how their suggestion conflicts with another fix.
   - **Do NOT resolve the thread.** Leave it open for the user or reviewer to respond.
   - Tag the comment internally as "disputed" so you track it.

   ### Category C: Unclear — ask for clarification
   The comment is ambiguous, could be interpreted multiple ways, or you're not sure if the fix would break something else. **Do NOT fix it.** Instead:
   - If from Codex: reply with `@codex review the feedback` followed by your analysis of the issue, the options you see, and what you need clarified.
   - If from another bot (Cursor BugBot, GitLab Copilot, etc.): reply with your analysis and what you need clarified.
   - If from a human user: reply with your analysis and what you need clarified.
   - **Do NOT resolve the thread.** Leave it open.
   - Tag the comment internally as "needs-clarification".

   d. For all Category A fixes: stage and commit with a conventional commit message, push to the PR branch. Review bots will automatically review the new push.

3. **If there are NO unresolved threads**: skip to Phase 3 (poll).

4. **Check for bot/user follow-ups on disputed threads:**
   On each poll cycle, also check unresolved threads you previously replied to (Category B or C). Look for new replies:
   - If a bot responds with a new comment that addresses your feedback and satisfies your concerns (e.g. concedes your point, provides a valid explanation, or the issue is resolved by context), **resolve the thread**.
   - If a bot responds but its reply does NOT satisfy your concerns, re-triage the reply as Category B (push back again) or Category C (ask for further clarification) and continue the loop.
   - If a user provides clarification or instructions **related to the original issue**, follow those instructions and fix accordingly.
   - If a reply is unrelated to the issue at hand (e.g. a different topic, a new feature request), ignore it — it's not a follow-up.
   - If the reviewer concedes or agrees with your pushback, resolve the thread.
   - If the user overrides your pushback with explicit instructions, implement what they asked.

## Phase 2: Resolve threads

After pushing fixes:

1. **Reply to each FIXED thread (Category A only)** explaining the fix and referencing the commit SHA:
   ```
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
     -f body="Fixed in {sha}. {explanation}"
   ```

2. **Resolve ONLY fixed threads (Category A)** via GraphQL. Do NOT resolve disputed (B) or needs-clarification (C) threads:
   ```
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "{id}"}) { thread { isResolved } } }'
   ```

3. Review bots will automatically review the new push — no manual trigger needed.

## Phase 3: Background polling

Launch a **background agent** to poll for new review comments. The agent:

1. **Polls every `{poll_interval}` minutes** (default 5) for up to `{max_poll_time}` minutes (default 15).

2. **On each poll**, check:
   a. Unresolved review threads from any reviewer (bot or user).
   b. **PR description reactions** — check if any bot reviewer reacted with 👍 or ✅ on the PR description itself (use GraphQL `pullRequest { reactions }`). This is the **mandatory approval gate**.
   c. **Complementary approval signals** — positive text like "Didn't find any major issues", "Nice work", "LGTM", or "No issues found" in a bot's review comment or thread reply. These reinforce approval but are NOT sufficient on their own.
   d. Whether 15 minutes have passed with no new comments from any reviewer.

3. **Stop conditions** (any of these ends the loop):
   - **Approved:** A bot reviewer reacted with 👍 or ✅ emoji on the PR description → done, PR is approved. Complementary positive text signals (e.g. "Didn't find any major issues") further confirm approval but the emoji on the PR description is the mandatory gate.
   - **Idle:** No new comments from any reviewer for 15 consecutive minutes (excluding disputed threads awaiting response) → done, but report that the bot has NOT formally approved (no 👍/✅ on PR description).
   - **Blocked on human:** Only remaining unresolved threads are disputed (Category B/C) awaiting human input → done, but report these threads to the user so they can weigh in.

4. **If new unresolved comments appear** (from any bot or user):
   - The polling agent reports back with the comment details.
   - The parent (you) then runs Phase 1 and Phase 2 again.
   - After pushing and resolving, restart Phase 3 with a fresh polling window.

## Rules

1. **Never force-push or use --no-verify.**
2. **Use conventional commit messages** (e.g. `fix(hooks): description`).
3. **Read files before editing** — understand current code before changing it.
4. **Only fix review comments** (bot or user) — do not modify code beyond what the review requests.
5. **Reply to every fixed thread** — explain what was changed and reference the commit.
6. **Resolve threads only after the fix is pushed** — not before. Never resolve disputed or needs-clarification threads.
7. **Timestamp awareness** — track when the last batch of comments was created so you don't re-process old resolved comments in the next poll cycle.
8. **Exercise judgment on reviewer feedback** — not every bot comment is correct. If the suggestion would break something, conflict with a prior fix, or misunderstand the code, push back with a clear explanation rather than blindly implementing it.
9. **Follow-up relevance** — when checking for replies on disputed threads, only act on responses that are directly related to the original issue. Ignore tangential or unrelated comments.

## Stop and notify

When polling ends (any stop condition met):

1. Report the final state:
   - How many review rounds were completed.
   - How many total comments were fixed (broken down by bot vs user comments).
   - How many comments were disputed (with links).
   - Whether the bot formally approved (👍/✅ on PR description), gave complementary positive signals (e.g. "No major issues"), or the loop ended due to idle timeout.
2. If there are disputed threads awaiting human input, list each one with:
   - The original reviewer comment (summary).
   - Your reply / reasoning.
   - What you need from the user to proceed.
3. Tell the user: "PR `{pr_number}` is ready for your final review."

## What to do in your first reply

1. Detect repo and branch.
2. Check `git status` for local changes.
3. Fetch current unresolved review threads on PR `{pr_number}` (from any supported bot or user).
4. Report the starting state (local changes? existing comments? how many? which bots?).
5. Follow Phase 0 to determine the right entry point:
   - Local changes → commit, push (bots auto-review), then Phase 1.
   - No local changes + unresolved comments → Phase 1 (fix existing comments).
   - No local changes + no comments → Phase 3 (poll and wait for bot auto-review).
