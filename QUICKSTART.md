# QUICKSTART — stand up your own fabrica in ~10 minutes

The friendly golden path for a **new adopter**: clone this repo, install the `/faber`
command, point it at a target repo, and watch one loop run. For the mental model read
[`README.md`](README.md); for the conventions and safety rails read [`CLAUDE.md`](CLAUDE.md).

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
- **Claude Code installed** — the whole team runs in-session (no API key); Faber and the
  coder it spawns are an ordinary Claude Code chat.
- **A target repo with CI that runs on PRs** — CI is the **hard merge gate**, so it must run
  the repo's real tests / lint / build on pull requests; otherwise the gate is hollow. **If
  your repo has no CI, Fabrica can bootstrap PR CI for you** — Faber offers to scaffold a
  `pull_request` workflow from your toolchain as the *first* change, and **you approve and
  merge that initial gate by hand** (a self-authored gate can't certify itself). Or wire CI
  yourself before pointing Fabrica at the repo — see the CI contract in
  [`templates/repo-setup.md`](templates/repo-setup.md). Either way CI-on-PRs stays the hard
  gate; only *who sets it up* is up to you. A target `CLAUDE.md` is **not** required — the
  coder auto-discovers the install / lint / build / test commands from the repo's CI workflows
  and standard manifests. The team works in *target* repos, not in this control-plane repo.

## Steps

1. **Clone fabrica** and enter it (substitute your own path; `<fabrica>` below is wherever
   this clone lives):

   ```sh
   mkdir -p "$HOME/git"
   git clone <your-fabrica-remote> "$HOME/git/fabrica" && cd "$HOME/git/fabrica"
   ```

2. **Install the `/faber` command:**

   ```sh
   scripts/install.sh
   ```

   Writes `~/.claude/commands/faber.md` with a path derived from this clone (no
   hardcoded location). Idempotent — re-running is safe. The script prints the next steps.

3. **Make sure the target repo has CI that runs on PRs** (the hard merge gate). This is the
   one real precondition — but **you no longer have to wire it yourself**: if the repo has no
   PR CI, **Faber offers to bootstrap it for you** at first contact (it scaffolds a
   `pull_request` workflow from your toolchain as the first "add PR CI" issue, and **you
   approve + merge that initial gate by hand** — Faber classifies it as human-merge-only and
   won't run `merge-pr.sh` on it, since a self-authored gate can't certify itself). Wire it
   yourself instead if you prefer. Everything else (the
   loop labels, the readiness pre-flight) **Faber bootstraps for you on first use** — see step 7.
   A target `CLAUDE.md` is **optional**: the coder auto-discovers the install / lint / build /
   test commands from the repo's CI workflows and standard manifests (see the discovery order
   in [`routines/coder.md`](routines/coder.md)). A filled-in `CLAUDE.md` "Stack & commands"
   from [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md) is an **optional override** —
   add one only to pin or disambiguate a non-standard toolchain. Branch protection on `main`
   is a UI step (see [`templates/repo-setup.md`](templates/repo-setup.md)); if you can't
   enable it, CI is still the hard gate.

   > **Optional / advanced pre-flight.** Faber creates the loop labels and runs the readiness
   > self-check itself on first use, so you don't have to. If you *want* to bootstrap or verify
   > by hand first, run (both idempotent + read-only-safe):
   >
   > ```sh
   > "<fabrica>/scripts/setup-target-repo.sh" <owner>/<repo>   # create/reconcile loop labels
   > "<fabrica>/scripts/doctor.sh" <owner>/<repo>              # read-only readiness self-check
   > ```
   >
   > `doctor.sh` verifies `/faber` points at this clone, `gh` is authenticated, the Claude Code
   > and Codex CLIs and `jq` are on `PATH`, every restore-critical file is present, and the
   > target repo's loop labels exist — one pass/warn/fail line per check, non-zero exit only on a
   > hard fail. Mutates nothing.

4. **Set your own north star** — in the **target repo**, at `.fabrica/north-star.md`. Your
   north star is committed in and owned by *your* repo, not the fabrica control-plane clone.
   Once you've cloned the target (next step), copy `templates/.ystack/north-star.md` from
   your fabrica clone into it as `.fabrica/north-star.md`, replace the placeholder with *your*
   direction, remove the `<!-- fabrica-shipped-default -->` marker, and **commit** it — the
   proactive manager-debate reads the *committed* file, and a missing / still-placeholder /
   no-active-entry star FAILs the gate. Setup does **not** auto-seed this file;
   `setup-target-repo.sh` only creates the loop labels. (Creating + committing the file is the
   pre-flight step; *approving* it happens with Faber in step 6, once a session exists to
   receive that approval. When the target is the Fabrica control-plane repo itself, its north
   star is the root `NORTH_STAR.md` — Fabrica is its own target.)

5. **Clone the target repo and `cd` into it.** `/faber` and every orchestration script
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

6. **Open Claude Code in the target repo and run `/faber`** to summon the manager. On its
   **first loop action this session, Faber auto-bootstraps the repo**: it derives
   `<owner>/<repo>` from the cwd, creates/reconciles the loop labels, and runs the read-only
   readiness self-check — so you don't hand-run `setup-target-repo.sh` / `doctor.sh`. If that
   self-check hits a hard failure (e.g. `gh` not authed), Faber surfaces the fix and holds off
   starting the loop; a warning (e.g. no PR CI detected) is relayed as advisory. Then, in
   that session, **approve your north star** (this unlocks proactive autonomous mode) —
   explicitly tell Faber you approve the direction you set in step 4. **Your explicit approval
   of the active north star is the root authorization for all proactive work** (the front gate
   sits at this altitude); Faber gates on that approval, not on any line written in the file.
   Until you set + approve your own, Faber will only act on issues you ask for directly and
   will ask you to set + approve the north star before pursuing anything proactively.

