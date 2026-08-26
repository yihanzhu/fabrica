---
spec-blob: 65c534472e457ca4eb8f3f0c6535e104a889d79a
drafted: 2026-08-26
---

# Plan: v2-phase-2

Implements the approved spec as **two stacked PRs under this one plan** (the
spec's Areas-of-concern §2 resolution of the ~300–400-line PR rule), with the
plumbing test (R6) proven between them.

## Files that change

**Stack A — `impl: v2-phase-2 (a — helpers)`, branch `fabrica/impl/v2-phase-2`**
- `work/v2-phase-2/plan.md` (this file — first commit)
- `scripts/v2/pending-spec.sh`, `scripts/v2/pending-impl.sh` (new): which slug
  needs work — the hash-guard idempotency checks (fresh / stale / missing).
- `scripts/v2/round-cap.sh` (new): read + bump `round-N` labels, emit
  `proceed=`/`stop=`; a PR with no round label counts as round-0.
- `scripts/v2/quota-preflight.sh` (new): a **runaway backstop, not a
  throughput ration** (operator decision 2026-08-26): every Phase 2 run is
  caused by an operator gate-merge or a label-bounded fix round, so legitimate
  work is already rate-limited by the operator's own clicks — real work is
  never skipped. The preflight trips only on abnormal volume (default 20
  runs/5h — a cascade-bug tripwire), fails loudly when it does, and gets a
  real budget only in Phase 4 when self-triggered runs (no human cause) arrive.
- `scripts/test/v2-pending-stage.test.sh`, `scripts/test/v2-round-cap.test.sh`
  (new): hermetic, gh/git stubbed on PATH — same idiom as the existing tests.
- `.github/workflows/plumbing-test.yml` (new, `workflow_dispatch` only): the R6
  probe — claude-code-action (app token) pushes a throwaway branch, runs
  allowlisted `gh pr create`, we observe whether the PR appears and whether its
  events cascade. Kept afterward as a permanent diagnostic.
- `.github/workflows/ci.yml`: add the two new test steps.
- `ci/required-files.txt`: register everything above.

**Stack B — `impl: v2-phase-2 (b — lane)`, branch `fabrica/impl/v2-phase-2b`,
opened only after Stack A merges and the plumbing result is recorded**
- `.github/workflows/spec-on-intent.yml`, `implement-on-spec.yml`,
  `review-on-pr.yml`, `fix-on-review.yml` (new): per the spec's design — the
  stage jobs call the helpers first, invoke the stage skills as prompts, share
  the `claude-quota` concurrency group, carry actor gates, `timeout-minutes`,
  `--max-turns`, and assert-PR-exists steps.
- `.claude/skills/implement/SKILL.md`, `review-pr/SKILL.md`,
  `address-review/SKILL.md` (new): producer skills at the coder ceiling from
  `config/models.conf`; the review skill at high effort; write-rules exclude
  `.github/**` and `.claude/**`. Two practices adopted from gstack/pstack
  (2026-08-26 review of both):
  - **Evidence binding** (gstack): the implement/fix skills paste verify output
    together with the head SHA it ran against (`verified-head: <sha>`); the
    review and fix stages treat evidence as stale when the PR head has moved
    past it — merge-pr.sh's SHA-pinning discipline, extended to test evidence.
  - **Evidence per change type** (pstack): the implement skill names what
    counts as proof for each class of change — shell → shellcheck + hermetic
    tests; workflows → CI green on the PR itself; docs → structure check —
    instead of one generic "tests pass".
- `README.md`: replace "Future, not wired" with the two-lane section; correct
  the retired auto-merge claim (Phase 0 ruleset, #122).
- `QUICKSTART.md`: autonomous-lane setup (secret, labels, ruleset pointer).
- `work/README.md`: name the live workflows.
- `ci/required-files.txt`: register.

## Order of work

1. This plan lands as the first commit; Stack A files follow on the same branch;
   PR opens with verify output pasted; **G3a** = operator merge.
2. Operator (or session) runs the plumbing test via `workflow_dispatch`; outcome
   recorded as a comment on the spec PR (#126) and in Stack B's PR body. If
   app-token `gh pr create` fails → spec R6 fallback (plain step with
   `GH_TOKEN` creates the PR; triggers adjusted for its non-cascading events)
   before Stack B is written.
3. Stack B lands; **G3b** = operator merge. The lane is live the moment it
   merges — bounded by the Stack A guards even on day one.
4. Phase 2 exit test: a trivial smoke intent (`work/lane-smoke/`) flows
   intent → spec PR → impl PR → review → fix (≤ cap) with the operator doing
   nothing but the three gate merges. Then `work/lane-smoke/` is removed by a
   follow-up PR.

## Risks

- **The plumbing unknown (R6) is load-bearing:** if the app token can't create
  PRs, Stack B's shape changes — which is exactly why the probe sits between the
  stacks and the fallback is specified in the spec, not improvised.
- **Live-fire on merge:** Stack B's workflows are armed the moment they land;
  the next `work/**` merge fires them for real. Bounds: actor gates, hash-guard
  idempotency (already merged in Stack A), one `claude-quota` group, per-job
  `--max-turns`/timeouts. Considered and rejected: shipping them disabled — a
  disarmed lane never proves itself, and the smoke test is the point.
- **`ci.yml` edit** touches the gate every PR depends on; the new steps are
  hermetic tests run locally against pinned shellcheck 0.11.0 before pushing.
- **Riskiest step:** `fix-on-review.yml` — the one deliberately-opened bot→bot
  edge. Rejected alternative: fix passes triggered by PR synchronize (tighter,
  but loops without the comment-marker + round-label brake). The label bump
  happens **before** any fix action, and the fix stage refuses approved PRs.
- **Constitution exception** (spec concern §1): both stacks write `.github/**`
  from this operator-driven session; the skills the lane ships must never allow
  its unattended jobs the same — review Stack B's skill write-rules for exactly
  this.

## Proof

- Stack A: the two hermetic test scripts green in CI; verify output (structure
  check + shellcheck + tests) pasted in the PR body.
- Plumbing: the probe run's PR link + cascade observation recorded on #126.
- Stack B / R3–R5: `review-on-pr` posts a REVIEW.md-conformant review on Stack
  B's own PR (the lane reviews the PR that ships it — same-repo trigger);
  workflow files inspected against R5's invariant list in review.
- Phase 2 exit test (R1–R4 jointly): the smoke-intent run with operator-only
  merges, verify output pasted in its impl PR body and bound to the verified
  head SHA (evidence-binding above).
- R7: README/QUICKSTART diffs read in Stack B review.
