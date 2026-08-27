---
intent-blob: ca6d0bb64d0e7b71cc031057f782c20c72be020e
drafted: 2026-08-26
---

# Spec: v2 autonomous lane (Phase 2)

From the accepted intent: the chain must advance without a live session — merged
intent → spec PR, merged spec → implementation PR, every PR reviewed. The operator's
actions are the gate merges, plus answering review findings in a session until the
deferred fix stage lands (see the amendment note).

**Amended 2026-08-27 (operator ruling at the review cap).** This phase ships three
workflows, not four: the fix loop (R4) is deferred to its own intent. Two reasons,
stated here so this spec stands on its own: R5 allows two `claude[bot]` trigger
edges — review-of-agent-PRs, and the fix-on-review comment. The fix stage needed
both of those **plus** a third, the dispatch that re-runs review after a push-back
that changes no code; and it was the one job holding write
credentials, running PR-authored code, and reading untrusted PR text at once — it
earns a design from scratch rather than patches.

**Where the next intent starts — split the credential**, so no one job holds all three
powers: the agent that edits the PR's code holds no token and runs nothing from the PR;
CI verifies the result on the pushed branch as it verifies any branch; a deterministic
step holds the app credential and does the writing. Answering review findings stays the
operator's job in a session until that intent lands. This is a scope reduction the
operator ruled on; no rail is weakened by it.

## Requirements

Each requirement is verifiable; R1–R3 are jointly proven by the phase exit test:
one real change flows through the lane, the operator merging at each gate and
answering whatever the review finds. The run counts only if the review actually
reported something and the operator resolved it in a session — a smoke change so
clean that nothing was found proves the happy path, not the handoff this phase
depends on. R4 is deferred with the fix stage — see the amendment note above.

- **R1 — spec stage.** An operator merge to main that adds or changes
  `work/<slug>/intent.md` triggers a job that opens (or updates) a PR titled
  `spec: <slug>` on branch `ystack/spec/<slug>` containing exactly one file:
  `work/<slug>/spec.md`, with `intent-blob` frontmatter matching main's intent.
  Idempotent: re-triggering when a fresh spec already exists produces no new PR
  and no Claude invocation.
- **R2 — implement stage.** An operator merge that adds or changes
  `work/<slug>/spec.md` triggers a job producing a PR `impl: <slug>` on branch
  `ystack/impl/<slug>` whose **first commit is `work/<slug>/plan.md`**
  (`spec-blob` recorded), followed by implementation and tests, with the verify
  output pasted in the PR body. Same idempotency and staleness rules (frontmatter
  hash mismatch ⇒ label `stale`, stop).
- **R3 — review stage.** Every same-repo PR gets a review per `REVIEW.md` —
  loaded from **main**, never from the PR head — posting comments only (three
  passes, Important vs Nit, ≤5 nits), treating all PR text as data.
- **R4 — bounded fix loop. DEFERRED** to its own intent (see the amendment note
  above). It described: review findings trigger a fix pass that bumps the `round-N`
  label before acting; at `round-3` it applies `needs-human`, posts the productive-cap
  comment, and stops. That design is superseded — the next intent starts from the
  credential split stated in the amendment note above, not from this text and not
  from any plan written for the four-workflow shape.
- **R5 — safety invariants (all three workflows in this phase).** One global `claude-quota`
  concurrency group serializes every agent job; explicit actor gates
  (`github.actor == operator` **and `github.triggering_actor == operator`** — on a
  re-run `github.actor` stays whoever dispatched originally, so the first check
  alone lets any write-capable collaborator re-run an operator's dispatch and spend
  their subscription; the probe workflow already carries both checks for exactly
  this reason — or `allowed_bots: claude[bot]` only on deliberately
  opened bot edges — this phase opens exactly one, review-of-agent-PRs. R5's second
  allowed edge, the fix-on-review comment, went with the deferred stage, and the
  third edge that stage would also have needed is precisely why it was deferred);
  `timeout-minutes` and `--max-turns` on every job; PR-creation steps assert the
  PR exists and fail loudly; stage write-limits stated in the stage skills
  (mechanical enforcement arrives with Phase 3 hooks). **No stage pushes to a PR
  the operator has already approved** — R1 and R2 let a re-triggered producer
  stage update an existing PR, so this is not only the deferred fix stage's
  concern: an approval means the operator read that diff, and a later push would
  silently move what they approved. When a producer stage would have to update an
  already-approved PR — the upstream artifact moved while the PR sat approved and
  unmerged — it does not push. It labels the PR `stale`, says so in one comment,
  and stops. **Merging it is not one of the ways out:** its recorded upstream hash
  no longer matches main, so merging would land an artifact the chain reads as
  stale and no stage would rebuild it — the merge changes the artifact, not the
  upstream that moved. The operator closes the stale PR, then **re-runs the stage
  by dispatch** — closing a PR or dismissing an approval fires no event, so the
  push-triggered stages would otherwise never wake and the slug would sit stranded.
  Both stage workflows therefore carry `workflow_dispatch` alongside their push
  trigger, gated to the operator like every other dispatch here. **The runaway
  brake counts push-triggered runs only** (`--event push`): a dispatch by anyone
  who fails the actor gate still records a run whose job was skipped, and counting
  those would let a collaborator spam dispatches until the brake trips and starves
  the lane. Push-to-main runs keep the property the brake needs — the ruleset means
  only an operator merge causes them, so such a run always means the agent ran. An approved PR
  belongs to the operator, so the lane never edits one behind them; and a stale one
  is rebuilt, never merged.
