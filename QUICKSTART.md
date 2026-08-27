# QUICKSTART — stand up your own ystack in ~10 minutes

The friendly golden path for a **new adopter**: clone this repo, install the `/yshifu`
command, point it at a target repo, and watch one loop run. For the mental model read
[`README.md`](README.md); for the conventions and safety rails read [`AGENTS.md`](AGENTS.md).

> This is the happy path only. The scripts are the source of truth for the exact
> commands — when in doubt, run them and read their output. For depth, edge cases, and
> the disaster-recovery framing (rebuilding an *existing* team), see
> [`RESTORE.md`](RESTORE.md); this guide does not duplicate its runbook.

## Prerequisites

- **`gh` CLI authenticated** — `gh auth status` shows you logged in.
- **`jq` on `PATH`** — needed by the review/debate gates to validate Codex's typed JSONL events,
  and by `scripts/merge-pr.sh` to parse `gh`'s CI-check JSON.
- **Codex (OpenAI) CLI signed in** — a ChatGPT plan that includes Codex review is enough
  for personal repos; the CLI must be installed and signed in. This is the cross-vendor reviewer.
- **Claude Code installed** — the whole team runs in-session (no API key); yshifu and the
  coder it spawns are an ordinary Claude Code chat.
- **A target repo with CI that runs on PRs** — CI is the **hard merge gate**, so it must run
  the repo's real tests / lint / build on pull requests; otherwise the gate is hollow. **If
  your repo has no CI, ystack can bootstrap PR CI for you** — yshifu offers to scaffold a
  `pull_request` workflow from your toolchain as the *first* change, and **you approve and
  merge that initial gate by hand** (a self-authored gate can't certify itself). Or wire CI
  yourself before pointing ystack at the repo — see the CI contract in
  [`templates/repo-setup.md`](templates/repo-setup.md). Either way CI-on-PRs stays the hard
  gate; only *who sets it up* is up to you. A target `CLAUDE.md` is **not** required — the
  coder auto-discovers the install / lint / build / test commands from the repo's CI workflows
  and standard manifests. The team works in *target* repos, not in this control-plane repo.

## Steps

1. **Clone ystack** and enter it (substitute your own path; `<ystack>` below is wherever
   this clone lives):

   ```sh
   mkdir -p "$HOME/git"
   git clone <your-ystack-remote> "$HOME/git/ystack" && cd "$HOME/git/ystack"
   ```

2. **Install the `/yshifu` command:**

   ```sh
   scripts/install.sh
   ```

   Writes `~/.claude/commands/yshifu.md` with a path derived from this clone (no
   hardcoded location). It also writes a bridge copy under the legacy `/faber` name,
   so the old command keeps working until that bridge is retired.
   Idempotent — re-running is safe. The script prints the next steps.

3. **Make sure the target repo has CI that runs on PRs** (the hard merge gate). This is the
   one real precondition — but **you no longer have to wire it yourself**: if the repo has no
   PR CI, **yshifu offers to bootstrap it for you** at first contact (it scaffolds a
   `pull_request` workflow from your toolchain as the first "add PR CI" issue, and **you
   approve + merge that initial gate by hand** — yshifu classifies it as human-merge-only and
   won't run `merge-pr.sh` on it, since a self-authored gate can't certify itself). Wire it
   yourself instead if you prefer. Everything else (the
   loop labels, the readiness pre-flight) **yshifu bootstraps for you on first use** — see step 7.
   A target `CLAUDE.md` is **optional**: the coder auto-discovers the install / lint / build /
   test commands from the repo's CI workflows and standard manifests (see the discovery order
   in [`routines/coder.md`](routines/coder.md)). A filled-in `CLAUDE.md` "Stack & commands"
   from [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md) is an **optional override** —
   add one only to pin or disambiguate a non-standard toolchain. Branch protection on `main`
   is a UI step (see [`templates/repo-setup.md`](templates/repo-setup.md)); if you can't
   enable it, CI is still the hard gate.

   > **Optional / advanced pre-flight.** yshifu creates the loop labels and runs the readiness
   > self-check itself on first use, so you don't have to. If you *want* to bootstrap or verify
   > by hand first, run (both idempotent + read-only-safe):
   >
   > ```sh
   > "<ystack>/scripts/setup-target-repo.sh" <owner>/<repo>   # create/reconcile loop labels
   > "<ystack>/scripts/doctor.sh" <owner>/<repo>              # read-only readiness self-check
   > ```
   >
   > `doctor.sh` verifies `/yshifu` points at this clone, `gh` is authenticated, the Claude Code
   > and Codex CLIs and `jq` are on `PATH`, every restore-critical file is present, and the
   > target repo's loop labels exist — one pass/warn/fail line per check, non-zero exit only on a
   > hard fail. Mutates nothing.

