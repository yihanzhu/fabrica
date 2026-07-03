# RESTORE.md — rebuild the whole team from this repo

This is the disaster-recovery runbook for Fabrica. If the live setup is lost — the
`/faber` command gone, the Codex CLI disconnected, labels or CI missing — follow this
top to bottom to turn **this repo** back into a running coding team.

This repo is the source of truth for *how the team works*. Everything below is
reconstructed **from files already in this repo** — this runbook only points at them and
gives the order. It does not duplicate their contents; open each referenced file and use
it as written.

> **Parameterize, don't hardcode.** Wherever you see `<owner>/<repo>` (or
> `<owner>`), substitute your own target repo(s). Per the reusability rule in
> [`CLAUDE.md`](CLAUDE.md), keep personal usernames and repo names out of the shipped
> files — supply them here at restore time, not in the templates.

---

## 0. Prerequisites

Accounts and access you need before starting:

- **A Claude plan that runs Claude Code** — the whole team runs in-session: Faber is an
  ordinary Claude Code chat, and it spawns the coder (and fix-mode coder) as subagents in
  that same session (metered ordinary use, **no API key**).
- **Codex (OpenAI) CLI** — this is the cross-vendor reviewer, driven by
  `scripts/codex-review.sh`. A ChatGPT plan that includes Codex review is enough for
  personal repos; the Codex CLI must be installed and signed in.
- **GitHub access** to each target repo, plus the **`gh` CLI authenticated** locally
  (`gh auth status` should show you logged in) for labels and the loop's `gh` calls.
- **The personal config you must supply** (keep it parameterized — see the note above):
  - the **target repo name(s)**, e.g. `<owner>/<repo>` — the repo(s) the team works in.
    (Fabrica is its own target repo; add others as you adopt the team elsewhere.)

Read [`README.md`](README.md) once for the mental model (the team, the loop, the
design "why") and [`CLAUDE.md`](CLAUDE.md) for the conventions and safety rails before
you rebuild.

---

## 1. Recreate Faber (the manager)

Faber is the **only human-facing surface** — you talk only to Faber; the workers have no
human channel.

1. Create a Claude Code project (a chat you keep).
2. Paste the full contents of [`manager/CLAUDE.md`](manager/CLAUDE.md) in as the project's
   persistent instructions / persona.
3. Recreate the `/faber` slash command by running
   [`scripts/install.sh`](scripts/install.sh) (no arguments). It generates
   `~/.claude/commands/faber.md` from [`templates/faber-command.md`](templates/faber-command.md),
   substituting this clone's own path for the placeholder — so the command never hardcodes
   a repo location. Idempotent: re-running is safe, and an existing differing `faber.md` is
   backed up to `faber.md.bak` before overwriting. Do **not** recreate this command by hand.
4. Give that session GitHub access (`gh` CLI or the GitHub connector) so Faber can read
   state and open issues.

