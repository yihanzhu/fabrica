---
name: spec-draft
description: Produce work/<slug>/spec.md — requirements and design in one pass —
  from an accepted (merged) intent. Use after an intent PR merges (G1). Runs by
  hand today; the spec-on-intent workflow invokes it in the autonomous lane.
argument-hint: "[slug] [intake-issue]"
---
# Draft a spec

Requirements and design collapse into one pass, and policy is applied while the
spec is written — not discovered in review. The bar: an engineer (or the implement
stage) who never saw any conversation can plan from the spec alone.

Slug: `$0`
Intake issue: `$1`

1. Require the same open intake issue tracked by the intent PR. It remains open until
   implementation; this PR must not close it.
2. Read `work/$0/intent.md` **from main** — never from a branch. Record its blob
   hash: `git hash-object work/$0/intent.md`.
3. Read the north star (`NORTH_STAR.md` here; a target's `.ystack/north-star.md`
   elsewhere), `CLAUDE.md`, and `REVIEW.md` — the spec must conform to all three.
4. Write `work/$0/spec.md`:
   - YAML frontmatter first:

         ---
         intent-blob: <hash from step 2>
         risk: <high|routine>
         drafted: <YYYY-MM-DD>
         ---

   - Then: **Requirements** (each one verifiable when done), **Design** (the how,
     at the altitude of files/components/order — not code), **Out of scope**, and
     **Areas of concern** — flag every conflict between the intent and the north
     star, conventions, or safety rails. Never silently resolve a conflict.
5. Classify risk in that frontmatter. `high` means any constitution path, workflow,
   identity/auth, security control, migration, deployment/production infrastructure,
   or broad architecture change; otherwise use `routine`. Explain the reason under
   Areas of concern. Missing or ambiguous classification stops for operator judgment
   before the PR; never choose `routine` to avoid the stronger gate. G2 merge accepts
   both the spec and this risk value.
6. Answer or explicitly carry forward every Open question from the intent — none
   may vanish.
7. **Stage rule:** this pass writes ONLY `work/$0/spec.md` — never the intent,
   other files, or any config.
8. On branch `ystack/spec/$0` (reuse if it exists — update, never duplicate),
   commit and open/update a PR titled `spec: $0`. Its body uses
   `Tracks #<intake>` — never `Closes`. The operator merging it is **G2**: approval
   to plan, not approval to write code.

**Write in plain language.** Short sentences, everyday words — the reader is a
tired human, not another agent (see AGENTS.md > PR rules).