4. **Set your own north star** — in the **target repo**, at `.ystack/north-star.md`. Your
   north star is committed in and owned by *your* repo, not the ystack control-plane clone.
   Once you've cloned the target (next step), copy `templates/.ystack/north-star.md` from
   your ystack clone into it as `.ystack/north-star.md`, replace the placeholder with *your*
   direction, remove the `<!-- ystack-shipped-default -->` marker, and **commit** it — the
   proactive manager-debate reads the *committed* file, and a missing / still-placeholder /
   no-active-entry star FAILs the gate. Setup does **not** auto-seed this file;
   `setup-target-repo.sh` only creates the loop labels. (Creating + committing the file is the
   pre-flight step; *approving* it happens with yshifu in step 6, once a session exists to
   receive that approval. When the target is the ystack control-plane repo itself, its north
   star is the root `NORTH_STAR.md` — ystack is its own target.)

5. **Clone the target repo and `cd` into it.** `/yshifu` and every orchestration script
   (`codex-review.sh`, `merge-pr.sh`, `manager-review.sh`) run from **inside the target
   repo's local clone** — they read its git remote and resolve the repo via `gh` (e.g.
   `codex-review.sh` calls `gh repo view`) — so you need a working copy on disk, and `gh`
   must resolve to **the repo PRs target**.

   **Recommended (simplest):** a **direct, non-fork clone of the canonical repo**, so
   `origin` *is* the repo PRs target and `gh` resolves correctly with no extra config:

   ```sh
   git clone <canonical-repo> "$HOME/git/<repo>" && cd "$HOME/git/<repo>"
   # or: gh repo clone <owner>/<repo> "$HOME/git/<repo>" && cd "$HOME/git/<repo>"
   ```

   **Fork-clone alternative:** if you must work from a fork, `origin` points at the fork, so
   you have to point both git *and* `gh` at the canonical repo (the repo PRs target):

   ```sh
   git remote add upstream <canonical-repo>      # add the canonical repo as a remote
   gh repo set-default <owner>/<repo>            # the repo PRs target
   ```

   `gh repo set-default` is **required**: adding the remote alone does not change which repo
   `gh` resolves to, so `gh repo view` / `gh pr view` and the orchestration scripts could
   otherwise target the fork (or prompt non-interactively) and you'd review/merge against the
   wrong repo. Everything below runs from this clone.

6. **Open Claude Code in the target repo and run `/yshifu`** to summon the manager. On its
   **first loop action this session, yshifu auto-bootstraps the repo**: it derives
   `<owner>/<repo>` from the cwd, creates/reconciles the loop labels, and runs the read-only
   readiness self-check — so you don't hand-run `setup-target-repo.sh` / `doctor.sh`. If that
   self-check hits a hard failure (e.g. `gh` not authed), yshifu surfaces the fix and holds off
   starting the loop; a warning (e.g. no PR CI detected) is relayed as advisory. Then, in
   that session, **approve your north star** (this unlocks proactive autonomous mode) —
   explicitly tell yshifu you approve the direction you set in step 4. **Your explicit approval
   of the active north star is the root authorization for all proactive work** (the front gate
   sits at this altitude); yshifu gates on that approval, not on any line written in the file.
   Until you set + approve your own, yshifu will only act on issues you ask for directly and
   will ask you to set + approve the north star before pursuing anything proactively.

7. **Give yshifu a one-liner** — describe the change you want. yshifu drafts a spec and
   opens a GitHub issue. You talk only to yshifu.

8. **Approve the drafted spec.** For a user-directed issue, the front gate is *your* approval
   of the spec yshifu drafted in step 7 — your one-liner was the request; this is the go.
   yshifu records that approval by applying the `ready` label (it never self-approves), which
   is its cue to spawn the coder. (For proactive issues yshifu raises toward your approved north
   star, the gate is yshifu⇄Codex consensus instead — no per-issue ask — which is exactly why
   approving the north star in step 6 matters.)

