# Fabrica — the workshop

A small autonomous coding team. **Faber** (the manager) runs the shop; the workers
(a Claude coder + a Codex reviewer) build and review code via GitHub events.

This repo is the **control plane** — it defines *how the team works*. It is **not**
where the team writes code. The team works in separate **target repos**; this repo
holds the prompts, roles, and templates you edit to set up and evolve the team.

Completes the trio: **Otium** (life) · **Valor** (work) · **Fabrica** (the craft of building).

## The team

| Agent | Vendor | Surface | Trigger | Writes? |
|-------|--------|---------|---------|---------|
| **Faber** (manager) | Claude | Claude Code chat + `manager/CLAUDE.md` | you talk to it | issues only, never code/merge |
| **Faber's brief** | Claude | Schedule routine | daily cron | read-only |
| **Coder** | Claude | Subagent Faber spawns (in-session mode) / Routine on `issues.labeled` (autonomous mode) | in-session: Faber spawns after `ready`; autonomous: the routine fires | yes (branches, PRs) |
| **Coder (revisions)** | Claude | Subagent Faber spawns (in-session mode) / Routine on review submitted (autonomous mode) | in-session: Faber spawns on review; autonomous: the reviewer fires the routine | yes |
| **Reviewer** | Codex (OpenAI) | `scripts/codex-review.sh` (in-session mode) / GitHub integration (autonomous mode) | PR opened/updated | **comments only** |

You talk **only** to Faber. The reviewer has no human channel — only the PR wakes it.
Claude and Codex never talk directly; **the PR is the message bus.**

**Two modes, pick one — never mix.** The team runs end-to-end in **one** of two
mutually-exclusive modes; each keeps launch + review + revision consistent, so nothing
strands:

- **In-session mode (default).** Faber drives the whole loop in a Claude Code session: you
  approve → Faber applies `ready` → Faber spawns the coder → Faber runs the Codex review via
  `scripts/codex-review.sh` → on feedback Faber spawns a fix-mode coder + bumps the round.
  **No routines, no Claude GitHub App.**
- **Autonomous mode (optional).** The `issues.labeled` coder routine + the
  `pull_request_review.submitted` coder-revision routine + the Codex GitHub-integration
  reviewer run the loop with no Faber session. The reviewer's event fires the revision
  routine, so these three are wired as a set. **Requires the Claude GitHub App;** Faber does
  not spawn.

**Invariant: exactly one coder launch per approved issue** — and the reviewer ↔ revision
pairing is fixed within each mode, so no supported combo strands revisions.

## The loop

```
  one-liner → Faber drafts spec → opens issue
                                       │
           YOU approve → Faber labels  ┤  (front gate = your approval;
              it `ready` (your go)  ───┤   Faber records it, never self-approves)
                                       ↓
                          Faber spawns [Coder]  → opens PR (label round-0)
                          (one launch per approval; if a routine is wired
                           instead, it fires here — never both)
                                       ↓
                                  [Reviewer = Codex]  → comments only
                                       ↓
                          [Coder revisions]  adopt reasonable / push back
                          (in-session: Faber spawns fix-mode coder;
                           autonomous: reviewer fires revision routine)
                                       │           (bump round-N)
                          ┌── round < 3 ┘
                          ↺  re-review
                          └── round = 3 → label `needs-human` → Faber pings YOU
                                       ↓
                       CI green + you're satisfied → YOU merge
```

## Design decisions (the "why")

- **3 roles, fixed.** Manager = the PM (no separate PM). Add an agent only for a
  distinct *job + trigger + tool surface* — not per discipline (no FE/BE split;
  specialize via each target repo's `CLAUDE.md`).
- **Cross-vendor by design.** Claude codes, Codex reviews — different training/
  architecture = decorrelated blind spots. A reviewer's value is being *different*,
  not a second copy.
- **Reviewer is read-only, comments only, never the author.** Non-negotiable.
- **Judgment lives at the spec (front gate), not the diff.** You approve intent up front;
  Faber records your approval with the `ready` label (never self-approving) — you stop
  reviewing diffs.
- **CI is the hard gate** — ground truth. Autonomy rests on tests first, diverse
  reviewer second.
- **No auto-merge in Phase 1.** Faber pings; you merge. Earn auto-merge later for
  low-risk + green CI; always back-look high-risk (auth, migrations, shared repos).
- **One rounds counter (~3).** Comments resolved or disagreement burned both count;
  a single push-back doesn't escalate — only an unresolved one at the cap reaches you.
- **One coder launch per approved issue.** In-session mode is the default: you approve →
  Faber applies `ready` → Faber spawns the coder. Autonomous mode wires a Claude Coder
  *routine* on `issues.labeled` instead. Pick **one complete mode** — never both, so a
  single approval never starts two coder runs and review feedback never strands (the
  reviewer ↔ revision handler is paired within each mode).
- **State lives in labels, not agent memory** → rounds + escalation live in **labels**
  (`round-0..3`, `needs-human`), not agent memory.
- **Runs on the plan** via Claude (Faber + coder) + Codex's own PR review — compliant
  ordinary use, metered. The optional routine path also runs as first-party Routines.
  Prototype on personal repos; apply terms diligence before any work/shared repo.

## Layout

```
manager/CLAUDE.md          Faber's persistent role (paste into Claude Code)
routines/coder.md          Coder routine instructions
routines/coder-revision.md Coder-handles-review routine
routines/brief.md          Faber's daily-brief routine
reviewer/codex-review.md   Codex reviewer mechanism + in-session review loop
scripts/install.sh         Generate the /faber command with a repo-derived path (idempotent)
scripts/codex-review.sh    Codex reviewer harness: post `codex exec review` to a PR, verbatim
scripts/setup-target-repo.sh  Bootstrap a target repo's loop labels (idempotent)
templates/faber-command.md Template for the /faber command (path placeholder)
templates/target-CLAUDE.md Drop into each target repo (conventions + PR-size rule)
templates/repo-setup.md    Labels + branch protection checklist
RESTORE.md                 Disaster-recovery runbook: rebuild the team from this repo
```

## Rollout

- **Phase 1** — prove the loop on one seeded target repo. Front gate + manual merge.
- **Phase 2** — live: daily brief + resurfacing + merge pings.
- **Phase 3** — auto-merge low-risk after ~10 clean loops.
