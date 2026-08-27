---
spec-blob: 2efc5c5d6182e9f72c2e1f50e150d0d51faa4faf
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

**PR B — the lane** (PR A merged; the plumbing test PASSED — run 33088639117:
the agent published a branch and opened PR #140 as `app/claude` with zero
denials, and that PR triggered CI by itself. App events cascade, so the lane
uses the direct path and the spec's PR-creation fallback is retired.)

**Rules the probe cost us five failures to learn — every workflow below obeys
them, and a reviewer should reject any that does not:**
1. **Allowlist by command prefix, never by argument text.** `Bash(git push:*)`
   matches; `Bash(git push -u origin some-branch:*)` matches nothing and the
   call is silently denied.
2. **Put writes behind a deterministic wrapper and allowlist only that.** See
   `scripts/v2/probe-publish.sh`: it fixes the branch name, the files it
   stages, and the refspec, and refuses arguments that are not this run's.
   Each stage gets its own wrapper in the same shape.
3. **Assert the side effect THIS stage was supposed to have** — not merely
   that a PR exists. For `spec-on-intent` and `implement-on-spec` the new
   branch and PR are the effect. For `review-on-pr` the PR already exists, so
   assert a review marker naming the head it reviewed. For `fix-on-review`
   assert a new head SHA (or a posted push-back). A denied write still
   reports `is_error: false`, so a vacuous assert means a green job that did
   nothing.
4. **Verify secrets through the API, never by assuming a paste landed** —
   auth resolves at execution time, so a bad token looks like a working
   workflow until the run dies.
5. **A brand-new workflow can only be dispatched once its file is on the
   default branch.** After that, `gh workflow run <file> --ref <branch>` runs
   the branch's version fine — so changes to an existing workflow CAN be
   tested before merge. (An earlier draft of this plan claimed dispatch never
   works off-default; that was a wrong inference from a run that actually
   failed on the allowlist.)
6. **Load write wrappers from a trusted revision.** A same-repo PR can edit
   `scripts/v2/*.sh`; a job that checks out the PR head and then allowlists
   that path runs the PR's script, not the audited one, with the job's write
   credentials. Review and fix jobs read their wrappers from the default
   branch — the same trust-anchor rule the v1 review harness already uses for
   committed config.

**Reviewer-loop rules (they belong in `fix-on-review`):**
- **Bind a verdict to the head SHA it reviewed, never to a timestamp.** A
  review of head A can land after head B is pushed, so a timestamp fence
  accepts it and the fix loop then edits B in response to findings about A.
  Codex's own review body names the commit it reviewed; parse that SHA and
  refuse to act unless it equals the PR's current head. (Same discipline as
  the v1 merge harness, which pins to the reviewed head and refuses when it
  moves.)
- **Wait for an explicit completion marker, not a fixed delay.** A settle
  window is a heuristic: a slow review wakes the fix job early, and a late
  comment can start a duplicate pass. Poll for a completed verdict naming the
  expected head, up to a bounded timeout, then escalate rather than guess.
- **Bump the round label BEFORE acting**, so a crash can only overcount.

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

1. ~~PR A: the helpers, tests and probe.~~ **Done** — merged as #131.
2. ~~Run the plumbing test.~~ **Done** — run 33088639117 passed: the agent
   published a branch and opened PR #140 itself, and that PR triggered CI.
   The spec's PR-creation fallback is **retired**; the lane uses the direct
   path. Recorded on #126.
3. **Next: build PR B** (the section above) → operator merges. The lane is
   live at that moment.
4. Smoke test: one tiny throwaway intent flows through the whole lane, with
   the operator doing nothing but the merges. Then delete it.

## Risks

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
