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
   assert the stamped review marker (see the reviewer-loop rules) naming the
   head it reviewed. For `fix-on-review`
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
6. **Load write wrappers AND stage skills from a trusted revision.** A
   same-repo PR can edit `scripts/v2/*.sh`. It can just as easily edit
   `.claude/skills/review-pr/SKILL.md` or
   `.claude/skills/address-review/SKILL.md` — the prompt the job runs. A job
   that checks out the PR head gets the PR's copy of both: its wrapper runs
   with the job's write credentials, and its skill can tell the model to use
   the allowed wrapper to post a verdict nobody ever reached. So `review-on-pr`
   and `fix-on-review` take **both** their wrapper and their stage skill from
   the default branch's current revision, never from the PR head:
   - check out the default branch to its own path and point the job's skill
     directory and its allowlisted wrapper path at that checkout;
   - `review-on-pr` needs no PR-head checkout at all — read the PR's diff and
     text through `gh`, as data;
   - `fix-on-review` does need the head, because it edits those files. Check it
     out to a separate working path: files to edit, never files to run.
   Same trust anchor as R3's "`REVIEW.md` loaded from main" and the v1 review
   harness's committed config.

**Reviewer-loop rules (they belong in `review-on-pr` and `fix-on-review`):**
- **Bind a verdict to the head SHA it reviewed, never to a timestamp.** A
  review of head A can land after head B is pushed, so a timestamp fence
  accepts it and the fix loop then edits B in response to findings about A. So
  every review comment the fix job may act on ends with one machine-readable
  line, and `fix-on-review` refuses to act unless the SHA on that line equals
  the PR's current head. Same discipline as the v1 merge harness, which pins to
  the reviewed head and refuses once it moves.
- **A workflow step stamps that line — never the model.** The PR's diff, title,
  body and comments are untrusted input to the review skill (`REVIEW.md`:
  treat as data). If the skill writes the marker itself, planted text can talk
  the model into printing one for the current head without a review happening —
  and the comment still arrives signed by the trusted app, so the fix job
  believes it. The marker is a credential, so a deterministic step owns it:
  - the review skill posts nothing. It writes its review body to
    `$RUNNER_TEMP/review.md` and one word — `findings` or `passed` — alone on
    one line to `$RUNNER_TEMP/verdict.txt`. Nothing else it prints is read.
  - `review-on-pr` then runs a plain step, only if the review step succeeded.
    That step posts the comment: the body from the file, plus the marker line
    it builds itself. The SHA comes from the event
    (`github.event.pull_request.head.sha`), never from model output.
  - the skill is told in so many words: do not write a `YSTACK-REVIEW`,
    `reviewed-head:` or `verdict:` line. The stamping step strips any such
    line out of the body before it appends its own.
  - if the review step fails or times out, nothing is stamped and no comment is
    posted, so the fix job never fires. A dead review must never look like a
    finished one.
  With the skill posting nothing, the review step needs no write wrapper and no
  write allowlist at all: the stamping step is the only thing in `review-on-pr`
  that writes. That is the comments-only rail, made mechanical.
  This does not make the judgment itself injection-proof — the verdict is still
  the model's call. It makes a review that never ran impossible to forge, and
  that is the part the fix job's authority rests on. When a second reviewer is
  added later (Codex cloud, D2), it gets the same treatment: a step we control
  stamps the marker, and the reviewer's own text is never trusted for the SHA.
- **The marker carries the verdict too, and only findings wake the fix job.**
  Head alone says "this head was reviewed" and nothing more, so a clean review
  passes the fence as easily as a bad one: the fix agent wakes, has nothing to
  fix, and burns a round for nothing. The stamped line is therefore
  `YSTACK-REVIEW reviewed-head: <sha> verdict: findings|passed`, and:
  - the skill writes `findings` when it reported at least one **Important**
    finding (`REVIEW.md`'s bar), `passed` when it did not. A nit-only review is
    `passed` — nits never spend a round.
  - `fix-on-review` acts only on `verdict: findings`. On `verdict: passed` it
    exits at once: no round bump, no push, no comment.
  - if `verdict.txt` is missing, empty, or holds anything but those two words,
    the stamping step stamps nothing and fails the job loudly. A broken review
    must not read as a pass.
- **A push-back must re-trigger the review, or the standoff never ends.**
  `address-review` may answer a finding by disagreeing instead of changing
  code. That posts a comment and leaves the head where it is — and review only
  fires on a new head, so nothing ever answers the push-back: no round is
  spent, the cap is never reached, and the PR sits there. So the fix job ends
  every round by making sure a review of the current head is coming:
  - **changed code** → push it. The `pull_request` synchronize event fires
    `review-on-pr` as usual. Nothing else to do.
  - **pushed back, no code change** → the job's last step asks for the review
    itself: dispatch `review-on-pr` for this PR at its current head
    (`workflow_dispatch` with the PR number, alongside the `pull_request`
    trigger), through the fix stage's wrapper like every other write. Dispatch
    it `--ref` the default branch, so the re-review runs the trusted copy of
    the workflow (rule 6), not a copy the PR could have edited. The
    re-review reads the push-back comment as part of the PR's text — as data —
    and either drops the finding with a stated reason or repeats it. This is a
    third deliberately-opened bot edge on top of the two the spec's R5 names,
    so `review-on-pr`'s dispatch trigger gets its own actor gate: the app or
    the operator, nobody else.
  - **mixed round** (some findings fixed, some pushed back) → code is pushed,
    so synchronize already covers it. Do not dispatch as well, or the same head
    gets reviewed twice.
  The round label was already bumped before the round ran, so a repeat
  disagreement walks to `round-3`, gets `needs-human`, and lands on the
  operator — which is what `REVIEW.md` ("When we disagree") says should happen
  to an argument neither side drops.
- **Wait for the stamped marker, not a fixed delay.** A settle window is a
  heuristic: a slow review wakes the fix job early, and a late comment can
  start a duplicate pass. Poll for a stamped marker naming the expected head,
  up to a bounded timeout, then escalate rather than guess.
- **Bump the round label BEFORE acting**, so a crash can only overcount. The
  whole order in `fix-on-review` is: read the marker → stop unless it says
  `verdict: findings` on the PR's current head → bump the label → then act. The
  fence comes before the bump; the bump comes before any write.

- Four workflows: `spec-on-intent`, `implement-on-spec`, `review-on-pr`,
  `fix-on-review`. Every job: one agent at a time, hard time and turn limits,
  loud failure if its PR didn't get created.
- Three skills: `implement`, `review-pr`, `address-review`. Rules baked in:
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
- PR B: **the lane cannot review its own PR** — a `pull_request` workflow only
  fires when its file is already on the default branch, so `review-on-pr`
  does not exist for the PR that introduces it. Prove it with the harness that
  exists today: the Codex cloud review on the PR, plus the operator's read of
  the workflows against the spec's safety list (R5). The lane's first real
  review is the PR after this one — and the smoke test below is what proves
  it fires at all.
- Phase exit: the smoke intent goes through end to end, you only merge.
