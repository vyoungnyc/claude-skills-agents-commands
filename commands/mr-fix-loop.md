---
name: mr-fix-loop
description: "Push fixes to a GitLab MR, resolve addressed discussions, fix pipeline failures locally, and poll for new feedback from bots and users in a fix-review loop until clean."
args:
  - name: mr_iid
    type: number
    required: true
    description: "The MR IID (internal ID shown in the GitLab UI, e.g. 42)."
  - name: poll_interval
    type: number
    required: false
    description: "Minutes between polls (default: 1)."
  - name: max_poll_time
    type: number
    required: false
    description: "Maximum minutes to poll before stopping (default: 15)."
---

# Command: /mr-fix-loop

You manage an automated fix-review-poll loop for a GitLab Merge Request with automated code review bots.

## Supported review bots

Recognize comments from any of these bot reviewers (match by author username):
- **GitLab Duo:** `gitlab-duo[bot]` or similar GitLab AI reviewer accounts
- **GitLab Duo Code Review:** `gitlab-code-review[bot]` or similar
- **Cursor BugBot:** `cursor-bugbot[bot]` or similar Cursor review bot accounts
- **Codex:** `chatgpt-codex-connector[bot]` (if integrated cross-platform)

When identifying bot review discussions, match against all known bot usernames above. Treat all bot reviewers equally — the same triage logic applies regardless of which bot posted the comment.

## Inputs

- `mr_iid`: `{mr_iid}`
- `poll_interval`: `{poll_interval}` (default: 1 minute)
- `max_poll_time`: `{max_poll_time}` (default: 15 minutes)

## Mission

Automate the cycle of: fix review comments → fix pipeline failures → push → poll for new comments → repeat until clean. Review bots automatically review on every push — no manual trigger needed. This command **never merges** the MR — the user decides when and whether to merge.

## Setup

1. Detect the project path from `git remote -v`.
2. Detect the current branch from `git branch --show-current`.
3. Fetch the MR using MCP `get_merge_request` to confirm it exists and get its source branch.
4. Check `git status` for uncommitted local changes.
5. **Check for existing polling agents** — if a background polling agent from a previous `/mr-fix-loop` run is still active, stop it with `TaskStop` before proceeding. Only one polling agent should be active at a time.

## Phase 0: Assess starting state

Determine what to do first based on the combination of local changes and remote review state:

| Local changes? | Unresolved discussions? | Action |
|---|---|---|
| Yes | Any | Commit and push local changes first (review bots will auto-review the push), then proceed to Phase 1 |
| No | Yes | **Fresh MR with existing comments** — go to Phase 1 to fix them |
| No | No | **Clean MR** — go to Phase 1.5 to check pipeline, then Phase 3 (poll) and wait for review bots to review |

This means `/mr-fix-loop` works on:
- An MR you just pushed fixes to (commit + resolve + poll)
- A fresh MR with existing comments but no local changes (fix + push + resolve + poll)
- A clean MR with no comments yet (check pipeline, then poll and wait for bot auto-review)

## Phase 1: Fix and push

1. **Fetch unresolved resolvable discussions** on MR `{mr_iid}` using the GitLab REST API via `glab`:
   ```
   glab api projects/:id/merge_requests/{mr_iid}/discussions | \
     jq '[.[] | select(.notes[0].resolvable == true and .notes[0].resolved == false)]'
   ```

2. **If there are unresolved discussions from any reviewer** (any supported review bot OR human users):
   a. Read each discussion's first note to understand the requested change — pay attention to the `position.new_path`, `position.new_line`, and the specific issue described in `notes[0].body`.
   b. Read the referenced file(s) to understand current code.
   c. **Triage each comment** into one of three categories. Apply the same triage logic regardless of whether the comment is from a bot or a human user:

   ### Category A: Agree — fix it
   The comment is correct and actionable. Implement the fix.

   ### Category B: Disagree — push back
   The comment is wrong, conflicts with a previous fix, misunderstands the code, or would introduce a regression. **Do NOT fix it.** Instead:
   - If from Codex: reply with your explanation of why you disagree, what your current solution does, and why it's correct (or better), then end with `@codex review the feedback`.
   - If from another bot or a human user: reply with your explanation of why you disagree, what your current solution does, and why it's correct (or better).
   - Include specific reasoning: what the reviewer missed, what constraint they didn't account for, or how their suggestion conflicts with another fix.
   - **Do NOT resolve the discussion.** Leave it open for the user or reviewer to respond.
   - Tag the comment internally as "disputed" so you track it.

   ### Category C: Unclear — ask for clarification
   The comment is ambiguous, could be interpreted multiple ways, or you're not sure if the fix would break something else. **Do NOT fix it.** Instead:
   - If from Codex: reply with `@codex review the feedback` followed by your analysis of the issue, the options you see, and what you need clarified.
   - If from another bot or a human user: reply with your analysis and what you need clarified.
   - **Do NOT resolve the discussion.** Leave it open.
   - Tag the comment internally as "needs-clarification".

   d. For all Category A fixes: stage and commit with a conventional commit message, push to the MR branch. Review bots will automatically review the new push.

