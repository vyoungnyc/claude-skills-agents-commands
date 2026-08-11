# CI Dispatch — Headless Implementation Phase

This doc explains how to run the **implementation phase only** of the `/execute-prd` pipeline
headlessly, e.g. from GitHub Actions. It does not cover discovery, planning, or PRD review —
those stay interactive. Nothing in this doc is activated in this repo: there is no
`.github/workflows/` here, and the workflow example below is meant to be copied into a
**target project** that wants headless dispatch, not run here.

## Scope boundary — why CI stops before the gates, not after them

`/execute-prd` has three blocking `AskUserQuestion` gates, and `agents/orchestrator.md` Rule 1
forbids starting implementation without explicit plan approval:

| Gate | Phase | What it blocks |
|---|---|---|
| PRD review | 0.2 | Proceeding past requirements gaps/scope/ambiguity findings |
| Plan approval | 1.6 | Proceeding to Phase 2 (implementation) without the user approving `PLAN_steps.md` + issues |
| Push/PR approval | 5.1 | Pushing the branch and opening a PR/MR |

These are **human approval gates by design** — they exist so a person signs off on scope, the
plan, and the point where work becomes visible to the rest of the team. An unattended `claude -p`
invocation cannot answer an `AskUserQuestion` prompt in a way that means anything: it would either
hang waiting on a prompt nobody sees, or worse, some tooling could be built to auto-answer it,
which quietly converts a human approval into a machine one. Neither is acceptable for gates that
exist specifically to keep a human in the loop.

**Consequence for this doc:** the CI entry point covers **`/execute-prd` Phase 2 onward** — the
implementation phase — against a `PLAN_steps.md` that has *already* cleared the 0.2 and 1.6 gates
interactively. CI must not attempt to satisfy those gates itself, and it stops again at 5.1: it
does not push or open a PR/MR. A human runs `/execute-prd` (or the earlier phases of it)
interactively up through plan approval, and only then does a CI-triggered headless run pick up
Phase 2.

## Preconditions

Before a CI run is triggered, all of the following must already be true (verify, don't create,
in the workflow):

1. **Feature branch exists** — `feature/{feature_id}` was created in Phase 0.1 and carries
   `docs/features/{feature_id}/PRD.md` and `ARCHITECTURE.md`.
2. **`PLAN_steps.md` is present and user-approved** — Phase 1.6 already ran interactively and the
   user explicitly approved the plan. CI does not re-derive or re-approve the plan; it treats
   `docs/features/{feature_id}/PLAN_steps.md` as a settled contract.
3. **Epic + child issues already exist** — Phase 1.5 already ran (`scripts/create-github-issues.sh`
   or the local-issue equivalent), so each plan step has an `issue_ref` the dispatched workers can
   read acceptance criteria from.

If any of these are missing, the run should fail fast with a clear message rather than attempt to
backfill them headlessly — backfilling would mean running gated phases without a human present.

## What runs inside the `-p` invocation

A single `claude -p` process is the CI entry point. It loads `agents/orchestrator.md` and drives
Phase 2 onward exactly as the interactive orchestrator would, with one difference: it must be
instructed (in the prompt) that Phase 0–1 gates are already satisfied, so it starts directly at
implementation dispatch rather than attempting PRD review or plan derivation.

Native background subagents (the `coder`/`backend-coder`/`frontend-coder` workers the orchestrator
spawns with `isolation: "worktree"`) run **inside** that `-p` invocation for its duration — they
are not separate processes the workflow needs to track, wait on, or clean up itself. When the `-p`
invocation exits, all subagents it spawned have already completed, failed, or been reported as
incomplete by the orchestrator; there is nothing left running in the background afterward.

Per `SPIKE_FINDINGS.md`, headless dispatch inherits the exact same worktree mechanics validated
interactively — nothing about running in CI changes them:

- Worktrees for spawned workers are cut from `origin/main` (the default branch), not from the
  branch the orchestrator itself is running on. Worker prompts must carry needed feature-branch
  context inline, or instruct the worker to merge the feature branch into its worktree first.
- The shared task queue is not visible to isolated background workers — steps must be
  **pre-assigned in each worker's spawn prompt** (step id, `file_domain`, `issue_ref`,
  `complexity`, acceptance criteria), not claimed from a queue at runtime.
- Each worker runs under `agents/coder.md`'s fixed `maxTurns: 30` — CI does not get a larger
  per-worker turn budget than an interactive run does.

## Turn budget ceiling

`agents/orchestrator.md` has `maxTurns: 50`. Treat this as a **practical ceiling** on how much of
the pipeline a single headless `-p` invocation can carry — plan the scope of one CI run (how many
steps, how many parallel workers) so the orchestrator's own turns (dispatch, monitoring, recovery,
merge-back, reporting) fit inside that budget. A CI run that needs more than one orchestrator
"session" worth of turns should be split into multiple triggered runs (e.g. one per dispatch round
in `PLAN_steps.md`) rather than assumed to complete in one invocation.

