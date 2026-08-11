#!/bin/bash
# UserPromptSubmit hook: reinject the Response Style pointer every turn.
#
# CLAUDE.md's Response Style rules (BLUF, no preamble, epistemic-status
# labeling) load once at session start and fade under recency pressure —
# the documented pattern is tone/format drifting back toward preamble and
# buried conclusions somewhere past the first hour of a session. This hook
# fires on every prompt submission, right where recency actually helps, and
# re-points attention at the existing rule instead of restating it — cheap
# regardless of session length.
#
# Pattern source: https://joecotellese.com/posts/steering-claude-code-bluf/

echo "Reminder: apply the Response Style rules in CLAUDE.md — BLUF (conclusion first, max 5 bullets, then detail in decreasing importance) for anything non-trivial, no preamble, label epistemic status (known/inferred/guessed) when it matters, don't re-suggest a follow-up the user didn't take."
