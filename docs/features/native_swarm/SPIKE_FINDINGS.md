# SPIKE_FINDINGS — native_swarm (REQ-001)

**Date:** 2026-08-10. **Method:** two rounds of 2 parallel background `coder` subagents with
`isolation: "worktree"`, dispatched from scratch branch `spike/native-swarm` (branched off
`feature/native_swarm` at `e45cb9a`). Round 1 tested queue-fed dispatch (failed — see (b)); round 2
tested direct-prompt dispatch with commits (succeeded). All observations are from this repo on this
machine, harness-current as of the spike date.

## (a) Where do worktree commits land, and how does the orchestrator merge them?

**Answer: commits land on per-agent branches `worktree-agent-<id>`, checked out in worktrees under
`.claude/worktrees/agent-<id>`. Both persist after the worker completes (when the worktree has
changes), and the orchestrator merges them from the main checkout with plain `git merge --no-ff
worktree-agent-<id>` — both spike merges applied cleanly and the files were present on the target
branch.**

Two qualifications that shape ARCHITECTURE §3.4:

1. **Worktrees are branched from `origin/main` (the default branch), not from the branch the
   orchestrator dispatches from.** Both round-1 and round-2 worktrees were cut at `291015d`
   (`origin/main`) while the dispatching checkout sat on `spike/native-swarm` at `e45cb9a`. Merge-back
   still works (common ancestor), but workers **do not see feature-branch state** — files added or
   edited only on the feature branch are absent in their worktrees. Round-1 workers could not find
   `docs/features/native_swarm/` at all. Consequence: worker prompts must carry all needed context
   inline (or instruct `git merge <feature-branch>` first), and merge-back must anticipate conflicts
   when a worker edits a file the feature branch has also touched since `origin/main`.
2. **Unchanged worktrees are torn down at completion, with their branches deleted.** Round-1 workers
   finished without committing; their worktrees and `worktree-agent-*` branches vanished. Merge-back
   must therefore skip workers whose branch no longer exists (nothing to merge) — the "no new
   commits" skip becomes "branch absent or no new commits."

*Decides: §3.4 is expressible — this was the only NO-GO condition, and it passes.*

## (b) Can two workers claim from the shared task queue without double-claim?

**Answer: untestable — the shared task queue is not visible to spawned coder subagents at all.**
Both round-1 workers reported that `TaskList`/`TaskGet`/`TaskUpdate` were absent from their available
tools (their effective toolset was `Read`, `Edit`, `Write`, `Bash` — `Grep`/`Glob` and the MCP grants
were also missing), despite `agents/coder.md` granting them in frontmatter. The orchestrator's queue
(tasks #1/#2) remained `pending`, unclaimed, before/during/after both workers ran.

**Design revision:** the queue-fed work loop in `coder.md` cannot be the dispatch contract for
worktree-isolated background subagents in this environment. Dispatch must **pre-assign steps in each
worker's spawn prompt** (step ids, file domains, issue refs, acceptance criteria inline). The native
task queue remains useful **orchestrator-side only**, as the progress ledger the orchestrator updates
as workers report. Double-claim safety becomes moot: assignment is explicit, and non-overlapping
`file_domain` per worker is enforced at batch construction, exactly as the batching rules already
require.

*Decides: ARCHITECTURE §3.1 "workers claim from the shared queue" is replaced by pre-assigned
prompts; §4 fallback ("explicit claim protocol / serialize per domain") is triggered.*

## (c) Does `SendMessage` continue a completed/stalled worker?

**Answer: yes — delivery and resumption work, and the worker acts on the message. No `SendMessage`
grant in `coder.md` is needed:** workers receive continuations regardless of their tool grants and
report back through their normal completion result (REQ-007 → no change required for this).

**Hard caveat:** continuation does **not** restore a torn-down worktree. Round-1 workers (unchanged
worktrees, cleaned at completion) resumed **in the shared checkout** with isolation gone; both
detected this and correctly refused to write. One had begun staging files at the stale worktree path
inside the shared repo before backing out. **Rule for §3.3: `SendMessage` continuation is safe only
while the worker's worktree still exists (stalled or incomplete workers, or completed workers with
preserved changes). After a clean completion that triggered teardown, respawn a fresh worker instead
of continuing.**

*Decides: the stalled-worker recovery row stands, with the worktree-alive precondition stated.*

## (d) Can a spawn override the agent's frontmatter `maxTurns`?

**Answer: no. The Agent tool exposes no turn-budget parameter** — its inputs are `subagent_type`,
`model`, `isolation`, `name`, `prompt`, `run_in_background` (plus deprecated fields). Per-spawn
`model` selection survives; per-spawn turn budgets do not. **`agents/coder.md`'s fixed `maxTurns: 30`
applies to every worker regardless of batch complexity.** The old opus/40 · sonnet/30 · haiku/20
budget mapping is reduced to model selection only; high-complexity batches drop from 40 to 30 turns,
making the `max_turns` recovery row *more* likely to fire. Docs (REQ-002) must state this plainly.

*Decides: §3.6 turn budget → documented fixed 30.*

## (e) What happens to uncommitted changes left in a finished worktree?

**Answer: preserved on disk, but only because a changed worktree survives completion — and they are
one cleanup command away from silent loss.** Worker A committed one file and left a second untracked;
after it finished, the worktree, its branch, and the untracked file were all still present. The
untracked file is invisible to merge-back (merges move commits only). `git worktree remove` **refuses**
on a dirty worktree (`contains modified or untracked files, use --force`); `--force` discards the
uncommitted work permanently — the spike verified both behaviors.

**Rule for §3.4 step 4:** before removing any worker worktree, run `git -C <worktree> status
--porcelain`; if dirty, either commit the changes on the worker branch (then merge) or copy them out
— never `--force`-remove a dirty worktree without salvaging. This is the native successor to the
script's `git add -u` guard (CHANGELOG 2.3.2). Residual unknown, noted for the docs: whether a worktree
with *only* uncommitted changes (no commits) counts as "changed" and survives teardown was not
tested — workers must be instructed to always commit their work.

*Decides: §3.4 step 4 handling; the data-loss guard survives the migration.*

## Wall-clock baseline (NFR)

Round 2 (the representative run): spawn → both workers committed and reported in **~19 s each,
in parallel**; full spike including the failed round 1, continuation tests, merges, and teardown:
**~5 min 41 s**. Native dispatch overhead per worker (worktree creation + spawn) is seconds, well
inside the script's per-batch overhead. No regression concern.

## Teardown

`git worktree list` shows only the main checkout; `git branch --list 'spike/*'` and
`git branch --list 'worktree-agent-*'` are empty; working tree clean on `feature/native_swarm`.
Spike queue tasks deleted.

## Design revisions carried into round 2 of the feature

1. Workers get **pre-assigned steps inline in spawn prompts**; the task queue is orchestrator-side
   tracking only (b).
2. Worker prompts must carry feature-branch context or merge the feature branch first, because
   worktrees are cut from `origin/main` (a).
3. Merge-back: skip absent branches; salvage dirty worktrees before removal; never `--force` blind (a, e).
4. `SendMessage` continuation only while the worktree lives; otherwise respawn (c).
5. Fixed turn budget of 30 documented; complexity drives model only (d).

## Verdict

The one blocking question — (a), reachability and mergeability of worker commits — passes cleanly.
Every other surprise has a workable design revision listed above, absorbed into step_02/step_06
before round-2 dispatch.

**GO**
