# ARCHITECTURE — native_swarm

**Feature:** Retire `scripts/swarm-dispatch.sh`; dispatch parallel implementation through native background subagents.
**Source of truth:** this document. Contract: `docs/features/native_swarm/PRD.md` (as committed in `20c668b`).
**Owner:** architect. **Status:** design complete, gated on the REQ-001 spike.

## 1. Context & Goals

`swarm-dispatch.sh` was written when parallel implementation required launching separate `claude` CLI
processes. The harness now provides the same capabilities natively. The goal is to delete 533 lines of
bash and re-express the same pipeline stage — fan out N workers, isolate them, pick a model per batch,
recover failures, merge results back — in terms the harness already owns.

Nothing about the surrounding pipeline changes: issue creation, the plan-approval gate, the parallel
reviewer + security-researcher gates, and `PLAN_steps.md` are untouched. This is a substitution at one
stage, not a redesign of the workflow.

**Non-goals:** remote/cloud dispatch, agent-teams changes, per-worker cost itemization, and end-to-end
validation of a real 3+-batch run (deferred to the next feature — PRD REQ-012).

## 2. Current State

### 2.1 What the script does

`scripts/swarm-dispatch.sh <feature_id> <feature_branch> <batch_config_json_file>` — 533 lines, bash 3.2
compatible. The orchestrator builds a batch-config JSON array (`name`, `steps`, `issues`, `complexity`,
`prompt`) and the script:

1. **Preflight** — requires `jq`, `git`, `claude`; kills any prior invocation via `/tmp/swarm-dispatch-<id>.pid`;
   fetches and resolves the feature branch (local or `origin/`).
2. **Per batch** — creates worktree `/tmp/swarm-<id>-<batch>` on branch `swarm/<id>/<batch>` off the feature
   branch, removing stale worktrees/branches first (warning when a stale branch had unmerged commits).
3. **Launch** — background `claude -p` per batch with `--output-format json`, `--model`, `--max-turns`,
   a fixed `--allowedTools` list, and `--permission-mode auto`; captures PID and exit code via a `.exit` file.
4. **Model/turn selection** — `high → opus/40`, `medium → sonnet/30`, `low → haiku/20`. Highest complexity
   in a batch wins.
5. **Failure classification** — `classify_failure()` inspects exit code, session JSON, and logs to emit one
   of `launch_failure`, `context_overflow`, `infrastructure`, `max_turns`, `tool_error`, `success`.
   Order matters: context and infrastructure are checked before `max_turns` because signals co-occur.
6. **Merge-back** — refuses to run with a dirty working tree; checks out the feature branch; **skips merge
   for any session that exited non-zero** so partial work never lands; auto-commits uncommitted worktree
   changes with `git add -u` (tracked files only, to avoid staging secrets); skips when the branch has no
   new commits; `git merge --no-ff`; on conflict, records conflicting files and aborts the merge.
7. **Output** — one JSON object: `feature_id`, `feature_branch`, `total`, `succeeded`, `failed`,
   `merge_conflicts`, and a `sessions[]` array carrying `failure_reason`, `model`, `session_id`, `cost_usd`,
   `duration_ms`, and per-batch merge status.

Several of these behaviors exist because of specific production failures (CHANGELOG 2.3.2 and 2.3.3):
merging failed sessions, dropped uncommitted edits, `tee` masking worktree-creation failure, and bash 4
syntax breaking on macOS. **The guards are the valuable part of the script, not the process management** —
they must survive the migration even though their implementation does not.

### 2.2 Who references it

| File | Reference | Disposition |
|---|---|---|
| `agents/orchestrator.md` | Dispatch decision (line ~116), swarm call (~126), workflow summary (~276) | Rewrite (REQ-002) |
| `commands/execute-prd.md` | Dispatch decision (~158), batch config + script call (~196), recovery table | Rewrite (REQ-002) |
| `CLAUDE.md` | Dispatch bullet (~42) | Rewrite (REQ-004) |
| `README.md` | `### Scripts (5)` heading (~106), scripts table (~112), platform table (~142), key design principles (~156), directory structure (~258) | Rewrite (REQ-004/006) |
| `docs/AGENT_TEAMS_GUIDE.md` | Pattern 5 (~169-186), decision framework (~116-134) | Rewrite (REQ-004) |
| `docs/PHASE_6_NATIVE_PARALLELISM.md` | Decision record; §P6.3 argues for keeping the script | Mark P6.3 superseded (REQ-004) |
| `README.md` ~172, `CHANGELOG.md` | Historical entries | Out of scope — changelog-class history |

