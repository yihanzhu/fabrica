# work/ — the v2 artifact chain

One initiative per directory: `work/<slug>/`. Every stage commits an artifact the
next stage reads. G1/G2, the risk-based plan gate, and G3 are manually enforced today
alongside the current issue/label/CI/review loop. Mechanical hooks and durable stage
records remain future work; a manual pass must never be described as automatic.

| Artifact | Written by | Gate that accepts it |
|---|---|---|
| `intent.md` | operator + `/intent-draft` | **G1** — operator merges the `intent: <slug>` PR |
| `spec.md` | `/spec-draft` (spec stage) | **G2** — operator merges the `spec: <slug>` PR |
| `plan.md` | `/plan-draft` | **High risk:** independent review + operator merge of a plan-only PR before code. **Routine:** independent check of the first implementation-branch commit before code. |
| implementation | coder | **G3** — CI + independent review, then operator merge |

## Manual risk-based plan gate

- `ready` means cleared and unclaimed; `claimed` means one active or unresolved pickup,
  and `needs-human` overrides both. Build labels/comments live on the intake issue; fix
  labels/comments live on the exact PR while parent `ready` remains absent. Build claim
  adds/verifies `claimed` then consumes an existing `ready` label as the pickup winner.
  Fix claim relies on the one-manager-session invariant. Both carry a unique claim ID
  and exact tuple; under that invariant a crash leaves `claimed` visible and blocks
  duplicate spawn. It is not a cross-manager mutex; detected parallel managers pause with
  `needs-human` until one manager reconciles state.

- For new normal implementation work, the GitHub issue is intake/message bus only;
  it cannot substitute for a hash-linked artifact. Merge `intent.md` (G1) and
  `spec.md` (G2) before planning. Already-open legacy implementation PRs may finish;
  a new attempt, rescope, or replacement uses this chain.
- On activation, remove and verify `ready` absent for every already-open implementation
  PR, then use `legacy-open` fix mode. A PR-absent issue may keep `ready` only with a
  complete new build tuple; a named bootstrap also needs its exact durable approved
  plan record. Otherwise clear it and run the new gates. The old label alone is not
  acceptance evidence.
- The only activation bridge is ystack-self issue **#180**, frozen at title/body
  SHA-256s `071e33752077f05c8f429f13d4ce2783b0478b2b8ef276db684b4472d62dd202` /
  `58fa9039359cc0d19cb9541282076d83bb5eb4360a9ccdb2f460920df5acd03a`, for its pinned
  `portable-core-contracts` attempt; external targets and other slugs never qualify. It
  ends on any issue edit. It pins all artifact PRs/blobs,
  operator-merged plan, branch, exact local/remote head, PR `absent`, old base, and clean
  state. Its terminal implementation intake is #155 at title/body SHA-256s
  `615e60decfa6c0c7fb769a7c4b595c8cbc47b52dfacd3babcd6fdb763deaa834` /
  `3426f4962a4d61ba64a1c606b410641117ec97d44fe8dfe618defba35b5aeae6`.
  Re-open that unchanged issue after policy merge and before `ready`; the implementation
  PR alone uses `Closes #155`. The bridge grandfathers the old stage-closing artifact PRs,
  then resumes only as `artifact-high/high/plan-refresh`. Any mismatch or new
  scope returns through G2 and plan acceptance. Immutable identity is the pinned target,
  slug, artifact PRs/blobs, plan/risk/scope, size/range, branch, and resulting PR number.
  The PR-absent head/base/clean tuple is one-time eligibility evidence. Normal fixes may
  advance current head/round and a base move triggers re-review; rebind exact evidence each
  round on the same PR. Any immutable-field change ends the bridge and returns through G2
  spec-with-risk plus a new high-risk plan gate; it never authorizes another attempt.
