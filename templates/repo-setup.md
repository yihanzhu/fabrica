# Target repo setup checklist

Do this once per target repo before pointing the team at it.

## 1. Labels
Create these labels (the loop uses them as its state — each coder spawn is stateless):
- `debating` — issue under manager-debate (Faber + Codex); not yet approved
- `ready` — cleared to run (your direct approval OR Faber⇄Codex consensus toward an approved north star); Faber's cue to spawn the coder
- `round-0`, `round-1`, `round-2`, `round-3` — review-loop counter
- `needs-human` — escalation: round cap hit, ambiguous spec, oversized PR, or failure
- `merge-ready` — current head passed Codex review; auto-merged in-session if low-risk, else awaiting your merge

```bash
scripts/setup-target-repo.sh <owner>/<repo>
```

This is idempotent — safe to re-run. It only does the labels; the steps below are
manual (the script prints these reminders too).

The script is the **canonical source of truth** for these labels: a normal run
force-edits each existing label to the script's definitions, so re-running reconciles
any drift live labels have picked up. To check for drift **without** mutating anything,
run the read-only dry mode:

```bash
scripts/setup-target-repo.sh --check <owner>/<repo>
```

It reports per label `matches` / `differs` (which of name/color/description) / `missing`,
and exits non-zero if anything is missing or differs (zero if all match).

## 2. Branch protection (main)
The supported protection shape is **required status checks** — that is the gate
`scripts/merge-pr.sh` reads and enforces.
- ✅ Require status checks to pass before merging (your CI) — the **hard gate**. Mark your
  CI contexts (lint/test/build) as **required**; `merge-pr.sh` discovers the required checks
  from the PR's own status-check rollup (`gh pr checks --required`, readable by anyone who can
  view the PR — **no branch-protection / admin read access needed**, so a non-admin maintainer
  who can merge is supported), gates on exactly those required checks, and treats any
  non-required check (preview deploys, coverage bots) as informational, so a pending/failing
  optional check won't stall a mergeable PR. If you leave the base unprotected (or define no
  required checks), the script falls back to requiring ≥1 passing check with none failing/pending.
- ✅ Require branches to be up to date before merging
- ⛔️ **Do NOT use "Require a pull request before merging → require approving review."**
  Fabrica's reviewer (`scripts/codex-review.sh`) is **comments-only and never approves**, so a
  required approving review can never be satisfied by the loop — `merge-pr.sh` detects this
  (`reviewDecision=REVIEW_REQUIRED`) and refuses, handing the PR to the human merge gate.
  Gate on required **status checks**, not on a required approving review.
- ⛔️ **Keep GitHub's native auto-merge button off** — merges run through Faber or the
  human (both gated on green CI), not a server-side auto-merge trigger. Faber merging a
  clean, low-risk PR is a deliberate `gh pr merge`, not this checkbox.

**Merged-branch cleanup.** `merge-pr.sh` does not delete the head branch. Either enable the
repo's **"Automatically delete head branches"** setting, or run `gh pr merge … --delete-branch`
manually, so merged feature branches don't accumulate.

## 3. CI — the loop's hard gate
CI must run this repo's **real lint / typecheck / build / test** on every PR — it is the
**hard merge gate**, and the green check only means something if CI exercises the change.
The coder **auto-discovers** the commands to run locally from the repo's CI configuration
(whatever the provider) plus standard manifests, and matches CI so local-green and the PR's
own CI agree. You do **not** need a filled-in `CLAUDE.md` for this — a target `CLAUDE.md`
"Stack & commands" is an **optional override** (see step 4) to pin or disambiguate a
non-standard toolchain.

**If this repo has no CI, add repo-specific CI first** — it's the loop's hard gate, and the
team won't merge against a missing or hollow check. There is no blessed drop-in workflow:
CI is project-specific, so you wire it to *your* commands.

Illustrative only (not a drop-in — swap in your repo's real commands and runtime):

```yaml
# on: [pull_request]  — run your repo's real lint / test / build
- run: npm ci
- run: npm test
- run: npm run lint
```

## 4. Conventions
- `CLAUDE.md` is **optional**. The coder auto-discovers the lint/build/test commands from
  CI + manifests (step 3), so you don't need one to run the loop. Add one (from
  `templates/target-CLAUDE.md`), with a filled-in "Stack & commands" section, only to
  **override** discovery — to pin or disambiguate a non-standard toolchain.

## 5. Connect the in-session team
The team runs from a Claude Code session — there are no per-repo routine triggers to wire.
- Install the **`/faber`** command: run `scripts/install.sh` (no args) from your fabrica
  clone. Faber then orchestrates the loop here, spawning Claude coder subagents.
- Connect the **Codex CLI** (installed + signed in) so Faber can run
  `scripts/codex-review.sh <PR#>` against this repo's PRs — the cross-vendor, comments-only
  reviewer.

## 6. Set + approve your own north star (unlocks proactive autonomous mode)
Edit `NORTH_STAR.md` in your **fabrica control-plane clone** (not this target repo) to *your*
direction and explicitly approve it to Faber. **Your explicit approval of the active north
star is the root authorization for all proactive work** — and Faber gates on that approval,
not on any line written in the file. The shipped approval note is the prior owner's history,
**not** a token that approves the goal for you: a fresh clone inheriting it is not auto-approved.
Until you set + approve your own, Faber acts only on issues you ask for directly and will ask
you to set + approve the north star before pursuing anything proactively. The shipped entry is
*Fabrica's own* goal, so an adopter must replace + approve it before proactive consensus-gated
work runs in their setup.