The decision framework in `AGENT_TEAMS_GUIDE.md` says "swarm dispatch (Pattern 5)" without naming the
script, so the REQ-004 grep will not catch it. It is listed explicitly for that reason.

### 2.3 Relevant agent definitions

| Agent | Tools granted today | Gap for this design |
|---|---|---|
| `orchestrator` | `Read, Write, Edit, Grep, Glob, Bash, Agent, AskUserQuestion` (model sonnet, maxTurns 50) | No `TaskCreate`/`TaskList`/`TaskUpdate`, no `SendMessage` — cannot drive a queue or recover a worker |
| `coder` | `Read, Edit, Write, Grep, Glob, Bash, TaskList, TaskGet, TaskUpdate, mcp__context7, mcp__chunkhound` (model sonnet, maxTurns 30) | No `SendMessage`; fixed `maxTurns: 30` regardless of batch complexity |

`coder.md`'s work loop is already the target protocol: claim the lowest eligible task whose `file_domain`
does not overlap an in-progress task, `TaskGet` for `file_domain`/`issue_ref`/`complexity`, implement,
validate against issue acceptance criteria, checkpoint every 5 turns, close the issue, mark complete.
**This is the contract the new dispatch must feed** — it is why the migration is mostly deletion.

## 3. Target Design

### 3.1 Dispatch flow