- Before G1, record the accepted intake revision on the issue: mode, issue reference,
  exact title and body SHA-256s, acceptance source, and accepter. Hash the non-null UTF-8
  values returned by the forge API with no added newline or normalization. A title/body change before G1 merge
  invalidates this record. After G1, issue text cannot amend artifacts; real scope
  changes return through the affected gates. The intent author cannot create or infer
  acceptance. User-directed mode requires yshifu to receive approval for those digests
  directly in the current session and record it immediately; after session loss, a
  pre-existing comment alone is not authority, so re-ask without a verifiable direct
  decision reference. Proactive mode also requires the source verdict's title/body markers
  to equal those digests; either moving during manager review produces
  no usable verdict. Select the newest current-operator comment with exactly one clean
  header and one matching anchored marker for each digest before looking at verdict; then require exactly one
  anchored `VERDICT: PROCEED`. A newer REFINE/DROP/malformed result blocks older go
  evidence; bare, cross-author, mixed, duplicate-marker, or multi-verdict evidence is untrusted.
- Keep that intake issue open through planning: intent, spec, and high-risk plan PRs
  use `Tracks #<intake>`. Only the implementation PR uses `Closes #<intake>`.
- Record `risk: high|routine` in `spec.md`; G2 review and operator merge accept it
  before planning. Missing or ambiguous risk stops for operator judgment.
- Record `review_size: standard|accepted-exception`. An exception must already be in
  the accepted spec/plan with one concern and an evidence-based range; it changes only
  the soft line signal, never scope, tests, CI, review, or human merge.
- **High risk** means constitution paths, workflows, identity/auth, security controls,
  migrations, deployment/production infrastructure, or broad architecture. Draft on
  `ystack/plan/<slug>`. Every non-merge branch commit not reachable from accepted base
  changes only `work/<slug>/plan.md`. A base update is an exact merge whose parents are
  prior plan head then freshly fetched base and whose tree differs from base only at the
  plan path; review and CI rerun on the new head/base. Independent review,
  green CI, and operator merge accept that exact blob. Only then create
  `ystack/impl/<slug>` from updated main and start code.
  Record that merged default OID as `plan-base`. If default moves before the first code
  commit, keep `ready` absent, run a fresh non-author review of the unchanged plan and
  artifact hashes against the new base with exactly one anchored
  `Plan-verdict: ACCEPT|REVISE`, and require explicit operator reaffirmation on the
  intake issue. Unique ACCEPT plus reaffirmation records a new plan-base; REVISE,
  zero/multiple verdicts, or changed meaning returns to
  a plan-only PR.
- **Routine** work fetches the current default OID, creates `ystack/impl/<slug>` from
  that exact branch base, and drafts `plan.md` as the first commit. An independent reviewer
  who is not the author reads the pushed plan-only remote head. Each record names
  `acceptance_kind: initial|plan-update|base-refresh`. Initial history is linear from
  branch base to head, its first commit parent equals branch base, every commit touches
  only `work/<slug>/plan.md`, and `branch-base=current-base`. A plan update is a
  single-parent head whose parent is the exact paused implementation head and whose
  commit changes only the plan path; record prior plan-acceptance head separately.
  For a plan update before the first code commit, paused head equals prior
  plan-acceptance head. Base refresh uses the
  merge topology below. The parent issue records branch, head OID,
  branch-base OID, current-base OID, plan blob, spec blob, intent blob, reviewer, and
  acceptance. Initial/base-refresh acceptance predates the first code commit;
  plan-update acceptance predates the next one. Yshifu directly coordinates a fresh
  non-author read-only reviewer and reads the complete raw verdict. Require exactly one
  anchored `Plan-verdict: ACCEPT|REVISE`; only ACCEPT advances, while REVISE keeps
  `ready` absent and returns to the plan author. The reviewer returns
  evidence only; yshifu posts it verbatim with reviewer identity/model and exact tuple.
  Existing comments cannot substitute; if the run is not provable, rerun it. No separate routine plan PR opens. Plan +
  code stay in one implementation PR.
