# Target repo setup checklist

The **one real precondition** is CI that runs on PRs (§3) — that's the hard merge gate.
**Everything else yshifu bootstraps for you on first use:** the first time you run `/yshifu`
in a target repo this session, yshifu derives the repo, creates/reconciles the loop labels,
and runs the readiness self-check — before its first loop action. So adoption collapses to
`cd repo → /yshifu → go`. And if the repo has **no PR CI yet, yshifu can bootstrap that gate
too** (§3) — you approve and merge the initial gate by hand — so you don't have to wire it
yourself first. The steps below document what that bootstrap does (and how to run it by hand
as an optional pre-flight); you don't have to run them yourself.

## 1. Labels (yshifu creates these on first use)
The loop uses these labels as its state (each coder spawn is stateless):
- `debating` — issue under manager-debate (yshifu + Codex); not yet approved
- `ready` — cleared and unclaimed; yshifu must take a verified claim before coder spawn
- `claimed` — active/unresolved pickup; crash guard under the hard one-manager-session invariant, not a cross-manager lock
- `round-0`, `round-1`, `round-2`, `round-3` — review-loop counter
- `needs-human` — resumable pause: plan refresh, round cap, ambiguous spec, size, or failure
- `merge-ready` — exact current head and base passed Codex review; the PR waits on **your** merge (yshifu never merges, and either moving voids the label)

**yshifu creates/reconciles these automatically** on its first-loop-action bootstrap, so you
normally don't touch this. If you want to bootstrap or reconcile the labels by hand
(optional/advanced), run the setup script — it's idempotent, safe to re-run:

```bash
scripts/setup-target-repo.sh <owner>/<repo>
```

The script is the **canonical source of truth** for these labels: a normal run
force-edits each existing label to the script's definitions, so re-running (whether by you
or by yshifu's bootstrap) reconciles any drift live labels have picked up. To check for drift
**without** mutating anything, run the read-only dry mode (this is what yshifu runs first to
decide whether a reconcile is needed):

```bash
scripts/setup-target-repo.sh --check <owner>/<repo>
```

It reports per label `matches` / `differs` (which of name/color/description) / `missing`,
and exits non-zero if anything is missing or differs (zero if all match).

## 2. Branch protection (main)
The supported protection shape is **required status checks** — that is the gate
`scripts/merge-pr.sh` reads and enforces when **you** run it. (No agent merges here:
yshifu labels a reviewed-clean head/base `merge-ready` and hands you the PR; `merge-pr.sh` is
yours, and yshifu never runs it.)
- ✅ Require status checks to pass before merging (your CI) — the **hard gate**. Mark your
  CI contexts (lint/test/build) as **required**; `merge-pr.sh` discovers the required checks
  from the PR's own status-check rollup (`gh pr checks --required`, readable by anyone who can
  view the PR — **no branch-protection / admin read access needed**, so a non-admin maintainer
  who can merge is supported), gates on exactly those required checks, and treats any
  non-required check (preview deploys, coverage bots) as informational, so a pending/failing
  optional check won't stall a mergeable PR. If you leave the base unprotected (or define no
  required checks), the script falls back to requiring ≥1 passing check with none failing/pending.
- ✅ Require branches to be up to date before merging
- ⚠️ **"Require a pull request before merging → require approving review" is your call, but
  know the trade.** ystack's reviewer (`scripts/codex-review.sh`) is **comments-only and never
  approves**, so no agent can ever satisfy that requirement — and `merge-pr.sh` refuses such a
  PR outright (`reviewDecision=REVIEW_REQUIRED`), so you merge those **by hand** instead of
  with the script. Gate on required **status checks** if you want `merge-pr.sh` usable.
- ⛔️ **Keep GitHub's native auto-merge button off** — merges run through **you**, gated on
  green CI and a `merge-ready` label, not a server-side trigger that lands a PR while nobody
  is looking.

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

