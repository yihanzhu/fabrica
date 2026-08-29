---
name: plan-draft
description: Write work/<slug>/plan.md from an approved spec and run the manual
  risk-based pre-code gate. High-risk plans use a plan-only PR; routine plans are the
  first implementation-branch commit and get an independent check before code.
argument-hint: "[slug] [high|routine] [intake-issue] [standard|accepted-exception]"
---
# Draft a plan

Nothing is implemented without the applicable plan gate. The plan author cannot
accept its own plan. This skill is manual policy, not a mechanical hook.

Slug: `$0`
Risk: `$1`
Intake issue: `$2`
Review size: `$3`

1. Require `$2` to be the same open intake issue tracked by the merged intent/spec
   PRs. It remains open for implementation; a plan PR must not close it.
2. Require `$1` to be exactly `high` or `routine` and match the risk recorded in the
   accepted spec frontmatter. Missing, ambiguous, or different risk stops for operator
   judgment before any branch or edit. A GitHub issue cannot substitute for the
   merged `work/$0/intent.md` and `spec.md`; new normal work reaches G1/G2 first.
3. Require `$3` to be `standard` or `accepted-exception`. An exception is valid only
   when the accepted spec already names it **or** this plan proposes one concern, the
   reason, and an evidence-based range. A plan proposal is not accepted yet: the
   high-risk operator merge or routine independent exact-plan check below is its
   pre-code acceptance. It never waives scope, readability, tests, CI, review, or merge.
4. Read `work/$0/spec.md` **from main**. Record `git hash-object work/$0/spec.md`.
   Freshness check first: if the spec's own `intent-blob` no longer matches main's
   current `work/$0/intent.md`, STOP — the chain is stale; tell the operator
   instead of planning.
5. Read enough of the codebase to name real files — no placeholder paths.
6. Write `work/$0/plan.md`:

       ---
       spec-blob: <hash from step 4>
       drafted: <YYYY-MM-DD>
       ---
       # Plan: <slug>

       ## Files that change
       ## Order of work
       ## Risks
       ## Proof

   **Proof** names the tests/checks that demonstrate each requirement and exactly
   how to run them.
7. Interrogate your own plan before showing it: what could this break, which step
   is riskiest, what alternative did you reject and why — the answers belong under
   Risks.
8. The bar: someone who never saw this conversation could implement from the plan
   alone. Then take exactly one path:

   - **High risk:** create/reuse `ystack/plan/$0`. Commit only
     `work/$0/plan.md`, open/update a plan-only PR, run independent review and CI,
     and use `Tracks #$2`, never `Closes`. Stop for operator merge. Do not create the implementation branch or write
     code before that merge. After merge, implementation starts from updated main on
     `ystack/impl/$0`. Any plan change invalidates acceptance and returns through a
     new/current plan-only PR. Every non-merge branch commit not reachable from accepted
     base must touch only that plan path. A base update is allowed only as an exact merge
     whose parents are prior plan head then freshly fetched base and whose tree differs
     from base only at the plan path; rerun review and CI. If implementation already exists, pause it; after the
     plan PR merges, merge updated main into the same implementation branch without
     reset/rebase/force, recheck the exact plan tuple, and resume only on a clean match.
     After merge, record the fetched default OID containing the plan as `plan-base`.
     Before first code, a moved default keeps `ready` absent and needs a fresh non-author
     review of the unchanged plan/artifact hashes with exactly one anchored
     `Plan-verdict: ACCEPT|REVISE` plus explicit operator reaffirmation. Unique ACCEPT
     records the new plan-base; REVISE, zero/multiple verdicts, or changed meaning returns
     here through a plan-only PR.
     Record accepted gate mode `artifact-high`.
   - **Routine:** fetch the current default branch and record its exact OID. Create/reuse
     `ystack/impl/$0` from that branch base and commit `work/$0/plan.md` as its first commit.
     Push that plan-only head to the remote without opening a PR. Before any code commit,
     every acceptance records `acceptance_kind: initial|plan-update|base-refresh` and
     `routine_phase: plan-only|code-started`. Initial, base-refresh, and a pre-code
     plan-update are plan-only; a post-code plan-update or implementation descendant is
     code-started. A
     fresh non-author read-only reviewer verifies `initial` as linear plan-only
     history with first parent equal to branch base and `branch-base=current-base`;
     `plan-update` as a single-parent head whose parent is the exact paused implementation
     head and whose commit changes only `work/$0/plan.md`, with prior plan-acceptance head
     recorded separately; or `base-refresh` with the exact merge
     topology below. It returns a complete raw verdict covering branch, head OID,
     branch-base OID, current-base OID, plan blob, spec blob, intent blob, and reviewer.
     Initial and
     base-refresh acceptance predate the first code commit; plan-update acceptance
     predates the next one. It never edits, pushes, comments, or labels. Yshifu must
     have directly coordinated this fresh
     non-author review, read its complete raw verdict, and post that verdict verbatim with
     reviewer identity/model plus the exact tuple. A pre-existing or unauthenticated
     comment never substitutes; rerun when provenance cannot be proven. Require exactly
     one anchored `Plan-verdict: ACCEPT|REVISE`; only ACCEPT creates acceptance. REVISE
     keeps `ready` absent and returns this skill to the plan author.
     Do not open a routine plan-only PR. If the plan changes after code exists,
     stop work and record the exact paused head plus prior plan-acceptance head. Add one commit that changes only
     `work/$0/plan.md` on top of the existing history; its parent must equal that paused
     head. Push the exact remote head; yshifu must coordinate a fresh non-author review,
     read its complete raw verdict, require exactly one anchored plan verdict, and post it
     verbatim with the paused head, matching
     update parent, reviewer identity/model, and exact tuple before the next code
     commit. Do not reset, rebase, or rewrite
     history to manufacture another plan-only branch head.
     If the fetched default moves after acceptance but before the first code commit,
     require `routine_phase: plan-only` and current HEAD equal to latest plan acceptance;
     merge it into this same branch without reset/rebase/force. Record
     `acceptance_kind: base-refresh`; the new head must have
     exactly two parents: the prior accepted head first and freshly fetched current base
     second. Keep the original branch base, require the branch to differ from current base
     only by `work/$0/plan.md`, push, and obtain fresh head/prior-head/branch-base/
     current-base acceptance before code. A conflict or intervening commit stops.
     Record accepted gate mode `artifact-routine`.

9. Never claim a hook, workflow, or automatic risk classifier enforced this gate.
   Record the manual reviewer, exact plan blob/head, risk class, and operator merge
   when applicable.

**Write in plain language.** Short sentences, everyday words — the reader is a
tired human, not another agent (see AGENTS.md > PR rules).
