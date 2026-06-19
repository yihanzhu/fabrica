# RESTORE.md — rebuild the whole team from this repo

This is the disaster-recovery runbook for Fabrica. If the live setup is lost — the
Claude Routines deleted, the Codex connection dropped, labels or CI gone — follow this
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

- **A Claude plan with Routines** — the coder, coder-revision, and brief all run as
  first-party Claude Routines on your plan (metered ordinary use, **no API key**). The
  manager (Faber) runs as an ordinary Claude Code chat session.
- **Codex (OpenAI)** with PR review — this is the cross-vendor reviewer. A ChatGPT plan
  that includes Codex PR review is enough for personal repos.
- **GitHub access** to each target repo, plus the **`gh` CLI authenticated** locally
  (`gh auth status` should show you logged in) for labels and one-off commands.
- **The personal config you must supply** (keep it parameterized — see the note above):
  - the **target repo name(s)**, e.g. `<owner>/<repo>` — the repo(s) the team works in.
    (Fabrica is its own target repo; add others as you adopt the team elsewhere.)
  - your **timezone / cron time** for the daily brief.
  - your **notify channel** for the brief (Slack / push / Telegram).

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
3. Give that session GitHub access (`gh` CLI or the GitHub connector) so Faber can read
   state and open issues.

Faber **only opens issues** — never writes code, never merges, never applies `ready`
itself. That front gate (you applying `ready`) is what wakes the coder.

---

## 2. Recreate the routines

Each routine is recreated from its file in [`routines/`](routines/). For each one:
open the file, copy the fenced **Instructions** block into a new Claude Routine, and set
the **trigger** + routine settings exactly as the file's header specifies (model,
permissions, connectors).

| Routine | Source file | Trigger |
|---------|-------------|---------|
| Coder | [`routines/coder.md`](routines/coder.md) | GitHub event → `issues.labeled` (acts only on `ready`) |
| Coder (revisions) | [`routines/coder-revision.md`](routines/coder-revision.md) | GitHub event → `pull_request_review.submitted` |
| Daily brief | [`routines/brief.md`](routines/brief.md) | Schedule → daily cron (your timezone) |

Notes:
- Point each routine's **Repository** setting at your target repo `<owner>/<repo>`.
- The coder routines need **write** permission and **GitHub-only** connectors; the brief
  is **read-only** and adds one notify channel. The files spell this out — follow them.
- The coder routine self-guards: if the applied label is not `ready`, it stops. That's
  why a single `issues.labeled` trigger is safe.

---

## 3. Recreate the Codex reviewer

The reviewer runs on **Codex (OpenAI)**, not as a Claude routine — that cross-vendor split
is deliberate (decorrelated blind spots).

1. Connect **Codex's PR review** to each target repo `<owner>/<repo>` so it reviews
   automatically when a PR is opened or updated.
2. Use the review prompt in [`reviewer/codex-review.md`](reviewer/codex-review.md) as its
   instructions.
3. **Comments only / read-only:** give Codex no write access beyond posting review
   comments. It never pushes, never approves-to-merge, never merges, and is never the
   author of the code it reviews. This is non-negotiable (see Safety rails below).

---

## 4. Recreate labels, branch protection, and CI (per target repo)

Do this **once per target repo**. The full checklist already exists — **reuse it**, do
not re-derive it: [`templates/repo-setup.md`](templates/repo-setup.md).

That checklist covers:
- **Labels** — the `ready` / `round-0..round-3` / `needs-human` set the stateless
  routines use as their state. (The `gh label create` loop is in that file.)
- **Branch protection on `main`** — require CI status checks to pass; **no auto-merge in
  Phase 1**.
- **CI** — comes from [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (structure
  check + shellcheck). It is the **hard merge gate**; restore it by having this repo's
  `.github/workflows/` present on `main`. Don't copy its steps here — link to it.
- **Conventions** — drop [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md) into
  the target repo's root, filled in for that repo.
- **Wiring** — the same routine/reviewer wiring you did in steps 2–3.

If you are restoring **Fabrica itself**, the labels and CI live in this repo already;
recreate any labels that were lost with the loop in `templates/repo-setup.md` using
`<owner>/<repo>` = your fork of this repo.

---

## 5. Smoke test — prove the rebuilt team is alive

Run **one trivial issue** through the full loop end to end:

1. Ask **Faber** for a throwaway change (e.g. a one-line doc tweak). Faber opens an issue.
2. **You** apply the `ready` label (the front gate). This should wake the **Coder**.
3. Confirm the Coder opens a PR that says `Closes #<n>` and carries `round-0`.
4. Confirm **Codex** posts review comments (and nothing else — no approve, no merge).
5. If there's feedback, confirm the **coder-revision** routine pushes follow-up commits
   and bumps the `round-N` label.
6. Confirm **CI** runs and goes green on the PR.
7. **You** merge once CI is green and you're satisfied.

If every arrow above fired, the team is back. If one stage is silent, re-check that
routine's **trigger** and **repository** setting (step 2) and Codex's connection (step 3).

> Optional: confirm the **brief** by waiting for its daily run (or temporarily setting the
> cron a few minutes out), and checking the notify channel gets one action-first message.

---

## 6. Safety rails that must survive any rebuild

These are load-bearing — per the self-modification safety section of
[`CLAUDE.md`](CLAUDE.md), never weaken them without explicit human sign-off:

- **Reviewer stays read-only / comments-only.** Codex never pushes, approves-to-merge, or
  merges, and is never the author.
- **No auto-merge in Phase 1.** Faber pings; **you** merge. Auto-merge is earned later,
  low-risk + green CI only.
- **Rounds cap (~3) + `needs-human` escalation stay intact.** Because routines are
  stateless, this state lives in the **labels** (`round-0..3`, `needs-human`), not in
  agent memory — so the labels (step 4) are part of the safety system, not decoration.
- **CI is the hard gate.** Merges require green CI; restore CI before trusting the loop.
- **Front gate by a human.** Only a human applies `ready`; Faber never self-approves.

---

## Troubleshooting / gotchas

Real lessons from setting this up the first time:

- **The GitHub App install is a web flow.** The Claude **desktop app does not surface the
  GitHub App installation** — do it from **claude.ai/code in a browser** to grant the
  repo access that remote routines need.
- **Local `gh` auth is NOT the same connection as the claude.ai web GitHub link.**
  Authenticating `gh` locally lets your *local* session and one-off commands hit GitHub;
  it does **not** give a cloud-run routine access. The web GitHub connection is separate —
  you may need both.
- **A company-managed (Team / Enterprise) Claude account can have the GitHub connection
  gated by an admin.** If you can't connect GitHub, that's likely the cause. A **personal
  Pro / Max account avoids that gate.**
- **Local vs. remote routines run differently.** A routine run **locally** is just a normal
  session on your plan (**no API key**, uses your local `gh` auth). A routine run **in the
  cloud (remote)** needs the **web GitHub connection** (the App install above) — local
  `gh` auth won't reach it.
- **Coder "did nothing" on a labeled issue?** Expected unless the label was exactly
  `ready` — the coder routine stops on any other label (step 2). Check the label.
- **Reviewer silent?** Re-check Codex is connected to *that* repo and triggers on PR
  open/update (step 3). Claude and Codex never talk directly — the PR is the only message
  bus, so if Codex isn't connected, the loop just stalls with no error.
