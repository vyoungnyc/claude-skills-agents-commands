---
name: codereview
description: "Interactive code review — runs 7 parallel reviewers (5 Claude angles + Codex + Codex adversarial), scores with haiku, deduplicates across all sources, and surfaces all findings. You decide what to fix."
args:
  - name: input
    type: string
    required: false
    description: "Scope and/or intent. Can be a scope ('staged', commit ref, 'PR #N', file path), a description of what the changes do, or both. Examples: 'abc123', 'PR #5', 'adding scan_type to src_abc model for Hello World product. Needed to distinguish full from classic scans.'"
model: opus
---

# Code Review

You are reviewing code changes interactively with the user. You run a 7-angle parallel review, score all findings, deduplicate across sources, and surface everything — the user decides what to fix.

## Priorities (in order)

1. **Correctness** — Logic errors, missed edge cases, off-by-ones, race conditions, broken error handling.
2. **Pattern adherence** — Deviations from established codebase conventions (naming, error handling, data flow, file organization).
3. **Best practices** — Deprecated APIs, known anti-patterns, missed language features that simplify the code.

## Step 1: Parse input and scope

`$ARGUMENTS` may contain a scope, intent description, or both.

**Scope** (determines which diff to review):
- No args or `staged` → `git diff --cached`, fall back to `git diff`
- Commit ref (e.g. `abc123`, `HEAD~3`) → `git diff <ref>...HEAD`
- `PR #N`, `MR #N`, or just a number → GitHub repos: `gh pr diff N`; GitLab or no `gh`: `git diff main...HEAD`
- File path → read the file + `git log -5 --follow <file>`
- Default: staged/unstaged diff