**If this repo has no CI, you have two options** — it's the loop's hard gate, and no PR gets
handed to you as reviewed-and-green against a missing or hollow check:
- **Let ystack bootstrap it (you approve the initial gate).** At first contact yshifu confirms
  CI is genuinely absent (inspecting the CI/provider config, not just `doctor.sh`'s WARN — that
  warns for a repo with no PRs yet even when a workflow exists), then offers to scaffold a
  `pull_request` workflow from your auto-discovered toolchain as the **first "add PR CI"
  issue**. Because a self-authored gate can't certify itself, that PR is **operator-approved
  and merged by you** — yshifu classifies it as human-merge-only and does **not** even apply
  `merge-ready` to it (a same-repo bootstrap workflow can self-report green on its own PR, so
  the human — not a check — is the gate), so **you merge it by hand**; this is the one
  sanctioned merge-without-a-pre-existing-gate case, precisely because it *creates* the gate. yshifu tells you **what the bootstrapped gate
  covers** (tests if present; otherwise lint / build only) so a weak gate isn't mistaken for a
  strong one.
- **Or wire it yourself.** There is no blessed drop-in workflow: CI is project-specific, so you
  wire it to *your* commands.

Either way CI-on-PRs stays the hard merge gate — only *who sets it up* changes.

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
- Install the **`/yshifu`** command: run `scripts/install.sh` (no args) from your ystack
  clone. yshifu then orchestrates the loop here, spawning Claude coder subagents.
- Connect the **Codex CLI** (installed + signed in) so yshifu can run
  `scripts/codex-review.sh <PR#>` against this repo's PRs — the cross-vendor, comments-only
  reviewer.

## 6. Set + approve your own north star (unlocks proactive autonomous mode)
Your north star lives in **this target repo**, at `.ystack/north-star.md` (committed, owned by
your repo — not the ystack control-plane clone). Setup does **not** auto-seed it; you create it:
copy `templates/.ystack/north-star.md` from your ystack clone into this repo as
`.ystack/north-star.md`, replace the placeholder with *your* direction, remove the
`<!-- ystack-shipped-default -->` marker, then **commit** it. `scripts/setup-target-repo.sh`
only creates the loop labels — it does not create this file. Then explicitly approve the active
north star to yshifu. **Your explicit approval of the active north star is the root authorization
for all proactive work** — and yshifu gates on that approval, not on any line written in the file.
The shipped approval note is the prior owner's history, **not** a token that approves the goal for
you: a fresh copy inheriting it is not auto-approved. Until you set + commit + approve your own,
yshifu acts only on issues you ask for directly and will ask you to set + approve the north star
before pursuing anything proactively. The proactive manager-debate (`scripts/manager-review.sh`)
reads the **committed** `.ystack/north-star.md`; a missing, still-placeholder, or no-active-entry
star FAILs the gate — so commit your north star after you write it. (When the target is the
ystack control-plane repo itself, its north star is the root `NORTH_STAR.md` — ystack is its
own target.)

## 7. Model tiering override (optional)
ystack ships model-tiering defaults at `config/models.conf` in the ystack clone (see
README.md's "Model policy" section). If this target repo wants different values (e.g. a
different coder ceiling), copy `templates/.ystack/models.conf` from your ystack clone into
this repo as `.ystack/models.conf` — same format/keys as the shipped defaults, applied
**after** them — set only the keys you want to change, and commit it. This is optional: skip
it entirely to inherit the shipped defaults. `scripts/doctor.sh` validates the shipped
defaults (checks (k) and (l)). The review/manager-debate gates (`scripts/codex-review.sh` /
`scripts/manager-review.sh`) already read this per-target override — but **only the
producer/model keys** (`YSTACK_CODER_MODEL`, `YSTACK_HANDS_MODEL`, `YSTACK_CODEX_MODEL`):
`YSTACK_REVIEW_EFFORT` / `YSTACK_DEBATE_EFFORT` can never be set this way (a target can
never lower or change its own gate — an attempt is ignored with a visible warning in the
posted PR/issue comment). The manager reads the same override before every coder/hands
spawn.
