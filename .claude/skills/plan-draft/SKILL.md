---
name: plan-draft
description: Write work/<slug>/plan.md — the implementation plan — from an approved
  (merged) spec, BEFORE any code. Use at the start of implementation, after G2; the
  implement stage commits this plan as the first commit of its branch.
argument-hint: [slug]
---
# Draft a plan

Nothing is implemented without an accepted plan. The plan is committed before code,
on the same branch as the implementation (`ystack/impl/<slug>`), so review can
check the eventual diff against it.

Slug: `$0`

1. Read `work/$0/spec.md` **from main**. Record `git hash-object work/$0/spec.md`.
   Freshness check first: if the spec's own `intent-blob` no longer matches main's
   current `work/$0/intent.md`, STOP — the chain is stale; tell the operator
   instead of planning.
2. Read enough of the codebase to name real files — no placeholder paths.
3. Write `work/$0/plan.md`:

       ---
       spec-blob: <hash from step 1>
       drafted: <YYYY-MM-DD>
       ---
       # Plan: <slug>

       ## Files that change
       ## Order of work
       ## Risks
       ## Proof

   **Proof** names the tests/checks that demonstrate each requirement and exactly
   how to run them.
4. Interrogate your own plan before showing it: what could this break, which step
   is riskiest, what alternative did you reject and why — the answers belong under
   Risks.
5. The bar: someone who never saw this conversation could implement from the plan
   alone. Commit it as the **first commit** on `ystack/impl/$0`. If implementation
   later departs from the plan, update `plan.md` in the same commit that departs.

**Write in plain language.** Short sentences, everyday words — the reader is a
tired human, not another agent (see AGENTS.md > PR rules).
