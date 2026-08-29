---
name: intent-draft
description: Draft a ystack intent — work/<slug>/intent.md — from the operator's
  one-liner or brainstorm. Use whenever the operator describes a problem, idea, or
  initiative that should enter the v2 chain.
argument-hint: "[slug-or-one-liner] [intake-issue] [intake-acceptance]"
---
# Draft an intent

The intent is the chain's entry artifact: the problem in the operator's own words,
not a solution commitment. Merging its PR is gate **G1** — acceptance into design.

1. Require the open intake issue number and its durable acceptance record. The record
   must bind this exact issue title/body revision with mode, exact SHA-256 of each non-null
   UTF-8 value returned by the forge API (no added newline/normalization), acceptance
   source, and accepter. User-directed intake requires a yshifu brief confirming it
   directly received current-session operator approval for both digests and recorded it;
   never infer approval from a pre-existing thread comment. After session loss, require a
   verifiable direct-decision reference or a fresh operator answer. Proactive intake cites
   the passed manager-review verdict and requires that comment's title/body markers to
   equal the current digests. Select the newest comment by
   the current `gh` operator with exactly one clean header and one matching anchored
   marker for each digest before looking at verdict; then require exactly one anchored
   `VERDICT: PROCEED`. A newer
   REFINE/DROP/malformed result blocks older go evidence. If either digest moved
   before G1, the record is missing, or the author created/inferred it, stop. The issue remains open
   until implementation; this PR must track it, not close it.
2. Brainstorm until the idea is concrete. Ask what an analyst would ask — scope,
   who is affected, constraints, what success looks like — a few questions at most,
   then draft.
3. Pick a short kebab-case slug; the initiative lives in `work/<slug>/`.
4. Write `work/<slug>/intent.md` exactly in the template below. Plain language; no
   implementation detail beyond real constraints.
5. Show the operator the draft and apply their corrections — the final text must
   read as THEIR words.
6. On branch `ystack/intent/<slug>` (never main), commit and open a PR titled
   `intent: <slug>`. Its body uses `Tracks #<intake>` — never `Closes` — because later
   stages still need the open intake issue. The operator merging that PR is G1.

Template — keep all six sections and headings exact:

    # Intent: <title>
    Author: <name> (<role>). Status: draft.

    ## Problem
    <what can't be done today; who feels it; evidence>

    ## Proposed outcome
    <what better looks like — an outcome, not an implementation>

    ## Affected users and systems
    <people, repos, workflows touched>

    ## Constraints
    <hard limits: budget, auth, compatibility, safety rails>

    ## Open questions
    <what the operator or the design stage must still answer>

**Write in plain language.** Short sentences, everyday words — the reader is a
tired human, not another agent (see AGENTS.md > PR rules).
