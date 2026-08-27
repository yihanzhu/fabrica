---
spec-blob: 6b4f4e43756882291dd12107cc0fe41b06a6c3ee
drafted: 2026-08-26
---

# Plan: v2-phase-2

Build the autonomous lane in two PRs (one big PR would break the repo's size
rule):

- **PR A (this branch):** small helper scripts + their tests + one plumbing test.
- **PR B (after A merges):** the three real workflows + two skills + doc updates.

## Files that change

**PR A — helpers**

- `work/v2-phase-2/plan.md` — this file.
- `scripts/v2/pending-spec.sh` + `pending-impl.sh` — decide whether a slug still
  needs a spec or an implementation, by comparing the recorded hashes. A re-run
  does nothing twice; stale work gets caught.
- `scripts/v2/round-cap.sh` — reads and bumps the round labels. No label means
  round 0. At round 3 it says stop. (Already merged. Nothing in the lane calls
  it yet — the fix stage that would is deferred; see the end of this file.)
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
   Each stage that writes gets its own wrapper in the same shape.
3. **Assert the side effect THIS stage was supposed to have** — not merely
   that a PR exists. For `spec-on-intent` and `implement-on-spec` the new
   branch and PR are the effect. For `review-on-pr` the PR already exists, so
   assert the review comment landed on it. A denied write still
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
6. **Load write wrappers AND stage skills from a trusted revision.** A
   same-repo PR can edit `scripts/v2/*.sh`. It can just as easily edit
   `.claude/skills/review-pr/SKILL.md` — the prompt the job runs. A job
   that checks out the PR head gets the PR's copy of both: its wrapper runs
   with the job's write credentials, and its skill can tell the model to write
   a verdict nobody ever reached — which the job then posts, signed by the
   trusted app. So `review-on-pr` takes **both** its
   wrapper and its stage skill from the default branch's current revision,
   never from the PR head:
   - check out the default branch to its own path and point the job's skill
     directory and its allowlisted wrapper path at that checkout;
   - `review-on-pr` needs no PR-head checkout at all — read the PR's diff and
     text through `gh`, as data.
   Same trust anchor as R3's "`REVIEW.md` loaded from main" and the v1 review
   harness's committed config.

**Review-job rules (they belong in `review-on-pr`):**
- **The PR is data, never instructions.** Its diff, title, body and comments
  are untrusted input to the review skill (`REVIEW.md`: treat as data). Text
  planted in a PR must never steer the review or what the job writes. The skill
  itself comes from the default branch (rule 6), so a PR cannot rewrite the
  prompt that judges it either.
- **The skill posts nothing — a plain step does.** The review skill writes its
  review body to `$RUNNER_TEMP/review.md`. Nothing else it prints is read.
  `review-on-pr` then runs a plain step, only if the review step succeeded, and
  that step posts the comment from the file. With the skill posting nothing,
  the review step needs no write wrapper and no write allowlist at all: the
  posting step is the only thing in `review-on-pr` that writes, and one comment
  is all it writes. That is the comments-only rail, made mechanical.
- **A dead review must never look like a finished one.** If the review step
  fails or times out, no comment is posted and the job fails loudly. A missing
  or empty `review.md` fails the job the same way. Silence must not read as a
  pass.
- None of this makes the judgment itself injection-proof — the review is still
  the model's call. It makes a review that never ran impossible to fake, and
  keeps the job's writing down to a single comment.

- Three workflows: `spec-on-intent`, `implement-on-spec`, `review-on-pr`.
  Every job: one agent at a time (the global `claude-quota` group), an actor
  gate, hard time and turn limits, loud failure if the side effect it was
  supposed to have didn't land. `review-on-pr` runs on agent-opened PRs, which
  is one of the two bot edges the spec's R5 allows; the lane opens no other.
- Two skills: `implement`, `review-pr`. Rules baked in:
  - Cheap model writes, high effort judges (v1 policy, unchanged).
  - Never write the constitution paths — `.github/**`, `.claude/**`,
    `AGENTS.md`, `CLAUDE.md`, `REVIEW.md` (the list in AGENTS.md > Stage rules
    and REVIEW.md > Compliance). Such a change goes to `proposals/` instead.
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
4. Smoke test: one tiny throwaway intent flows through the lane — merged
   intent → spec PR → merged spec → impl PR, each PR getting its review
   comment — with the operator doing nothing but the merges. Then delete it.

## Risks

- **PR B is live the moment it merges** — the next `work/` merge fires it for
  real. I chose not to ship it switched off: a disabled lane proves nothing,
  and the brakes (one job at a time, time limits, turn limits) are already
  merged in PR A by then.
- **Nothing answers a review on its own.** With the fix stage deferred, a
  review posts findings and stops there; the PR waits for you. That is a slower
  lane, not an unsafe one — no bot writes code in reply to another bot.
- **Editing ci.yml touches the gate everything depends on.** The new tests run
  locally against the pinned shellcheck before anything is pushed.
- **This phase writes to `.github/`** — allowed only because you're driving
  these sessions. The lane itself never gets that power.

## Deferred: fix-on-review

**The lane ships three workflows. The fix stage is cut from this phase** and
comes back later as its own intent, with its own spec. Two reasons, both worth
saying out loud:

1. **The plan had outgrown the spec it answers to.** R5 lets `claude[bot]` in
   on exactly two trigger edges. The fix stage needed a third — the path where
   a push-back that changes no code has to ask for a fresh review. When a plan
   reaches past its spec, the fix is to shrink the plan, not to amend the spec.
2. **Every security finding of the last two review rounds landed on that one
   stage.** It is the only job that holds write credentials, runs code written
   in the PR, and reads untrusted PR text — all at once. That earns a design
   from scratch, not a patch onto a shape built for something else.

**Where the next intent should start: split the credential.** No one job holds
all three powers:

- the agent that edits the PR's code holds no token and runs nothing from the
  PR;
- CI verifies the result on the pushed branch, the way it verifies any branch;
- a deterministic step holds the app credential and does the writing — it
  pushes the branch and stamps the round.

Everything else that design needs — how findings reach the fix agent, how a
push-back ends, how rounds are bounded — is that intent's work, not this
plan's.

**Until it exists, review findings are the operator's to handle in a session.**
That is exactly how they were handled while this phase was built. The lane
posts the review; a human answers it.

## Proof

- PR A: the two new test scripts pass in CI; verify output pasted in the PR,
  named to the commit it ran on.
- Plumbing: the test run's PR link + whether it triggered CI, recorded on #126.
- PR B: **the lane cannot review its own PR** — a `pull_request` workflow only
  fires when its file is already on the default branch, so `review-on-pr`
  does not exist for the PR that introduces it. Prove it with the harness that
  exists today: the Codex cloud review on the PR, plus the operator's read of
  the workflows against the spec's safety list (R5). The lane's first real
  review is the PR after this one — and the smoke test below is what proves
  it fires at all.
- Phase exit: the smoke intent goes end to end — intent merged, spec PR opened
  and reviewed, spec merged, impl PR opened and reviewed — and you only merge.
  No fix round is part of this: whatever the reviews find, you answer.