- A non-bridge high-risk plan change returns through a plan-only PR; a bridge
  pinned-field change first follows its G2 rule above. A routine plan change stops
  work and records the exact paused head. If code already exists, make and push one update
  commit that changes only `work/<slug>/plan.md` on top of that history; its parent must
  equal the paused head. A different read-only reviewer checks that exact remote head and
  records paused head, matching plan-update parent, prior plan-acceptance head, and fresh
  acceptance before the next code commit. Do not rewrite history to create another
  plan-only branch head. Either kind of change invalidates
  earlier plan acceptance. When a high-risk plan changes after implementation starts,
  merge updated main into the same implementation branch after the plan PR lands; never
  reset/rebase/force or create a duplicate PR. Recheck the clean tuple and treat the base
  move as invalidating old review evidence.
- If the fetched default moves after routine plan acceptance but before the first code
  commit, preserve the same branch and merge the new default without reset/rebase/force.
  A `base-refresh` head must be an exact two-parent merge: first parent is the prior accepted
  head and second parent is the freshly fetched current-base OID. Keep the original
  branch base; the branch must differ from current base only by `plan.md`. Push it and
  obtain fresh exact-head/prior-head/branch-base/current-base acceptance before code.
  A conflict or intervening commit stops.
- Allowed `gate_mode/risk/branch_state` combinations are exact. Build allows
  `artifact-high/high/{fresh-high,existing,plan-refresh}`,
  `artifact-routine/routine/existing`, and either bootstrap mode with
  `high/bootstrap`. Fix allows high artifact work with `existing|plan-refresh`, routine
  artifact work with `existing`, either bootstrap mode with `high/bootstrap`, and
  `legacy-open/{high,routine}/legacy-open`. Anything else stops. Build-mode existing or
  plan-refresh has PR `absent` plus exact local HEAD/clean state. High-risk preserved
  attempts add old/current base. Routine initial acceptance has
  `branch-base=current-base`; base refresh adds prior accepted head and
  prior/current-base. Fix mode binds repo/branch/local HEAD equal to the open PR's
  remote head, current base, round, and `worktree: clean`.
- Routine tuples also record `routine_phase: plan-only|code-started`. Base refresh is
  only for plan-only state whose current HEAD equals latest plan acceptance. Code-started
  state binds an exact preserved descendant HEAD; a base move updates attempt context and
  invalidates review evidence. Recompute intent/spec blobs, both hash links, and accepted
  spec risk against the fresh base; only an exact match preserves plan acceptance. Never
  label it base-refresh.
- The existing sole-purpose add-CI and greenfield-bootstrap paths keep their concrete
  operator-approved bootstrap plans and human merge. They are the only process exceptions
  to a `work/<slug>/plan.md`; neither authorizes ordinary work to skip this gate.

**Chain state is the artifacts themselves, hash-linked.** `spec.md` frontmatter
records `intent-blob` — the `git hash-object` of the intent it was drafted from;
`plan.md` records `spec-blob`. Before acting on any artifact, compare its recorded
hash against main's current upstream file: on mismatch, label the PR `stale` and
stop — never build on a moved artifact. High-risk implementation also compares its
plan with main's operator-merged plan blob; routine implementation compares with the
latest exact accepted head/plan blob for its recorded acceptance kind. The first commit
proves only the initial plan-before-code order.

**Deterministic branches:** `ystack/intent/<slug>`, `ystack/spec/<slug>`, high-risk
`ystack/plan/<slug>`, and `ystack/impl/<slug>`. A re-run updates the existing open
branch/PR; it never keeps two PRs open for one slug and stage. After a merged stage needs
an amendment, reuse its deterministic branch and open the next PR for that stage.

Today the artifact stages and risk decision run by hand. Autonomous wiring is paused:
draft PR #146
proved that portable adapters, credential separation, evals, and durable
reconciliation must land first. [`ROADMAP.md`](../ROADMAP.md) is the authoritative
rollout order; no forge event name or agent harness is a core gate.
