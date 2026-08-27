---
name: spec-draft
description: Produce work/<slug>/spec.md — requirements and design in one pass —
  from an accepted (merged) intent. Use after an intent PR merges (G1). Runs by
  hand today; the spec-on-intent workflow invokes it in the autonomous lane.
argument-hint: [slug]
---
# Draft a spec

Requirements and design collapse into one pass, and policy is applied while the
spec is written — not discovered in review. The bar: an engineer (or the implement
stage) who never saw any conversation can plan from the spec alone.

Slug: `$0`

1. Read `work/$0/intent.md` **from main** — never from a branch. Record its blob
   hash: `git hash-object work/$0/intent.md`.
2. Read the north star (`NORTH_STAR.md` here; a target's `.ystack/north-star.md`
   elsewhere), `CLAUDE.md`, and `REVIEW.md` — the spec must conform to all three.
3. Write `work/$0/spec.md`:
   - YAML frontmatter first:

         ---
         intent-blob: <hash from step 1>
         drafted: <YYYY-MM-DD>
         ---

   - Then: **Requirements** (each one verifiable when done), **Design** (the how,
     at the altitude of files/components/order — not code), **Out of scope**, and
     **Areas of concern** — flag every conflict between the intent and the north
     star, conventions, or safety rails. Never silently resolve a conflict.
4. Answer or explicitly carry forward every Open question from the intent — none
   may vanish.
5. **Stage rule:** this pass writes ONLY `work/$0/spec.md` — never the intent,
   other files, or any config.
6. On branch `ystack/spec/$0` (reuse if it exists — update, never duplicate),
   commit and open/update a PR titled `spec: $0`. The operator merging it is
   **G2**: approval to build.

**Write in plain language.** Short sentences, everyday words — the reader is a
tired human, not another agent (see CLAUDE.md > PR rules).