3. **If there are NO unresolved discussions**: skip to Phase 1.5 (check pipeline).

4. **Check for bot/user follow-ups on disputed discussions:**
   On each poll cycle, also check unresolved discussions you previously replied to (Category B or C). Look for new replies (subsequent entries in the discussion's `notes[]` array):
   - If a bot responds with a new note that addresses your feedback and satisfies your concerns (e.g. concedes your point, provides a valid explanation, or the issue is resolved by context), **resolve the discussion**.
   - If a bot responds but its reply does NOT satisfy your concerns, re-triage the reply as Category B (push back again) or Category C (ask for further clarification) and continue the loop.
   - If a user provides clarification or instructions **related to the original issue**, follow those instructions and fix accordingly.
   - If a reply is unrelated to the issue at hand (e.g. a different topic, a new feature request), ignore it — it's not a follow-up.
   - If the reviewer concedes or agrees with your pushback, resolve the discussion.
   - If the user overrides your pushback with explicit instructions, implement what they asked.

## Phase 1.5: Check and fix pipeline failures

After pushing fixes (or if there are no review comments to fix):

1. **Check pipeline status** using MCP `get_merge_request_pipelines` for MR `{mr_iid}`.
2. **If the latest pipeline has failed jobs**, use MCP `get_pipeline_jobs` to identify which jobs failed.
3. **For each failed job**, determine the failure type (lint, tests, type-check, build, etc.) and:
   a. **Run the equivalent check locally** to reproduce the failure:
      - Lint: `npm run lint` or the project's lint command
      - Tests: `npm test` or the project's test command
      - Type-check: `npx tsc --noEmit` or equivalent
      - Build: `npm run build` or equivalent
   b. **If reproducible locally**: treat it as a Category A fix — understand the failure, fix the code, commit with a conventional commit message (e.g. `fix(lint): resolve unused import warning`), and push.
   c. **If NOT reproducible locally** (environment-specific, infrastructure issue, flaky test): report the failure to the user with details and move on. Do not attempt to fix what you cannot reproduce.
4. **If the pipeline is passing or pending**: skip to Phase 2 (or Phase 3 if no discussions were fixed).

## Phase 2: Resolve discussions

After pushing fixes:

1. **Reply to each FIXED discussion (Category A only)** explaining the fix and referencing the commit SHA:
   ```
   glab api -X POST projects/:id/merge_requests/{mr_iid}/discussions/{discussion_id}/notes \
     -f body="Fixed in {sha}. {explanation}"
   ```

2. **Resolve ONLY fixed discussions (Category A)** via the REST API. Do NOT resolve disputed (B) or needs-clarification (C) discussions:
   ```
   glab api -X PUT projects/:id/merge_requests/{mr_iid}/discussions/{discussion_id} \
     -f resolved=true
   ```

3. Review bots will automatically review the new push — no manual trigger needed.

## Phase 3: Background polling

Run the polling script in the background to watch for new review comments and pipeline status. Use `scripts/poll-mr-reviews.sh` (or `"$CLAUDE_PROJECT_DIR"/.claude/scripts/poll-mr-reviews.sh`) to avoid generating inline scripts each time:

1. **Polls every `{poll_interval}` minutes** (default 1) for up to `{max_poll_time}` minutes (default 15).

2. **On each poll**, check:
   a. Unresolved resolvable discussions from any reviewer (bot or user).
   b. **MR approval status** (primary gate) — check if the MR has received formal approval:
      ```
      glab api projects/:id/merge_requests/{mr_iid}/approvals
      ```
      Look for `approved == true` or `approvals_left == 0`.
   c. **Award emoji on MR** (secondary gate) — check if any bot reviewer reacted with `thumbsup` or `white_check_mark` on the MR itself:
      ```
      glab api projects/:id/merge_requests/{mr_iid}/award_emoji
      ```
   d. **Complementary approval signals** — positive text like "Didn't find any major issues", "Nice work", "LGTM", or "No issues found" in a bot's discussion note. These reinforce approval but are NOT sufficient on their own.
   e. **Pipeline status** — use MCP `get_merge_request_pipelines` to check if any new pipeline has failed since the last push.
   f. Whether 15 minutes have passed with no new comments from any reviewer.

3. **Stop conditions** (any of these ends the loop):
   - **Approved:** The MR has formal approval (`approvals_left == 0`) OR a bot reviewer reacted with `thumbsup` or `white_check_mark` emoji on the MR → done, MR is approved. Complementary positive text signals further confirm approval.
   - **Idle:** No new comments from any reviewer for 15 consecutive minutes (excluding disputed discussions awaiting response) → done, but report that the MR has NOT been formally approved.
   - **Blocked on human:** Only remaining unresolved discussions are disputed (Category B/C) awaiting human input → done, but report these discussions to the user so they can weigh in.

4. **If new unresolved comments or pipeline failures appear** (from any bot or user):
   - The polling agent reports back with the comment/failure details.
   - The parent (you) then runs Phase 1, Phase 1.5, and Phase 2 again.
   - After pushing and resolving, restart Phase 3 with a fresh polling window.

## Rules

1. **Never force-push or use --no-verify.**
2. **Never merge the MR.** This command is strictly for fixing review comments and pipeline failures. The user decides when and whether to merge.
3. **Use conventional commit messages** (e.g. `fix(hooks): description`).
4. **Read files before editing** — understand current code before changing it.
5. **Only fix review comments and pipeline failures** (bot or user) — do not modify code beyond what the review requests or the pipeline requires.
6. **Reply to every fixed discussion** — explain what was changed and reference the commit.
7. **Resolve discussions only after the fix is pushed** — not before. Never resolve disputed or needs-clarification discussions.
8. **Timestamp awareness** — track when the last batch of comments was created so you don't re-process old resolved comments in the next poll cycle.
9. **Exercise judgment on reviewer feedback** — not every bot comment is correct. If the suggestion would break something, conflict with a prior fix, or misunderstand the code, push back with a clear explanation rather than blindly implementing it.
10. **Follow-up relevance** — when checking for replies on disputed discussions, only act on responses that are directly related to the original issue. Ignore tangential or unrelated comments.

## Stop and notify

When polling ends (any stop condition met):

1. Report the final state:
   - How many review rounds were completed.
   - How many total comments were fixed (broken down by bot vs user comments).
   - How many pipeline failures were fixed (broken down by type: lint, test, build, etc.).
   - How many comments were disputed (with links).
   - Whether the MR has formal approval, bot emoji approval (`thumbsup`/`white_check_mark`), complementary positive signals, or the loop ended due to idle timeout.
   - Latest pipeline status (passed, failed, running, pending).
2. If there are disputed discussions awaiting human input, list each one with:
   - The original reviewer comment (summary).
   - Your reply / reasoning.
   - What you need from the user to proceed.
3. Tell the user: "MR `!{mr_iid}` is ready for your final review."

## What to do in your first reply

1. Detect project path and branch.
2. Check `git status` for local changes.
3. Fetch current unresolved resolvable discussions on MR `{mr_iid}` (from any supported bot or user).
4. Check latest pipeline status via MCP `get_merge_request_pipelines`.
5. Report the starting state (local changes? existing comments? how many? which bots? pipeline status?).
6. Follow Phase 0 to determine the right entry point:
   - Local changes → commit, push (bots auto-review), then Phase 1.
   - No local changes + unresolved discussions → Phase 1 (fix existing comments).
   - No local changes + no discussions → Phase 1.5 (check pipeline), then Phase 3 (poll and wait for bot auto-review).