9. **Watch one loop:** yshifu spawns the coder subagent → coder opens a PR (`round-0`) →
   yshifu runs `"<ystack>/scripts/codex-review.sh" <PR#>` from inside the target repo's
   clone — by absolute path, since the harness lives only in the ystack clone, not the
   target repo → Codex posts review comments only. Fixes bump `round-N`; the cap (~3) or
   an ambiguous spec escalates with `needs-human`. After a clean review yshifu labels the
   PR `merge-ready`; for a clean, low-risk PR yshifu **merges** it once CI is green, under
   your standing authorization (acting on the passed review — not self-approval; Codex is
   comments-only). A PR needing human review (safety-rail / north-star / high-risk) is
   brought to **you** to merge instead.

That's the loop. To prove a rebuilt or relocated setup end to end — or recover a lost one
— follow the smoke test and runbook in [`RESTORE.md`](RESTORE.md).

## Starting from an empty folder (greenfield 0→1)

The steps above adopt an **existing** repo. ystack can also start a project from
**nothing** — an empty folder or a repo with no source yet. The path mirrors the loop, but
the **first change is a human-gated bootstrap** because at 0→1 there is no CI and no merge
gate yet (yshifu won't run autonomously until a real gate exists):

1. **Open Claude Code in the empty folder and run `/yshifu`.** yshifu detects the target is
   greenfield (empty / no source) and does **not** try to run the existing-project setup
   (which would hard-fail on an empty target).
2. **State your goal.** On a greenfield target your opening command *becomes* the stated
   first north star — yshifu records it as the direction. It is **not** the go on its own
   (the one-liner is the request, not the go).
3. **Base-branch prerequisite (if the repo is truly empty).** A brand-new GitHub repo with
   no commits has no default branch, so a PR can't be opened against it yet. yshifu
   **surfaces** this: you create/connect the repo and land the first commit (an
   outward-facing action yshifu won't do silently). If you already have a folder with a base
   branch, skip this.
4. **Approve the concrete bootstrap plan.** yshifu proposes the initial scaffold — a runnable
   **skeleton + manifest + first test + a `pull_request` CI workflow + a committed
   `.ystack/north-star.md`** — and you approve that plan. That approval is the go for the
   bootstrap. Part of the plan is the **exact north-star text + done-signal yshifu drafts from
   your opening command** (command-as-first-north-star): the bootstrap coder commits *that* text
   into the target's `.ystack/north-star.md` — yshifu doesn't invent your goal.
5. **yshifu scaffolds it.** Once the repo + base branch exist, yshifu first bootstraps the loop
   labels and runs its read-only **readiness self-check** (`doctor.sh`) — surfacing any hard
   failure like `gh`/Codex CLI not signed in **before** it spawns anything (the bootstrap PR
   still gets a Codex review, so that prerequisite matters up front); the expected no-CI /
   no-`CLAUDE.md` — **and no-north-star** — results here are just advisory warnings (the bootstrap
   PR is what creates the committed `.ystack/north-star.md`, so a north-star WARN *before* it
   lands is advisory in greenfield, like the missing-PR-CI WARN). Then yshifu spawns the coder
   under its narrow **greenfield-bootstrap exception** to create the skeleton, manifest, first
   test, PR CI, **and a committed `.ystack/north-star.md`** (an active non-placeholder entry
   carrying your goal + done-signal, no `ystack-shipped-default` marker) **together** in one
   sole-purpose PR (the coder is normally blocked with no commands to discover and no PR CI —
   this exception exists precisely to establish both). Cross-vendor Codex review still runs. This
   leaves the 0→1 target with the committed north star the shipped gate (`manager-review.sh`)
   requires.
6. **You approve and merge the bootstrap PR by hand.** No real gate exists yet for it to
   certify itself, so yshifu classifies it **human-merge-only** and does **not** auto-merge
   it — you merge that initial gate yourself (same as the add-PR-CI bootstrap above).
7. **Handoff to the 1→N loop — the front gate still holds.** Once the skeleton + CI + first
   test land, a **real gate now exists** and yshifu transitions to the normal loop under the
   standing rails (including auto-merge for clean, low-risk PRs). But the handoff does **not**
   by itself unlock open-ended proactive autonomy: you approved the **bootstrap scaffold plan
   (scoped to the 0→1 PR)**, which is **NOT** approval of the active north star for proactive
   1→N work. So after the bootstrap lands, yshifu pursues **proactive** north-star work **only
   if you have explicitly approved the active north star** for autonomy; **otherwise it stays
   user-directed** — it asks you for the next direction, or to explicitly approve the north
   star, before any proactive follow-up. Your greenfield opening command is the **stated**
   north star (it set the *direction*), **not** the proactive-autonomy go —
   bootstrap-plan approval ≠ north-star approval.
