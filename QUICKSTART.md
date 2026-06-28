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
- **`jq` on `PATH`** — needed by the merge helper (`scripts/merge-pr.sh`) to parse `gh`'s
  CI-check JSON. Without it setup passes but the merge step fails.
- **Codex (OpenAI) CLI signed in** — a ChatGPT plan that includes Codex review is enough
  for personal repos; the CLI must be installed and signed in. This is the cross-vendor reviewer.
- **Claude Code installed** — the whole team runs in-session (no API key); Faber and the
  coder it spawns are an ordinary Claude Code chat.
- **A target repo with CI** — CI is the **hard merge gate**, so it must run the **exact
  commands** you put in the target repo's `CLAUDE.md` (its tests / lint / build); otherwise
  the gate is hollow. **If your repo has no CI, add repo-specific CI first** — see the CI
  contract in [`templates/repo-setup.md`](templates/repo-setup.md). The team works in
  *target* repos, not in this control-plane repo.

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

3. **Bootstrap a target repo's loop labels** — run the setup script by absolute path from
   anywhere:

   ```sh
   "<fabrica>/scripts/setup-target-repo.sh" <owner>/<repo>
   ```

   Creates the `ready` / `round-0..3` / `needs-human` / `merge-ready` labels the loop uses
   as its state. Idempotent. It prints the manual follow-ups it can't script.

4. **Confirm the target repo has CI** (the hard merge gate) and drop a filled-in
   `CLAUDE.md` of conventions from [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md)
   into its root. For a **code repo this `CLAUDE.md` is a hard prerequisite** — its
   "Stack & commands" are the only authoritative source for the install / lint / build /
   test commands the coder runs, so without it the coder cannot verify its work (it is
   optional only for docs/trivial repos with no toolchain). Branch protection on `main` is
   a UI step (see [`templates/repo-setup.md`](templates/repo-setup.md)); if you can't enable
   it, CI is still the hard gate.

5. **Pre-flight check (optional but recommended)** — from your fabrica clone, run the
   read-only self-check to confirm the basics are in place before you summon Faber:

   ```sh
   scripts/doctor.sh <owner>/<repo>
   ```

   It verifies `/faber` points at this clone, `gh` is authenticated, the Claude Code and
   Codex CLIs and `jq` are on `PATH`, every restore-critical file is present, and the
   target repo's loop labels exist. One pass/fail line per check; non-zero exit if
   anything's off. Mutates nothing.

6. **Set your own north star.** Edit [`NORTH_STAR.md`](NORTH_STAR.md) to *your* direction —
   the shipped entry is *Fabrica's own* goal and its approval note is the prior owner's
   history, **not** a token that approves the goal for you. (Setting the file is the pre-flight
   step; *approving* it happens with Faber in the next step, once a session exists to receive
   that approval.)

7. **Clone the target repo and `cd` into it.** `/faber` and every orchestration script
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

8. **Open Claude Code in the target repo and run `/faber`** to summon the manager. Then, in
   that session, **approve your north star** (this unlocks proactive autonomous mode) —
   explicitly tell Faber you approve the direction you set in step 6. **Your explicit approval
   of the active north star is the root authorization for all proactive work** (the front gate
   sits at this altitude); Faber gates on that approval, not on any line written in the file.
   Until you set + approve your own, Faber will only act on issues you ask for directly and
   will ask you to set + approve the north star before pursuing anything proactively.

9. **Give Faber a one-liner** — describe the change you want. Faber drafts a spec and
   opens a GitHub issue. You talk only to Faber.

10. **Approve the drafted spec.** For a user-directed issue, the front gate is *your* approval
   of the spec Faber drafted in step 9 — your one-liner was the request; this is the go.
   Faber records that approval by applying the `ready` label (it never self-approves), which
   is its cue to spawn the coder. (For proactive issues Faber raises toward your approved north
   star, the gate is Faber⇄Codex consensus instead — no per-issue ask — which is exactly why
   approving the north star in step 8 matters.)

11. **Watch one loop:** Faber spawns the coder subagent → coder opens a PR (`round-0`) →
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
