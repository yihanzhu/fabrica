# Intent: plain-language cleanup

Author: Yihan (operator). Status: draft.

## Problem

The repo's own docs break the plain-language rule (#129). The README, quickstart,
north star, and the agent prompts are dense and hard to read. New readers get
lost, and so do we.

## Proposed outcome

Every doc in the repo reads plainly: short sentences, everyday words, nothing
lost. A newcomer can read the README and quickstart once and know what fabrica
is and how to start.

## Affected users and systems

Anyone reading the repo (operator, adopters). Files: README, QUICKSTART,
NORTH_STAR, RESTORE, CLAUDE.md, manager/CLAUDE.md, routines/, reviewer/,
templates/, work/ and proposals/ readmes.

## Constraints

- Runs **after** v2-phase-2 lands. Its second PR already rewrites parts of
  README and QUICKSTART — doing both at once means conflicts.
- Agent prompts (manager, routines, reviewer) are live instructions: simplify
  the wording, never drop a rule. Behavior must not change. Safety-rail wording
  changes need explicit operator sign-off (existing CLAUDE.md rule).
- Small PRs per the size rule — likely: human docs, then agent prompts, then
  templates.

## Open questions

- Do script comments count? Suggestion: only where they confuse — they serve
  coders, not readers.
- Should the spec include a read test — e.g. someone follows QUICKSTART cold
  and it works?