Faber **never writes code or opens PRs** and **never approves on your behalf** — it opens
issues and orchestrates the loop. Faber **does** merge clean, low-risk PRs (CI green +
Codex review passed) under your standing authorization, and brings you anything needing
human review (safety-rail changes, north-star / goal drift, high-risk back-look). The
front gate is **your approval of the drafted spec** (for a user-directed issue, your
one-liner is the request → Faber drafts the spec → you approve that drafted spec — drafting
alone never earns `ready`): once you approve the spec, Faber applies the `ready` label as the
record of your go (it never labels a spec you haven't approved). That `ready` label is Faber's
own cue to spawn the coder subagent — one launch per issue, not a separate automated trigger.

---

## 2. Recreate the coder + brief instruction sources

Nothing to "wire" here — the coder and brief are **not standalone services**. They are
instruction files in [`routines/`](routines/) that Faber reads and passes (with the
specific task context) to the subagents it spawns in-session. To restore them, just make
sure the files are present on `main`:

| File | Role |
|------|------|
| [`routines/coder.md`](routines/coder.md) | Coder baseline instructions Faber passes to a spawned coder subagent |
| [`routines/coder-revision.md`](routines/coder-revision.md) | Coder fix-mode instructions for a spawned revision subagent |
| [`routines/brief.md`](routines/brief.md) | Brief instructions Faber can run for resurfacing (read-only; not auto-scheduled) |

Notes:
- The `/faber` command (step 1) already points Faber at these files, so once it is
  installed Faber will use them when it spawns a coder; there is no separate trigger,
  repository, or connector setting to configure.
- The coder instructions self-guard: the coder confirms the issue carries `ready` (Faber's
  record that it is cleared to run — your spec-approval OR Faber⇄Codex consensus) before
  doing anything. That keeps the front gate intact even inside the spawn.

---

## 3. Recreate the Codex reviewer

The reviewer runs on **Codex (OpenAI)**, not on Claude — that cross-vendor split is
deliberate (decorrelated blind spots). It uses Codex's **built-in** review
(`codex exec review`) driven by the in-session harness — see
[`reviewer/codex-review.md`](reviewer/codex-review.md) for the mechanism and the loop.

Make sure the **Codex CLI is installed and signed in**, then drive review with
[`scripts/codex-review.sh`](scripts/codex-review.sh). The script lives only in *this*
control-plane repo, so from within the target repo's clone Faber invokes it by **absolute
path** — `"$HOME/git/fabrica/scripts/codex-review.sh" <PR#>` (substitute your fabrica
clone; or put `<fabrica>/scripts` on `PATH` and call `codex-review.sh <PR#>`). Do **not**
copy the script into each target repo. `gh` infers `<owner>/<repo>` from the cwd; the
script runs `codex exec review` (read-only forced via `-c sandbox_mode="read-only"`) and
posts Codex's verdict to the PR **verbatim**. No GitHub-side wiring needed; the script
itself only posts a comment.

**Comments only / read-only is non-negotiable**: Codex (and the script) get no write
access beyond posting review comments. It never pushes, never approves-to-merge, never
merges, and is never the author of the code it reviews (see Safety rails below).

> **Future, not wired.** Codex also offers a GitHub integration that could review PRs
> automatically on open/update with no Faber session — an autonomous upgrade. It is **not
> set up here**; the in-session harness above is the only review path today.

---

## 4. Recreate labels, branch protection, and CI (per target repo)

Do this **once per target repo**. The full checklist already exists — **reuse it**, do
not re-derive it: [`templates/repo-setup.md`](templates/repo-setup.md).

That checklist covers:
- **Labels** — the `debating` / `ready` / `round-0..round-3` / `needs-human` / `merge-ready`
  set the loop uses as its state (each coder spawn is stateless, so the round lives in the
  label; `debating` marks a proactive issue under manager-debate, not yet approved).
  The `gh label create` loop is in that file. `setup-target-repo.sh` is the **canonical
  source of truth** for these labels: a normal run force-edits each live label to the
  script's definitions, so **re-running reconciles any drift**. To verify labels after a
  restore **without mutating anything**, run the read-only dry mode —
  `scripts/setup-target-repo.sh --check <owner>/<repo>` — which reports per label
  `matches` / `differs` / `missing` and exits non-zero if anything is missing or differs.
- **Branch protection on `main`** — require CI status checks to pass; keep GitHub's
  **native auto-merge button off** (merges go through Faber or the human, both gated on
  green CI — not a server-side trigger). Caveat: that section of `repo-setup.md` is a **UI checkbox checklist with no
  command** (unlike the labels loop), and **branch protection isn't available on free
  private repos** — it needs a paid plan or a public repo. If you can't enable it, **CI is
  still the hard gate** (see Safety rails); you just lose the server-side enforcement.
- **CI** — comes from [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (structure
  check + shellcheck). It is the **hard merge gate**; restore it by having this repo's
  `.github/workflows/` present on `main`. Don't copy its steps here — link to it.
  - The structure check enforces the full backup against
    [`ci/required-files.txt`](ci/required-files.txt) — the **source of truth** for every
    restore-critical file. It fails the build if any listed path is missing (and if a
    listed `scripts/*.sh` isn't executable), so a PR can't silently drop `install.sh`,
    `RESTORE.md`, or any other load-bearing file and stay green. When you add a file the
    team needs to be reconstructable, add it to that manifest.
  - **Out of scope: `claude.yml`.** `.github/workflows/` also contains
    [`claude.yml`](.github/workflows/claude.yml) — the optional `@claude`-mention helper
    (`anthropics/claude-code-action@v1`). It is **not part of the team loop** and is not
    required to restore the coding team, so it is out of scope for this runbook. If you do
    want it back, note that it needs a `CLAUDE_CODE_OAUTH_TOKEN` repo secret, which lives
    only in GitHub repo settings (not in any file here) and must be re-created by hand.
- **North star (per target)** — the team steers by the target's **committed**
  `.fabrica/north-star.md` (resolved via `scripts/lib/north-star.sh`; the manager-debate gate
  reads its committed content). Restore it in the target repo: copy
  [`templates/.fabrica/north-star.md`](templates/.fabrica/north-star.md) to
  `.fabrica/north-star.md`, replace the placeholder with your direction, **remove the
  `<!-- fabrica-shipped-default -->` marker**, and **commit** it — a missing / still-marked /
  no-`status: active` star FAILs the proactive gate (`manager-review.sh`) and WARNs in
  `doctor.sh`. Setup does **not** seed it — `setup-target-repo.sh` only creates the loop labels.
  (When restoring **Fabrica itself**, its north star is the root
  [`NORTH_STAR.md`](NORTH_STAR.md) — Fabrica is its own target — so there's no separate
  `.fabrica/north-star.md` to restore.)
- **Conventions** — drop [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md) into
  the target repo's root, filled in for that repo.
- **The in-session setup** — install `/faber` (step 1) and connect the Codex CLI for
  `scripts/codex-review.sh` (step 3); there are no per-repo routine triggers to wire.

If you are restoring **Fabrica itself**, the labels and CI live in this repo already;
recreate any labels that were lost with the loop in `templates/repo-setup.md` using
`<owner>/<repo>` = your clone/copy of this repo (restoring Fabrica is the same repo, not
a fork).

---

## 5. Smoke test — prove the rebuilt team is alive

**Pre-flight first.** Before running the full live loop, run the read-only self-check
from this clone to catch the cheap failures fast — a missing credential, an
uninstalled `/faber`, a dropped restore-critical file, or absent loop labels:

```sh
scripts/doctor.sh                 # checks (a) /faber points here (b) gh auth (c) claude on PATH (d) codex (e) required files
scripts/doctor.sh <owner>/<repo>  # also verifies that target repo's loop labels (delegates to setup-target-repo.sh --check)
```

It prints a pass/fail line per check and exits non-zero if anything fails; it never
mutates anything. Fix any `fail:` line before the smoke test below — otherwise the
loop will stall at exactly that gap. Then prove the team end to end:

Run **one trivial issue** through the full loop end to end, all from your Faber session:

1. Ask **Faber** for a throwaway change (e.g. a one-line doc tweak). Your ask is the
   *request*; Faber drafts the spec and opens an issue.
2. **You** approve that drafted spec (the front gate — approving the spec Faber drafted,
   not just the topic); **Faber** then applies the `ready` label as the record of your
   approval, and **spawns a coder subagent**.
3. Confirm the coder opens a PR that says `Closes #<n>` and carries `round-0`.
4. Confirm the review path:
   - **Faber runs** `scripts/codex-review.sh <PR#>` and **Codex** posts review comments
     to the PR (and nothing else — no approve, no merge).
   - **CI** runs on the PR and goes green.
5. If there's feedback, confirm **Faber spawns a fix-mode coder** that pushes follow-up
   commits and bumps the `round-N` label, then re-runs `codex-review.sh`.
6. Confirm the merge path: for a clean, low-risk PR (CI green + Codex passed) **Faber
   merges** under your standing authorization; a PR needing human review (safety-rail /
   north-star / high-risk) is brought to **you** instead.

If every step above fired, the team is back. If one stage is silent: re-check `/faber` is
installed and points at this repo (step 1), the coder instruction files are present (step
2), and the Codex CLI is signed in so `codex-review.sh` runs (step 3).

> Optional: confirm the **brief** by asking Faber to run it, and check you get one
> action-first message back.

---

## 6. Safety rails that must survive any rebuild

These are load-bearing — per the self-modification safety section of
[`CLAUDE.md`](CLAUDE.md), never weaken them without explicit human sign-off:

- **Reviewer stays read-only / comments-only.** Codex never pushes, approves-to-merge, or
  merges, and is never the author.
- **Merge stays gated, and human-review carve-outs survive.** Faber may auto-merge a PR
  only when it's **CI-green + Codex-clean + low-risk** (standing authorization). It must
  **not** merge — it brings the PR to you — for safety-rail changes, ambiguous specs,
  anything escalated (`needs-human`/round-cap), north-star milestones / goal drift, or
  high-risk back-look (auth, migrations, shared repos). Codex never approves or merges.
- **Rounds cap (~3) + `needs-human` escalation stay intact.** Because each coder spawn is
  stateless, this state lives in the **labels** (`round-0..3`, `needs-human`), not in agent
  memory — so the labels (step 4) are part of the safety system, not decoration.
- **CI is the hard gate.** Merges require green CI; restore CI before trusting the loop.
- **Front gate clears via one of two paths; `ready` records that an issue is cleared.** A
  **user-directed** issue runs after you approve the spec Faber drafts (your one-liner is the
  request → Faber drafts the spec → you approve that drafted spec). A **proactive** issue runs
  after you've approved the active north star **and** Faber⇄Codex manager-debate reaches
  consensus — no per-issue ask. `ready` means "cleared to run" via *either* path; Faber never
  self-applies it acting alone (a proactive issue takes the passed consensus, not Faber by
  itself) and never on a user-directed spec you haven't approved.

---

## Troubleshooting / gotchas

Real lessons from setting this up:

- **`/faber` not found, or points at the wrong repo?** Re-run
  [`scripts/install.sh`](scripts/install.sh) (no arguments) from your fabrica clone — it
  regenerates `~/.claude/commands/faber.md` with this clone's path. Do not hand-edit it.
- **Local `gh` auth is what the loop uses.** Faber, the spawned coder, and
  `codex-review.sh` all run in your local Claude Code session and hit GitHub through your
  local `gh` auth. If GitHub calls fail, check `gh auth status` first.
- **Coder won't start on an issue?** Expected unless the issue carries exactly `ready`
  (Faber's record that it is cleared to run — your spec-approval for a user-directed issue,
  OR Faber⇄Codex consensus for a proactive one) — the coder instructions stop on anything
  else (step 2). Confirm the issue is cleared and Faber applied `ready`.
- **No Codex review on the PR?** The review is not automatic — **Faber must run**
  `scripts/codex-review.sh <PR#>` from the target repo's clone. Check the Codex CLI is
  installed and signed in (`codex` runs), and that the script is invoked by absolute path.
  Claude and Codex never talk directly — the PR is the only message bus.
