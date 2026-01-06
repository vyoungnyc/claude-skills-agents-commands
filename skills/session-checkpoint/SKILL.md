---
name: session-checkpoint
description: "Emit and resume SESSION_CHECKPOINT blocks so agents can recover work after session or context limits."
---

# Skill: session-checkpoint

You help agents **save and resume progress** when sessions end or context shrinks, using a small `SESSION_CHECKPOINT` block.

## When to use

- After a major chunk of work (planning, design, implementation, review, docs, RAG, security).
- Before a reply that might be the last one in a long session.
- Whenever `/context` or `/usage` shows that the session is approaching context or token limits.
- At the **start** of a session when a `SESSION_CHECKPOINT` block is provided.

## Inputs you expect

For **emitting** a checkpoint:

- Role and feature/task identifier (e.g. planner + TASK-123).
- Brief recap of what was just done.
- The remaining work or open questions for this role.
- Any important file paths that were created or modified.
- (Optional) The output of `/context` or `/usage` if already provided.

For **resuming** from a checkpoint:

- A `SESSION_CHECKPOINT` block from a previous run.
- Current instruction on what the agent should do next.

## What you do

### 1. Check current session limits

When deciding whether to emit a checkpoint:

- If available, call **`/context`** and/or **`/usage`** (or their equivalents) to see:
  - Current context size vs maximum.
  - Recent token usage and any provider warnings.
- Treat thresholds roughly as:
  - **≥ 70%** of context or token budget used → start planning a checkpoint soon.
  - **≥ 85%** → emit a checkpoint **before** producing very large replies.
- If `/context` or `/usage` are not available, fall back to simple heuristics:
  - Long conversation history.
  - Large diffs, big specs, or multiple code blocks in the current reply.

### 2. Emit a checkpoint

When asked to save progress (or when nearing limits):

- Produce a small, structured block like:

  ```text
  SESSION_CHECKPOINT
  role: <agent-role>
  task: <feature-or-ticket-id>
  summary: <1–3 sentences of what was just completed>
  remaining:
    - <short bullet of remaining work>
    - <another bullet if needed>
  files:
    - <path/to/file1>
    - <path/to/file2>
  notes: <important caveats, blockers, dependencies, or links to PRs/tickets>
  ```

- Keep it **short and literal**. No storytelling or extra commentary.
- Make sure the summary and remaining work are clear enough that a future session can continue without redoing the work.
- If `/context` or `/usage` show that you are very close to limits, **prioritize** emitting the checkpoint even if you have more commentary to give.

### 3. Resume from a checkpoint

When given a `SESSION_CHECKPOINT` block:

- Parse the role, task, summary, remaining work, and files.
- Restate it briefly in your own words so the user can confirm context.
- Continue the requested work from the “remaining” items instead of starting over.
- If something is unclear, ask **direct, specific** follow-up questions.
- If you expect the new work to be large, consider:
  - Calling `/context` or `/usage` early.
  - Emitting a **new** checkpoint after finishing another chunk.
  - If `/usage` or `/context` show > ~85% of the available budget, prefer to:
    - Emit a fresh `SESSION_CHECKPOINT`.
    - Suggest starting a new session or subagent invocation **from that checkpoint** instead of continuing to append more context.

## Output style

- Be concise and direct.
- Only one `SESSION_CHECKPOINT` block at a time.
- Prefer bullet lists and short sentences.
- Avoid repeating full specs or large diffs inside the checkpoint; reference paths instead.