7. **Give Faber a one-liner** — describe the change you want. Faber drafts a spec and
   opens a GitHub issue. You talk only to Faber.

8. **Approve the drafted spec.** For a user-directed issue, the front gate is *your* approval
   of the spec Faber drafted in step 7 — your one-liner was the request; this is the go.
   Faber records that approval by applying the `ready` label (it never self-approves), which
   is its cue to spawn the coder. (For proactive issues Faber raises toward your approved north
   star, the gate is Faber⇄Codex consensus instead — no per-issue ask — which is exactly why
   approving the north star in step 6 matters.)

9. **Watch one loop:** Faber spawns the coder subagent → coder opens a PR (`round-0`) →
   Faber runs `"<fabrica>/scripts/codex-review.sh" <PR#>` from inside the target repo's
   clone — by absolute path, since the harness lives only in the fabrica clone, not the
   target repo → Codex posts review comments only. Fixes bump `round-N`; the cap (~3) or
   an ambiguous spec escalates with `needs-human`. After a clean review Faber labels the
   PR `merge-ready`; for a clean, low-risk PR Faber **merges** it once CI is green, under
   your standing authorization (acting on the passed review — not self-approval; Codex is
   comments-only). A PR needing human review (safety-rail / north-star / high-risk) is
   brought to **you** to merge instead.

That's the loop. To prove a rebuilt or relocated setup end to end — or recover a lost one
— follow the smoke test and runbook in [`RESTORE.md`](RESTORE.md).

## Starting from an empty folder (greenfield 0→1)

The steps above adopt an **existing** repo. Fabrica can also start a project from
**nothing** — an empty folder or a repo with no source yet. The path mirrors the loop, but
the **first change is a human-gated bootstrap** because at 0→1 there is no CI and no merge
gate yet (Faber won't run autonomously until a real gate exists):

1. **Open Claude Code in the empty folder and run `/faber`.** Faber detects the target is
   greenfield (empty / no source) and does **not** try to run the existing-project setup
   (which would hard-fail on an empty target).
2. **State your goal.** On a greenfield target your opening command *becomes* the stated
   first north star — Faber records it as the direction. It is **not** the go on its own
   (the one-liner is the request, not the go).
3. **Base-branch prerequisite (if the repo is truly empty).** A brand-new GitHub repo with
   no commits has no default branch, so a PR can't be opened against it yet. Faber
   **surfaces** this: you create/connect the repo and land the first commit (an
   outward-facing action Faber won't do silently). If you already have a folder with a base
   branch, skip this.
4. **Approve the concrete bootstrap plan.** Faber proposes the initial scaffold — a runnable
   **skeleton + manifest + first test + a `pull_request` CI workflow + a committed
   `.fabrica/north-star.md`** — and you approve that plan. That approval is the go for the
   bootstrap. Part of the plan is the **exact north-star text + done-signal Faber drafts from
   your opening command** (command-as-first-north-star): the bootstrap coder commits *that* text
   into the target's `.fabrica/north-star.md` — Faber doesn't invent your goal.
5. **Faber scaffolds it.** Once the repo + base branch exist, Faber first bootstraps the loop
   labels and runs its read-only **readiness self-check** (`doctor.sh`) — surfacing any hard
   failure like `gh`/Codex CLI not signed in **before** it spawns anything (the bootstrap PR
   still gets a Codex review, so that prerequisite matters up front); the expected no-CI /
   no-`CLAUDE.md` — **and no-north-star** — results here are just advisory warnings (the bootstrap
   PR is what creates the committed `.fabrica/north-star.md`, so a north-star WARN *before* it
   lands is advisory in greenfield, like the missing-PR-CI WARN). Then Faber spawns the coder
   under its narrow **greenfield-bootstrap exception** to create the skeleton, manifest, first
   test, PR CI, **and a committed `.fabrica/north-star.md`** (an active non-placeholder entry
   carrying your goal + done-signal, no `fabrica-shipped-default` marker) **together** in one
   sole-purpose PR (the coder is normally blocked with no commands to discover and no PR CI —
   this exception exists precisely to establish both). Cross-vendor Codex review still runs. This
   leaves the 0→1 target with the committed north star the shipped gate (`manager-review.sh`)
   requires.
6. **You approve and merge the bootstrap PR by hand.** No real gate exists yet for it to
   certify itself, so Faber classifies it **human-merge-only** and does **not** auto-merge
   it — you merge that initial gate yourself (same as the add-PR-CI bootstrap above).
7. **Handoff to the 1→N loop — the front gate still holds.** Once the skeleton + CI + first
   test land, a **real gate now exists** and Faber transitions to the normal loop under the
   standing rails (including auto-merge for clean, low-risk PRs). But the handoff does **not**
   by itself unlock open-ended proactive autonomy: you approved the **bootstrap scaffold plan
   (scoped to the 0→1 PR)**, which is **NOT** approval of the active north star for proactive
   1→N work. So after the bootstrap lands, Faber pursues **proactive** north-star work **only
   if you have explicitly approved the active north star** for autonomy; **otherwise it stays
   user-directed** — it asks you for the next direction, or to explicitly approve the north
   star, before any proactive follow-up. Your greenfield opening command is the **stated**
   north star (it set the *direction*), **not** the proactive-autonomy go —
   bootstrap-plan approval ≠ north-star approval.
