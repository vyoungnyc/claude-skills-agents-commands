---
name: pr-fix-loop
description: "Push fixes to a PR, trigger Codex review, resolve addressed threads, and poll for new feedback in a fix-review loop until clean."
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

You manage an automated fix-review-poll loop for a GitHub PR with Codex (or similar bot) code review.

## Inputs

- `pr_number`: `{pr_number}`
- `poll_interval`: `{poll_interval}` (default: 5 minutes)
- `max_poll_time`: `{max_poll_time}` (default: 15 minutes)

## Mission

Automate the cycle of: fix review comments → push → trigger re-review → poll for new comments → repeat until clean.

## Setup

1. Detect the repo owner/name from `git remote -v`.
2. Detect the current branch from `git branch --show-current`.
3. Fetch the PR to confirm it exists and get its head branch.
4. Check `git status` for uncommitted local changes.

## Phase 0: Assess starting state

Determine what to do first based on the combination of local changes and remote review state:

| Local changes? | Unresolved bot threads? | Action |
|---|---|---|
| Yes | Any | Commit and push local changes first, then proceed to Phase 1 |
| No | Yes | **Fresh PR with existing comments** — go to Phase 1 to fix them |
| No | No | **Clean PR** — add `@codex review` comment to trigger initial review, then Phase 3 (poll) |

This means `/pr-fix-loop` works on:
- A PR you just pushed fixes to (commit + resolve + poll)
- A fresh PR with existing bot comments but no local changes (fix + push + resolve + poll)
- A clean PR with no comments yet (just poll and wait)

## Phase 1: Fix and push

1. **Fetch unresolved review threads** on PR `{pr_number}` using the GitHub GraphQL API:
   ```
   gh api graphql ... reviewThreads ... select(.isResolved == false)
   ```

2. **If there are unresolved threads from a bot reviewer** (e.g. `chatgpt-codex-connector[bot]`):
   a. Read each comment to understand the requested change — pay attention to the file path, line number, and the specific issue described.
   b. Read the referenced file(s) to understand current code.
   c. Implement the fix.
   d. Stage and commit with a conventional commit message describing what was fixed.
   e. Push to the PR branch.

3. **If there are NO unresolved threads**: skip to Phase 3 (poll).

## Phase 2: Resolve and trigger review

After pushing fixes:

1. **Reply to each fixed thread** explaining the fix and referencing the commit SHA:
   ```
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
     -f body="Fixed in {sha}. {explanation}"
   ```

2. **Resolve each thread** via GraphQL:
   ```
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "{id}"}) { thread { isResolved } } }'
   ```

3. **Trigger re-review** by adding a PR comment:
   ```
   gh api repos/{owner}/{repo}/issues/{pr_number}/comments -f body="@codex review"
   ```

## Phase 3: Background polling

Launch a **background agent** to poll for new review comments. The agent:

1. **Polls every `{poll_interval}` minutes** (default 5) for up to `{max_poll_time}` minutes (default 15).

2. **On each poll**, check:
   a. Unresolved review threads from bot reviewers.
   b. Latest review state (did the bot approve or react with thumbs-up?).

3. **Stop conditions** (any of these ends the loop):
   - No unresolved bot threads exist → done.
   - Bot's latest review is an approval or contains positive signal (thumbs-up, "LGTM", no issues) → done.
   - Max poll time reached with no new unresolved comments → done.

4. **If new unresolved comments appear**:
   - The polling agent reports back with the comment details.
   - The parent (you) then runs Phase 1 and Phase 2 again.
   - After pushing and resolving, restart Phase 3 with a fresh polling window.

## Rules

1. **Never force-push or use --no-verify.**
2. **Use conventional commit messages** (e.g. `fix(hooks): description`).
3. **Read files before editing** — understand current code before changing it.
4. **Only fix bot review comments** — do not modify code beyond what the review requests.
5. **Reply to every fixed thread** — explain what was changed and reference the commit.
6. **Resolve threads only after the fix is pushed** — not before.
7. **Timestamp awareness** — track when the last batch of comments was created so you don't re-process old resolved comments in the next poll cycle.

## Stop and notify

When polling ends (any stop condition met):

1. Report the final state:
   - How many review rounds were completed.
   - How many total comments were fixed.
   - Whether the bot approved or just stopped commenting.
2. Tell the user: "PR `{pr_number}` is ready for your final review."

## What to do in your first reply

1. Detect repo and branch.
2. Check `git status` for local changes.
3. Fetch current unresolved bot review threads on PR `{pr_number}`.
4. Report the starting state (local changes? existing comments? how many?).
5. Follow Phase 0 to determine the right entry point:
   - Local changes → commit, push, then Phase 1.
   - No local changes + unresolved comments → Phase 1 (fix existing comments).
   - No local changes + no comments → add `@codex review` comment to kick off the review, then Phase 3 (poll).