**Intent** (everything that isn't a scope token): treat as authoritative context for correctness checking. If the code diverges from the stated intent, that's a blocking finding.

Show a one-line summary: `Reviewing N files, M lines changed` before proceeding.

## Step 2: Gather context and clarify intent

Before launching reviewers:
- Get the full diff text
- Find all relevant CLAUDE.md files: root CLAUDE.md + any CLAUDE.md in directories containing modified files
- Check `ARCHITECTURE.md` and `PLAN_steps.md` if they exist
- For each modified file, read enough surrounding code to understand the patterns in use

**Intent gate (before Step 3):** If the intent of the changes is not obvious from the diff, commit messages, or user-provided context, ask the user what the changes are supposed to do **before** launching reviewers. Reviewers need clear intent context to produce accurate findings. Do not launch Step 3 until intent is established.

## Step 3: Launch all 7 reviewers in parallel

In a **single parallel tool-use turn**, launch all of the following simultaneously, passing the full diff, CLAUDE.md file paths, and any clarified intent context from Step 2 to each.

---

### Claude sub-agents (Agent tool, model: sonnet)

Each sub-agent must return findings as a JSON array. Use this schema:

```json
[
  {
    "file": "src/foo.ts",
    "line_start": 42,
    "line_end": 45,
    "severity": "critical|high|medium|low",
    "title": "Short title",
    "body": "What is wrong and why it matters.",
    "recommendation": "Concrete fix."
  }
]
```

Return `[]` if no findings. Never include: pre-existing issues (lines not in the diff), style issues a linter would catch, or speculative concerns without evidence from the actual code.

**Agent #1 — CLAUDE.md compliance**

> You are a CLAUDE.md compliance reviewer. You will be given a diff and a list of CLAUDE.md file paths. Read those CLAUDE.md files, then check every changed line in the diff against their instructions. Note: CLAUDE.md is guidance for writing code — not all instructions apply during review. Only flag explicit, specific violations that are directly called out. Return a JSON array of findings using the schema provided. Return [] if no violations.

**Agent #2 — Bug scan (changed lines only)**

> You are a shallow bug scanner. Read only the changed lines in the diff. Look for: logic errors, off-by-ones, null/undefined dereferences, broken error handling, race conditions, data loss risks, broken invariants. Do not read extra surrounding context — focus only on changed lines. Report large bugs only — avoid nitpicks. Ignore lines not present in the diff. Return a JSON array of findings using the schema provided. Return [] if no bugs found.

**Agent #3 — Git blame and history**

> You are a git history reviewer. Read the git blame and history of the code modified. Use `git log --follow` and `git blame` on the changed files and lines — decide how deep to go based on what you find. Look for: patterns of prior bugs in this area, recently reverted changes being re-introduced, prior fixes being undone, areas flagged repeatedly in commit messages. Use history as context to identify whether this change is safe. Return a JSON array of findings using the schema provided. Return [] if history gives no cause for concern.

**Agent #4 — Prior PR/MR comments**

> You are a PR history reviewer. Read previous pull requests that touched the same files, and check for any comments on those pull requests that may also apply to the current pull request. Use `gh pr list --state merged` and `gh pr view` to find and read prior PRs — decide how many to check based on what you find. If `gh` is unavailable (e.g., GitLab repos or no GitHub CLI), skip this review angle and return `[]` (the unavailability will be reported separately via reviewer status). Return any relevant findings as a JSON array using the schema provided, noting the prior PR number in the body. Return [] if no relevant prior comments found.

**Agent #5 — Code comments compliance**

> You are a code comments compliance reviewer. Read inline comments, docstrings, and TODO/FIXME/NOTE comments in the modified files. Check that the changes comply with guidance documented in those comments — violated invariants, ignored preconditions, broken documented contracts. Return a JSON array of findings using the schema provided. Return [] if changes comply with documented guidance.

---

### Codex reviewers (Bash — run in background, 15-minute timeout)

Launch **both** Codex reviewers in the **same parallel tool-use turn** as the 5 Claude agents above. Use `run_in_background: true` and `timeout: 900000` (15 minutes) for each Bash call — they run concurrently while Claude agents complete.

**Scope note:** Codex uses its own scope detection (current branch diff against default branch). It does not receive the scope parsed in Step 1. If the user specified a non-default scope (e.g., a single file or a specific commit range), note this discrepancy in the final output — Codex findings may cover a broader or different diff than Claude agents. **When the user's scope is narrower than branch-vs-default**, tag all Codex findings with `scope: "branch-wide"` and exclude them from the primary verdict calculation — present them in a separate "Branch-wide Codex findings" section so they don't inflate the scoped verdict.

**Codex #6 — Standard review:**
```bash
CODEX=$(find ~/.claude/plugins -name "codex-companion.mjs" -type f 2>/dev/null | head -1)
if [ -n "$CODEX" ]; then
  OUTPUT=$(node "$CODEX" review 2>/dev/null)
  EXIT=$?
  if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
  else
    echo '{"verdict":"error","summary":"Codex review failed (exit '$EXIT')","findings":[],"next_steps":[]}'
  fi
else
  echo '{"verdict":"error","summary":"Codex companion not found","findings":[],"next_steps":[]}'
fi
```
`Bash({ command: "...", run_in_background: true, timeout: 900000 })`

**Codex #7 — Adversarial review:**
```bash
CODEX=$(find ~/.claude/plugins -name "codex-companion.mjs" -type f 2>/dev/null | head -1)
if [ -n "$CODEX" ]; then
  OUTPUT=$(node "$CODEX" adversarial-review 2>/dev/null)
  EXIT=$?
  if [ $EXIT -eq 0 ] && [ -n "$OUTPUT" ]; then
    echo "$OUTPUT"
  else
    echo '{"verdict":"error","summary":"Codex adversarial review failed (exit '$EXIT')","findings":[],"next_steps":[]}'
  fi
else
  echo '{"verdict":"error","summary":"Codex companion not found","findings":[],"next_steps":[]}'
fi
```
`Bash({ command: "...", run_in_background: true, timeout: 900000 })`

**Handling Codex results:** After Claude agents #1–#5 complete and haiku scoring finishes, check the Codex background task outputs. If Codex tasks are still running, proceed to dedup and initial presentation with Claude findings only — Codex results will be integrated incrementally per Step 6. If `verdict` is `"error"`, note it in the final summary as a skipped reviewer — do not treat errors as clean approvals. Do **not** inject error findings into the findings array — report Codex errors only in the summary text.

**Reviewer failure verdict adjustment:** If any reviewer (Claude or Codex) errors or times out, the verdict cannot be `approve`. Downgrade `approve` → `approve-with-nits` and note incomplete coverage. If ≥ 3 reviewers failed, force `changes-requested` with a note that the review had insufficient coverage — the user must explicitly override to proceed. **Exception:** "Codex companion not found" is a **skipped** reviewer (optional dependency not installed), not a failed one — do not count it toward the failure threshold or downgrade the verdict. Only count runtime errors or timeouts from an installed Codex as failures.

**Codex output format:** Codex may return structured JSON (with `confidence` 0–1 per finding) or rendered markdown. Handle both:
- **JSON output:** Extract `confidence` per finding, compute `score = confidence × 100`.
- **Markdown output:** Parse the rendered report, extract findings manually, and assign `score` based on severity (`[P0]`/`blocker` → 100, `[P1]`/`critical`/`high` → 85, `[P2]`/`medium` → 65, `[P3]`/`low` → 40).

Do **not** send Codex findings to the haiku scoring step — score them directly from the output.

Note which reviewers were skipped, errored, or used a different scope in the final output.

---

## Step 4: Score Claude findings with haiku

Once Claude agents #1–#5 complete, spawn a **parallel haiku agent per finding** from those agents. Do not wait for Codex — it runs in the background and its results are read after haiku scoring finishes (see Step 3 handling note).

Give each haiku agent the finding JSON, the diff, and the CLAUDE.md file paths. Use this rubric verbatim:

```
0:   False positive. Does not survive light scrutiny, or is a pre-existing issue not introduced by this diff.
25:  Might be real but unverified. Stylistic issue not explicitly called out in CLAUDE.md.
50:  Verified real issue but minor or infrequent in practice.
75:  Verified real issue, likely encountered in practice, important to address.
100: Certain — confirmed, will occur frequently, evidence is direct and unambiguous.
```

Each haiku agent returns: `{"score": <0-100>, "reasoning": "<one sentence>"}`

Assign the returned score to its finding.

## Step 4.5: Normalize Codex findings

Before dedup, normalize Codex findings (#6 and #7) so they have the same `score` field as Claude findings:
- **JSON output with `confidence`:** compute `score = confidence × 100` (e.g., 0.85 → 85).
- **Markdown output without `confidence`:** assign `score` from severity: `[P0]`/`blocker` → 100, `[P1]`/`critical`/`high` → 85, `[P2]`/`medium` → 65, `[P3]`/`low` → 40. Fail closed on unknown severities — assign 85 and flag for manual review.
- Add the `score` field to each Codex finding object.
- All findings from all 7 agents **must** have a `score` (0–100) field before entering Step 5.
- **Scope tagging:** If the user-specified scope is narrower than branch-vs-default, tag each Codex finding with `scope: "branch-wide"`. These findings are excluded from dedup and the primary verdict in Step 5 — present them in a separate section per Step 6.

## Step 5: Deduplicate and merge

Spawn a **single haiku agent** with all normalized **scoped** findings (agents #1–#5, plus Codex findings that are NOT tagged `scope: "branch-wide"`).

Instructions for the haiku agent:
> You are deduplicating a list of code review findings from independent reviewers. Group findings that describe the same issue — either referencing the same file and overlapping line range, or describing a semantically equivalent problem. For each group, produce one merged finding: combine the body text from all sources into one clear description, union all source labels into a `sources` array, keep the highest severity, keep the highest score. Return the deduplicated list as a JSON array. Each item must have: file, line_start, line_end, severity, title, body, recommendation, score (0-100), sources (array of source names from: claude-compliance, claude-bugs, claude-history, claude-pr-comments, claude-code-comments, codex, codex-adversarial).

**Branch-wide Codex findings** (tagged `scope: "branch-wide"` in Step 3) are excluded from dedup and the primary verdict. Present them in a separate section after the main findings (see Step 6).

## Step 6: Present all findings

Sort findings by `score` descending. **Show everything — do not filter.** The user decides which items to fix.

Present Claude agent findings (#1–#5) immediately after scoring and dedup. Do not wait for Codex background tasks to present initial results — show what you have. Codex findings will be added incrementally once background tasks complete (see Incremental Codex results below).

```
## Review: <short description of what changed>

### Summary
<1-3 sentences: what changed and overall signal from the reviewers>
<Note any skipped/pending reviewers, e.g. "Codex reviews still running — findings will be added when they complete">

### Findings

[95] [critical] src/foo.ts:42–45 — Null dereference on empty response
Sources: claude-bugs
Description and recommendation.

[67] [medium] src/bar.ts:12 — Deviates from error-handling pattern in CLAUDE.md
Sources: claude-compliance · claude-history
Description and recommendation.

### Branch-wide Codex findings (informational — excluded from verdict)
<Only shown when user scope is narrower than branch-vs-default. Omit section if all Codex findings are in scope.>

### Verdict: `approve` | `approve-with-nits` | `changes-requested`
<If Codex reviews are still pending, label as: "Verdict (preliminary — Codex pending): ..." and note that the user should not act on a preliminary verdict. Present the final verdict after all reviewers complete.>
```

**Incremental Codex results:** When Codex background tasks complete (after initial presentation), normalize their findings per Step 4.5, deduplicate against existing findings, and **append new Codex findings to the presented list**. Update the verdict if new high-confidence findings change it. Clearly mark additions: "Codex review completed — N new findings added."

Verdict is based on the presence of high-confidence findings (score ≥ 75):
- Any critical/high at ≥ 75 → `changes-requested`
- Only medium/low or all < 75 → `approve-with-nits`
- No findings or all cosmetic → `approve`

## Step 7: Ask when unsure (during review)

If questions arise while reviewing findings (after Step 6), ask the user:
- A finding's validity depends on intended behavior that wasn't clarified in Step 2.
- A change contradicts existing patterns — ask if the deviation is deliberate.

Do NOT ask about things determinable from the code or docs. Major intent questions should be caught in Step 2's intent gate, not here.

## Step 8: Wait for user approval before fixing

After presenting findings, ask: **"Which findings should I fix?"** Do **not** apply any fixes until the user explicitly approves. The user can specify by score range, severity, source, or item number. Wait for their response.

Once approved, apply only the user-approved fixes. Run available tests and linters after fixing to verify.

## Rules

1. Review what's there, not what's missing. No feature suggestions or scope expansion.
2. Read the codebase before judging — a pattern that looks wrong in isolation may be convention.
3. Blocking findings must have concrete evidence — not just "this could theoretically fail."
4. Don't flag style issues a formatter or linter would catch.
5. Trust user-provided intent context.
6. False positives to ignore: pre-existing issues, linter-catchable issues, lines not in the diff, changes that are intentional per user context. Exception: findings on unchanged lines are valid when the reviewer can show causal linkage to the diff (e.g., changed function signature breaks unchanged callers, modified type breaks unchanged consumers).