> **Superseded** (v2.6.0, feature `native_swarm`, review round 1) — the "workers claim from the shared
> queue" flow below was replaced by **pre-assigned steps inline in each worker's spawn prompt** once the
> REQ-001 spike showed the shared task queue is not visible to isolated background subagents at all
> (`docs/features/native_swarm/SPIKE_FINDINGS.md`, answer (b), "Design revisions" #1). The task queue
> remains useful **orchestrator-side only**, as the progress ledger the orchestrator updates as workers
> report; it is not the workers' work list. The diagram and prose below are retained as the original
> design record; see SPIKE_FINDINGS.md for the design that actually shipped.

```
Orchestrator (feature branch, plan approved)
  │
  ├─ group parallelizable steps into domain batches (batch_hint + file_domain)  [unchanged]
  │
  ├─ TaskCreate one entry per step
  │     metadata: file_domain, issue_ref, complexity  (+ expertise_hints where useful)
  │
  ├─ spawn N background coder subagents, one per batch
  │     isolation: "worktree"
  │     model: highest complexity in batch (high→opus, medium→sonnet, low→haiku)
  │
  ├─ workers claim from the shared queue (coder.md work loop, unchanged)
  │
  ├─ monitor via TaskList; harness reports completion — no polling
  │
  ├─ recover failures (§3.3)
  │
  ├─ merge worktrees back (§3.4)
  │
  └─ emit swarm report (§3.5) → Phase 3 review gates  [unchanged]
```

The queue replaces the batch-config JSON entirely. Batches stop being a data structure passed to a script
and become simply *how many workers are spawned and with which model* — the queue itself is flat, and
`file_domain` overlap avoidance in `coder.md` is what keeps workers off each other's files.

### 3.2 What each script responsibility becomes

| Script responsibility | Native replacement |
|---|---|
| `git worktree add` / cleanup / stale-branch handling | `isolation: "worktree"` (harness-managed) |
| Background processes, PID tracking, `wait` | Background subagents; harness notifies on completion |
| `--model` / `--max-turns` per session | `model` per spawn; turn budget per §3.6 |
| `--allowedTools` allowlist | Agent definition frontmatter (`coder.md`) |
| Batch-config JSON | Task queue entries with metadata |
| `classify_failure()` | Harness-reported failure + orchestrator judgment (§3.3) |
| Session JSON parsing | `TaskList` state + harness completion reports |
| Merge-back and guards | Orchestrator-owned, documented sequence (§3.4) |
| PID file / prior-run kill | Dropped — no external processes to collide |

### 3.3 Failure recovery

The tiered table stays, with two rows replaced and one removed:

| Failure | Recovery |
|---|---|
| `max_turns` | Respawn with upgraded model: haiku → sonnet → opus; already opus → escalate to user |
| Stalled / incomplete worker | `SendMessage` continuation (replaces `claude --resume`) |
| `context_overflow` | Retry with opus 1M; already opus → escalate |
| `tool_error` | Escalate to user immediately — unchanged |
| ~~`launch_failure`~~ | Removed — the harness owns worktree creation |

Respawned workers do not need re-seeding: incomplete tasks remain in the queue as `in_progress` with the
failed worker as owner, so recovery is "release and respawn," not "rebuild context." The orchestrator
must reset `owner` and `status` on the abandoned task before respawning, or the replacement worker will
skip it as already claimed.

### 3.4 Merge-back sequence (orchestrator-owned)

The script's guards are re-expressed as a documented procedure in `orchestrator.md`. Order is load-bearing:

1. Verify the working tree is clean; refuse to merge otherwise.
2. Check out the feature branch explicitly — never merge onto whatever HEAD points at.
3. For each worker: **skip the merge if the worker failed or its tasks are incomplete.** Partial work must
   not land; this was a critical bug (CHANGELOG 2.3.2).
4. Handle uncommitted worktree changes per spike answer (e) — preserve or commit, never silently discard.
5. Skip when the worker's branch has no new commits.
6. `git merge --no-ff` per worker branch.
7. On conflict: record the conflicting files, abort the merge, and spawn a single conflict-resolution
   session — unchanged from today.

### 3.5 Swarm report

Best-effort, emitted after all workers settle. Per worker: batch name, model, duration, turn count,
steps completed, issues closed — plus **failed and incomplete workers with their failure mode and the
recovery action taken**. Cost is explicitly not itemized. When the harness exposes no duration/turn
metrics, the orchestrator falls back to its own observed spawn/finish timestamps and marks turn count
unavailable rather than dropping the row.

### 3.6 Tool grants

- `agents/orchestrator.md` frontmatter gains `TaskCreate`, `TaskList`, `TaskUpdate` (build and monitor the
  queue) and `SendMessage` (recovery, report gathering).
- `agents/coder.md` gains `SendMessage` **only if** spike answer (c) shows a worker cannot act on a
  continuation without it (REQ-007).
- Turn budget: if a spawn can override frontmatter `maxTurns` (spike answer (d)), keep the per-complexity
  budgets 40/30/20. If not, `coder.md`'s fixed `maxTurns: 30` applies to every worker and the docs must say
  so plainly — high-complexity batches lose 10 turns, which makes the `max_turns` recovery row more likely
  to fire, not less. Either way the budget stops being invisible.

## 4. The Spike as a Hard Gate (REQ-001)

Two workers, worktree-isolated, on scratch branch `spike/native-swarm`; findings in `SPIKE_FINDINGS.md`
ending in an explicit GO/NO-GO; branch and worktrees torn down afterward.

| Question | Decides | Contingent design |
|---|---|---|
| (a) Where do worktree commits land; how does the orchestrator merge them? | Whether §3.4 is expressible at all | **Blocker.** NO-GO if the orchestrator cannot reach and merge worker branches |
| (b) Can two workers claim from the queue without double-claim? | Whether `file_domain` overlap checks in `coder.md` suffice | If claiming races, add an explicit claim protocol or serialize per domain |
| (c) Does `SendMessage` continue a completed/stalled worker? | The stalled-worker recovery row | If not, fall back to respawn-with-context for stalls; REQ-007 tool grant follows from this |
| (d) Can a spawn override frontmatter `maxTurns`? | §3.6 turn budget | Per-complexity budgets, or documented fixed 30 |
| (e) What happens to uncommitted changes in a finished worktree? | §3.4 step 4 | If discarded, the merge sequence needs an explicit commit step — this is the data-loss case `git add -u` existed for |

Only (a) is a true NO-GO condition. (b)-(e) shape the design rather than block it; each has a stated
fallback above, so a surprising answer costs a doc revision, not a redesign.

## 5. CI Entry Point (REQ-005)

`docs/CI_DISPATCH.md` documents a headless GitHub Actions entry point scoped to the **implementation phase
only**, against an already-approved `PLAN_steps.md` — the equivalent of `/execute-prd` Phase 2 onward.

The boundary is not stylistic. `/execute-prd` contains blocking `AskUserQuestion` gates at Phase 1.6 (plan
approval) and Phase 5.1 (push/PR approval) plus the Phase 0.2 PRD gate, and `orchestrator.md` Rule 1
forbids starting implementation without explicit plan approval. Unattended, those gates hang or get
silently auto-answered — which would convert a human approval into a machine one. CI therefore enters
*after* approval and must not auto-answer the gates.

Preconditions stated in the doc: feature branch exists, `PLAN_steps.md` present and user-approved, epic and
child issues already created. The doc also notes the orchestrator's `maxTurns: 50` as a practical ceiling
on how much of the pipeline one `-p` invocation can carry, covers permission configuration and timeouts,
uses `CLAUDE_CODE_OAUTH_TOKEN` from a repository secret (never an inline token), and mentions
`anthropics/claude-code-action` as the alternative entry point. The example workflow ships in docs and is
not activated in this repo — there is no `.github/workflows/` here and this change does not add one.

## 6. Change Map

| REQ | Files | Notes |
|---|---|---|
| REQ-001 | `docs/features/native_swarm/SPIKE_FINDINGS.md` (new) | Gate for everything below |
| REQ-002 | `agents/orchestrator.md`, `commands/execute-prd.md` | Dispatch tables, recovery table, merge sequence, tool grants |
| REQ-003 | `agents/orchestrator.md` | Report format |
| REQ-004 | delete `scripts/swarm-dispatch.sh`; `CLAUDE.md`, `README.md`, `docs/AGENT_TEAMS_GUIDE.md`, `docs/PHASE_6_NATIVE_PARALLELISM.md` | Grep AC is the check |
| REQ-005 | `docs/CI_DISPATCH.md` (new) | Independent file domain — parallelizable |
| REQ-006 | `README.md`, `CHANGELOG.md` | v2.6.0; Scripts count 5 → 4 |
| REQ-007 | `agents/coder.md` | Conditional on spike (c)/(d) |
| REQ-008 | `docs/REMOTE_DISPATCH_NOTES.md` (new) | Could-have; independent domain |

**Overlapping-domain constraint.** REQ-002, REQ-003, REQ-004, and REQ-006 all touch some combination of
`orchestrator.md`, `execute-prd.md`, and `README.md`. Those steps must run in **one batch or in sequence** —
never split across parallel workers, whose worktrees would each carry a different version of the same file
and collide at merge. Only the new-file work (REQ-005, REQ-008) and the conditional `coder.md` edit are
safely parallel.

The consequence, recorded as PRD REQ-012: this feature has two or three parallelizable batches and cannot
exercise the 3+ dispatch path it introduces. Validation lands on the next feature.

## 7. Risks

- **Native worktree merge semantics don't fit the merge-back flow.** Mitigation: REQ-001(a) is a hard gate;
  NO-GO halts before anything is modified.
- **Self-modification.** The pipeline edits its own orchestrator and command definitions mid-run. Mitigation:
  workers edit inside isolated worktrees branched from the feature branch, so the running session's loaded
  definitions do not change until merge; overlapping files stay in a single batch.
- **Silent loss of a hard-won guard.** The script's merge guards encode real incidents. Mitigation: §3.4
  enumerates them as an explicit checklist; each has a home in `orchestrator.md` before the script is deleted.
- **Stale reference survives cleanup.** Mitigation: REQ-004's grep criterion is binary and checkable.
- **Recovery leaves an orphaned claim.** A respawn without releasing the failed worker's task makes the
  replacement skip it. Mitigation: §3.3 requires resetting `owner`/`status` before respawn.

## 8. Implementation Notes

- **Sequence:** spike first and alone (it gates everything). Then the doc/definition batch. Delete the
  script last, after every replacement behavior is written down — the script is the only remaining record
  of the guards until §3.4 lands in `orchestrator.md`.
- Preserve the existing table and section formatting in `orchestrator.md` §4 and `execute-prd.md` Phase 2;
  this is a content swap, not a restructure.
- CHANGELOG follows the 2.5.0 style: grouped, bolded change titles with the rationale, not just the change.
- Verification for this feature is grep-based; there is no md test suite, and no `.test.sh` sibling is needed
  because bash is being deleted rather than added.
- Commits use `git commit -F -` heredoc form — the conventional-commits hook cannot parse a multi-line `-m`.
