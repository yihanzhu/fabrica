---
spec-blob: 65c534472e457ca4eb8f3f0c6535e104a889d79a
drafted: 2026-08-26
---

# Plan: v2-phase-2

Build the autonomous lane in two PRs (one big PR would break the repo's size
rule):

- **PR A (this branch):** small helper scripts + their tests + one plumbing test.
- **PR B (after A merges):** the four real workflows + three skills + doc updates.

## Files that change

**PR A — helpers**

- `work/v2-phase-2/plan.md` — this file.
- `scripts/v2/pending-spec.sh` + `pending-impl.sh` — decide whether a slug still
  needs a spec or an implementation, by comparing the recorded hashes. A re-run
  does nothing twice; stale work gets caught.
- `scripts/v2/round-cap.sh` — reads and bumps the round labels. No label means
  round 0. At round 3 it says stop.
- `scripts/v2/quota-preflight.sh` — safety brake only, never a work limiter
  (your decision: every run starts from your merge, so real work is already
  paced by you). It only trips on abnormal volume — 20+ runs in 5 hours means
  a bug. It fails loudly.
- `scripts/test/v2-pending-stage.test.sh` + `v2-round-cap.test.sh` — tests for
  the above. Run offline, no network.
- `.github/workflows/plumbing-test.yml` — manual-trigger test: can the bot push
  a branch and open a PR on its own? Kept afterward as a diagnostic.
- `.github/workflows/ci.yml` — run the two new tests.
- `ci/required-files.txt` — list the new files.

**PR B — the lane** (only after PR A merges and the plumbing test passes)

- Four workflows: `spec-on-intent`, `implement-on-spec`, `review-on-pr`,
  `fix-on-review`. Every job: one agent at a time, hard time and turn limits,
  loud failure if its PR didn't get created.
- Three skills: `implement`, `review-pr`, `address-review`. Rules baked in:
  - Cheap model writes, high effort judges (v1 policy, unchanged).
  - Never write to `.github/` or `.claude/`.
  - **Proof is tied to the code:** verify output names the exact commit it ran
    on. New commits make old proof stale.
  - **Each change type has its own proof:** shell → shellcheck + tests;
    workflows → green CI on the PR; docs → structure check.
- Docs: README (the lane replaces "future, not wired"; fix the stale
  auto-merge claim), QUICKSTART, work/README.

## Order of work

1. You approve this plan → I build PR A → you merge.
2. Run the plumbing test. Record the result on #126. If the bot can't open
   PRs, use the spec's fallback (a plain workflow step opens the PR instead).
3. Build PR B → you merge. The lane is live.
4. Smoke test: one tiny throwaway intent flows through the whole lane, with
   you doing nothing but the merges. Then we delete it.

## Risks

- **The plumbing test can fail.** That's why it runs before PR B is written —
  the fallback is already in the spec, not improvised.
- **PR B is live the moment it merges** — the next `work/` merge fires it for
  real. I chose not to ship it switched off: a disabled lane proves nothing,
  and the brakes (round labels, one-job-at-a-time, time limits) are already
  merged in PR A by then.
- **The fix loop is a bot answering a bot** — the one place we allow that.
  Brake: the round label is bumped *before* the fix runs, so the loop stops at
  3 rounds even if something else breaks. The fix job also never touches a PR
  you already approved.
- **Editing ci.yml touches the gate everything depends on.** The new tests run
  locally against the pinned shellcheck before anything is pushed.
- **This phase writes to `.github/`** — allowed only because you're driving
  these sessions. The lane itself never gets that power.

## Proof

- PR A: the two new test scripts pass in CI; verify output pasted in the PR,
  named to the commit it ran on.
- Plumbing: the test run's PR link + whether it triggered CI, recorded on #126.
- PR B: the lane reviews its own PR (the review workflow fires on it); you
  check the workflows against the spec's safety list (R5).
- Phase exit: the smoke intent goes through end to end, you only merge.