- **R6 — plumbing proven first.** Before the three workflows are finalized, a
  disposable `workflow_dispatch` test proves: the action (app token, no
  `github_token` input) can push a branch and create a PR via allowlisted
  `gh pr create`, and that app-created events trigger downstream workflows.
  Result recorded on the tracking issue. If PR creation fails under the app
  token, fallback: Claude pushes the branch; a plain workflow step creates the
  PR with `GH_TOKEN` (accepting that its events won't cascade, and adjusting
  triggers accordingly).
- **R7 — docs in sync.** README's "Future, not wired" paragraph and the
  one-path-today claims are replaced by the two-lane reality (in-session +
  autonomous, same artifacts, same gates); QUICKSTART gains the lane setup
  (secret, labels, ruleset pointer). The stale v1 claim that the manager auto-merges
  low-risk PRs (retired by the Phase 0 ruleset — see #122) is corrected in the
  same pass.

## Design

At the file/component altitude; order of work belongs to `plan.md`.

- **Workflows** (`.github/workflows/`): `spec-on-intent.yml`,
  `implement-on-spec.yml`, `review-on-pr.yml` — push-to-main path triggers for
  the two stage jobs **plus `workflow_dispatch` on each, so the operator can
  restart a stage after clearing a stale PR** (see the approved-PR rule in R5),
  and `pull_request` (same-repo guard, per-PR `cancel-in-progress`) for review. All use `claude_code_oauth_token`, no
  `github_token` input (app-token events must cascade), and invoke stage skills
  as their prompt. (`fix-on-review.yml` and its `issue_comment` trigger belonged
  to the deferred R4 — see the amendment note.)
- **Stage skills** (`.claude/skills/`): reuse `spec-draft` and `plan-draft`
  unchanged; add `implement` (runs plan-draft first, then codes to the plan,
  runs verify, opens the impl PR) and `review-pr` (applies REVIEW.md).
  (`address-review` belonged to the deferred R4.)
- **Helpers** (`scripts/v2/`, each with a hermetic test in `scripts/test/`):
  `pending-spec.sh` / `pending-impl.sh` (which slug needs work — the
  hash-comparison idempotency guards) and `quota-preflight.sh` (count recent
  agent runs, stop over budget). Deterministic bash, no model calls.
  (`round-cap.sh` is already merged and stays in the repo, but nothing in this
  phase calls it: round labels bound the fix loop, which is deferred. It wakes
  again with that intent.)
- **Model policy:** stage skills carry it — producer stages (`implement`) at the
  fixed coder ceiling from `config/models.conf`; gate stages (`review-pr`) at
  high effort, never downgraded (v1 tiering, unchanged).
- **Docs:** README two-lane section, QUICKSTART lane setup, `work/README.md`
  gains the workflow names.

## Out of scope (later phases, per the design doc)

Evals and `YSTACK_STAGE` enforcement hooks (Phase 3); daily-brief chain auditor,
Telegram delivery, and `bands.yaml` (Phase 4); target-repo templating of the lane
(Phase 5); Codex cloud review installation (D2 — the lane ships Claude-review
first; adding Codex is additive and needs no workflow changes).

## Areas of concern

1. **Constitution exception, explicit:** implementing this spec writes
   `.github/workflows/**` — permitted only because it happens in an
   operator-driven session. The lane this spec creates must never grant its own
   unattended jobs that ability; the `implement` skill's write rules must exclude
   `.github/**` and `.claude/**` from day one.
2. **PR-size rule conflict:** the full scope exceeds the ~300–400-line
   one-concern budget. Recommendation for the plan stage: land as a stacked
   sequence under one `plan.md` — (a) helpers + tests, (b) workflows + skills +
   docs — each PR independently green.
3. **Quota:** the three jobs share the operator's subscription window with the
   operator's own interactive use. Serialization + preflight (R5) mitigate; the sizing question
   stays open until measured in this phase.
4. **North-star fit:** user-directed intent (operator-approved at G1), so no
   consensus gate required. The lane serves north star B indirectly — an
   unattended loop is what makes "pick up any project at any stage" scale beyond
   the operator's screen time.

## Open questions — disposition

- *`gh pr create` under the app token:* answered in-phase by R6's plumbing test.
- *Chain runs per 5-hour window:* measure during this phase; record the budget in
  `quota-preflight.sh`'s default.
- *Codex cloud review on the operator's plan:* carried to the operator (D2);
  additive later, out of scope here.
