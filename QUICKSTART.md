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
- **Codex (OpenAI) CLI signed in** — a ChatGPT plan that includes Codex review is enough
  for personal repos; the CLI must be installed and signed in. This is the cross-vendor reviewer.
- **Claude Code installed** — the whole team runs in-session (no API key); Faber and the
  coder it spawns are an ordinary Claude Code chat.
- **A target repo with CI** — CI is the **hard merge gate**. The team works in *target*
  repos, not in this control-plane repo.

## Steps

1. **Clone fabrica** and enter it (substitute your own path; `<fabrica>` below is wherever
   this clone lives):

   ```sh
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

   Creates the `ready` / `round-0..3` / `needs-human` labels the loop uses as its state.
   Idempotent. It prints the manual follow-ups it can't script.

4. **Confirm the target repo has CI** (the hard merge gate) and, optionally, drop a
   `CLAUDE.md` of conventions from [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md)
   into its root. Branch protection on `main` is a UI step (see
   [`templates/repo-setup.md`](templates/repo-setup.md)); if you can't enable it, CI is
   still the hard gate.

5. **Open Claude Code in the target repo and run `/faber`** to summon the manager.

6. **Give Faber a one-liner** — describe the change you want. Faber drafts a spec and
   opens a GitHub issue. You talk only to Faber.

7. **Approve the issue.** Front gate = *your* approval. Faber records it by applying the
   `ready` label (it never self-approves), which is its cue to spawn the coder.

8. **Watch one loop:** Faber spawns the coder subagent → coder opens a PR (`round-0`) →
   Faber runs `scripts/codex-review.sh <PR#>` (from inside the target repo's clone) →
   Codex posts review comments only. Fixes bump `round-N`; the cap (~3) or an ambiguous
   spec escalates with `needs-human`. **You** merge once CI is green and you're satisfied.

That's the loop. To prove a rebuilt or relocated setup end to end — or recover a lost one
— follow the smoke test and runbook in [`RESTORE.md`](RESTORE.md).