## Permissions, timeouts, and secrets

- **Authentication:** use `CLAUDE_CODE_OAUTH_TOKEN` from a **repository secret**
  (`${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}`). Never inline a token into the workflow file, a
  prompt, or a log-visible command — CI logs are not a safe place for credentials.
- **Permission mode:** headless runs have no one to answer permission prompts, so grant the
  minimum tool set the implementation phase needs up front (typically inherited from
  `agents/orchestrator.md`'s frontmatter: `Read, Write, Edit, Grep, Glob, Bash, Agent`) rather
  than relying on interactive approval. Do not grant broader filesystem or network access than the
  orchestrator and its spawned coders already have in their agent definitions.
- **Timeouts:** set both a job-level timeout (`timeout-minutes` in the workflow, sized to the
  orchestrator's `maxTurns: 50` ceiling plus the parallel workers' `maxTurns: 30` each) and rely on
  the harness's own turn limits as the inner bound. An unattended run that exceeds its timeout
  should fail the job rather than continue silently — there is no human present to notice a stuck
  run otherwise.
- **No credentials in git:** the example workflow below references only the secret name; nothing
  in this repo or the target project's committed files should ever contain the token value.

## Example workflow (copy into a target project's `.github/workflows/`)

This YAML is a complete, copyable starting point. It is **not** added to this repo — there is no
`.github/workflows/` directory here, and this doc is the only place it lives.

```yaml
# .github/workflows/ci-dispatch.yml
name: CI Dispatch — Implementation Phase

on:
  workflow_dispatch:
    inputs:
      feature_id:
        description: "Feature ID matching docs/features/<feature_id>/"
        required: true
        type: string

jobs:
  implement:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    permissions:
      contents: write
      issues: write
      pull-requests: read
    steps:
      - name: Checkout feature branch
        uses: actions/checkout@v4
        with:
          ref: feature/${{ github.event.inputs.feature_id }}
          fetch-depth: 0

      - name: Verify preconditions
        run: |
          set -euo pipefail
          test -f "docs/features/${{ github.event.inputs.feature_id }}/PLAN_steps.md" \
            || { echo "::error::PLAN_steps.md missing — plan must be approved interactively first"; exit 1; }
          gh issue list --label "feature:${{ github.event.inputs.feature_id }}" --limit 1 \
            || { echo "::error::No GitHub issues found for this feature — run Phase 1.5 first"; exit 1; }
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code

      - name: Run implementation phase headlessly
        env:
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
        run: |
          claude -p "$(cat <<'PROMPT'
          You are the orchestrator for feature_id=${{ github.event.inputs.feature_id }}.
          Phase 0 (PRD review) and Phase 1 (plan approval, gate 1.6) are already complete and
          approved — do not re-run them and do not attempt to satisfy any AskUserQuestion gate.
          Start at Phase 2 (Implementation) of commands/execute-prd.md using the existing
          docs/features/${{ github.event.inputs.feature_id }}/PLAN_steps.md and the already-created
          GitHub issues. Run through Phase 4 (documentation). Stop before Phase 5.1 (push/PR
          approval) — report readiness for push instead of pushing or opening a PR.
          PROMPT
          )" \
            --model sonnet \
            --max-turns 50 \
            --permission-mode acceptEdits \
            --allowedTools "Read,Write,Edit,Grep,Glob,Bash,Agent" \
            --output-format json > run-result.json

      - name: Upload run result
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ci-dispatch-result-${{ github.event.inputs.feature_id }}
          path: run-result.json
```

Notes on the example:
- The prompt explicitly tells the orchestrator which gates are already satisfied and where to
  stop (before 5.1), matching the scope boundary above — it never asks the orchestrator to answer
  a gate, only to skip past ones already cleared.
- `timeout-minutes: 90` and `--max-turns 50` are sized around the orchestrator's `maxTurns: 50`
  ceiling with headroom for the workflow's own setup/teardown steps; adjust per feature size.
- Uploading `run-result.json` gives a human a record to review after the run, since no one
  answered any prompts live.

## Alternative: `anthropics/claude-code-action`

For teams that prefer a maintained GitHub Action over a raw `claude -p` shell step, the official
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) wraps the same
`claude -p` mechanics (including `CLAUDE_CODE_OAUTH_TOKEN` handling) behind a GitHub Actions
interface. It is a reasonable alternative entry point for the same implementation-phase scope
described here; evaluate it if the raw shell invocation above needs more GitHub-native ergonomics
(PR comments, check runs, etc.) than a bare `claude -p` step provides. This doc's scope boundary,
preconditions, and turn-budget guidance apply equally whether you use the raw CLI or the action.
