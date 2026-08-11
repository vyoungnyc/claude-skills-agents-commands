# Remote Dispatch — Research Note

> **This is a research note, not a design or implementation document.** It records when
> `isolation: "remote"` (cloud workers) would plausibly beat local `isolation: "worktree"`
> dispatch, for a future decision. **No implementation, no config changes, and no commitment
> to build remote dispatch follow from this note.** It is explicitly out of scope for the
> `native_swarm` feature (PRD REQ-008, "Could Have"; REQ-009 marks remote dispatch implementation
> as Won't Have this phase).

## What "remote" would mean here

Today, `agents/orchestrator.md` dispatches parallel `coder` workers with `isolation: "worktree"` —
each worker gets a git worktree on the same machine as the orchestrator, branched (per
`SPIKE_FINDINGS.md`) from `origin/main`. `isolation: "remote"` would instead run a worker's
session on infrastructure separate from the orchestrator's host — e.g. a cloud sandbox or a
separate CI/build runner — communicating results back rather than sharing a local filesystem.

## When local worktrees are the right choice (status quo)

- **Small-to-medium repos** where `git worktree add` is fast (seconds, per the spike's ~19s/worker
  measurement) and disk usage per worktree is negligible.
- **Low worker counts** (the 2-3 parallel workers this feature's own steps use) — the overhead of
  provisioning remote infrastructure isn't amortized.
- **Fast local iteration** — the orchestrator and workers share a machine, so merge-back
  (`git merge --no-ff worktree-agent-<id>`) is a local, low-latency operation with no network
  round-trip or artifact transfer step.
- **Simpler failure modes** — no remote-infra failures (network partition, sandbox provisioning
  timeout, remote-to-local artifact sync) to add to the recovery table alongside `max_turns` and
  stalled workers.
- **No extra credential surface** — local worktrees need no additional secrets beyond what the
  orchestrator's own session already has; remote workers would need their own scoped
  repo/credential access, which is additional attack surface to manage.

## When remote workers would plausibly win

- **Very large fan-out** — swarms with many more than 2-3 parallel workers, where local disk
  I/O, CPU, or memory contention across worktrees on one host becomes the bottleneck rather than
  the workers' own turn budgets.
- **Heavyweight per-worker environments** — steps that need to build/run something with a large,
  slow-to-provision toolchain (e.g. a full container build, a GPU-backed test) that's expensive to
  duplicate N times on the orchestrator's host but cheap to provision once per remote worker on
  purpose-built infrastructure.
- **Host resource isolation matters** — if a worker's implementation work is untrusted or
  resource-unbounded enough that running it on the same host as the orchestrator (and other
  workers) is a reliability or security concern, remote sandboxing enforces isolation the local
  filesystem model can't.
- **Cross-machine CI dispatch at scale** — if `docs/CI_DISPATCH.md`-style headless runs need to
  fan out more workers than a single CI runner can host concurrently, remote workers let each one
  run on its own runner/sandbox instead of competing for one job's resources.
- **Very large repos** — where even a `git worktree add` (which shares object storage with the
  main checkout) becomes slow enough, or where per-worker disk footprint matters at higher worker
  counts, that isolating checkouts onto separate machines is cheaper than sharing one host's disk.

## Open questions a future design would need to answer

These are unresolved, not answered here — flagged for whoever picks this up:

1. How does merge-back work when the worker's commits live on a machine the orchestrator's
   `git merge` can't reach directly — does it require a push to a shared remote first?
2. Does `SendMessage` continuation (validated for local worktrees in `SPIKE_FINDINGS.md`(c)) work
   the same way for a remote worker, or does remote add its own reachability constraints?
3. What's the credential model for a remote worker's repo access, and how is it scoped down from
   whatever the orchestrator itself holds?
4. At what worker count or repo size does the fixed cost of remote provisioning actually pay for
   itself versus local worktree overhead (~19s/worker per the spike's local baseline)? No data
   exists yet — this would need its own spike.

## Bottom line

For this feature's scope (2-3 parallel workers, one repo, one machine), local worktree isolation
is clearly sufficient and cheaper. Remote dispatch becomes worth designing when fan-out width,
per-worker environment weight, or cross-machine CI scale outgrow what one host's worktrees can
comfortably carry — none of which apply today.
