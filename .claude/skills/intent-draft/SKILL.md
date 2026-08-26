---
name: intent-draft
description: Draft a fabrica intent — work/<slug>/intent.md — from the operator's
  one-liner or brainstorm. Use whenever the operator describes a problem, idea, or
  initiative that should enter the v2 chain.
argument-hint: [slug-or-one-liner]
---
# Draft an intent

The intent is the chain's entry artifact: the problem in the operator's own words,
not a solution commitment. Merging its PR is gate **G1** — acceptance into design.

1. Brainstorm until the idea is concrete. Ask what an analyst would ask — scope,
   who is affected, constraints, what success looks like — a few questions at most,
   then draft.
2. Pick a short kebab-case slug; the initiative lives in `work/<slug>/`.
3. Write `work/<slug>/intent.md` exactly in the template below. Plain language; no
   implementation detail beyond real constraints.
4. Show the operator the draft and apply their corrections — the final text must
   read as THEIR words.
5. On branch `fabrica/intent/<slug>` (never main), commit and open a PR titled
   `intent: <slug>`. The operator merging that PR is the acceptance gate.

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
