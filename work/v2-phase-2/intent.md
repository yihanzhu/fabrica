# Intent: v2 autonomous lane (Phase 2)

Author: Yihan (operator). Status: draft.

## Problem

The chain only advances while I'm sitting in a live session driving it. When I'm
away, merged intents just sit there — nothing drafts the spec, nothing implements
an approved spec, nothing reviews a PR. Fabrica v1 deferred this as "future, not
wired"; the artifact spine from Phase 1 now exists, but every stage is hand-cranked.

## Proposed outcome

Merging an artifact fires the next stage on its own: an accepted intent produces a
spec PR; an approved spec produces an implementation PR (plan.md first, then code
and tests, verify output pasted); every PR gets a policy review with a bounded fix
loop. My only actions are the three gate merges — the loop runs while I sleep.

## Affected users and systems

Me (as gate-keeper); the fabrica repo's GitHub Actions workflows; the Phase 1 stage
skills (spec-draft, plan-draft, plus new implement/review/fix prompts); new
`scripts/v2/` helpers (idempotency, round-cap, quota preflight).

## Constraints

Runs on my Claude subscription (CLAUDE_CODE_OAUTH_TOKEN secret — no API bill).
Agents never write `.github/**` or `.claude/**` (proposals/ patches only). One
global claude-quota concurrency group; explicit actor gates on every workflow;
round cap of 3 enforced by labels bumped before acting; review config always loaded
from main, never from the PR under review. All defenses from the v2 design doc
apply.

## Open questions

Does `gh pr create` work under the app token in automation mode (the design doc's
flagged unknown — settle with a plumbing test before building on it)? How many
chain runs fit a 5-hour subscription window alongside my own use? Codex cloud
review (D2): available on my ChatGPT plan, and does it coexist cleanly with the
Claude review workflow on the same PRs?
