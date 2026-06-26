# Fabrica — the workshop

A small autonomous coding team. **Faber** (the manager) runs the shop in a Claude Code
session: you approve specs, and Faber spawns a Claude coder subagent to build and runs a
Codex reviewer to review.

This repo is the **control plane** — it defines *how the team works*. It is **not**
where the team writes code. The team works in separate **target repos**; this repo
holds the prompts, roles, and templates you edit to set up and evolve the team.

Completes the trio: **Otium** (life) · **Valor** (work) · **Fabrica** (the craft of building).

**Get started →** [QUICKSTART.md](QUICKSTART.md)

## The team

You talk **only** to Faber, in a Claude Code session. Faber orchestrates the other roles
within that session — spawning the coder and running the reviewer — so there is no
separate human channel to the workers. Claude and Codex never talk directly;
**the PR is the message bus.**

| Agent | Vendor | How it runs | Writes? |
|-------|--------|-------------|---------|
| **Faber** (manager) | Claude | You talk to it in a Claude Code chat (`manager/CLAUDE.md`) | issues only; never authors code/PRs (merges clean low-risk PRs) |
| **Coder** | Claude | A subagent Faber spawns with the issue/PR context + `routines/coder.md` | yes (branches, PRs) |
| **Coder (revisions)** | Claude | A fix-mode subagent Faber spawns with `routines/coder-revision.md` | yes |
| **Reviewer** | Codex (OpenAI) | Faber runs `scripts/codex-review.sh` against the PR | **comments only** |

## The loop

The loop is **in-session**: Faber drives every step from one Claude Code chat. There is
exactly one coder launch per approved issue, one review path, and one revision path.

```
  one-liner → Faber drafts spec → opens issue
                                       │
           YOU approve → Faber labels  ┤  (front gate = your approval;
              it `ready` (your go)  ───┤   Faber records it, never self-approves)
                                       ↓
              Faber spawns [Coder] subagent  → opens PR (label round-0)
                                       ↓
              Faber runs scripts/codex-review.sh  → Codex posts comments only
                                       ↓
              Faber spawns [Coder, fix mode]  adopt reasonable / push back
                                       │              (bump round-N)
                          ┌── round < 3 ┘
                          ↺  Faber re-runs codex-review.sh
                          └── round = 3 → label `needs-human` → Faber pings YOU
                                       ↓
              CI green + Codex clean (low-risk) → Faber merges
                 (high-risk / escalations / rail changes / north-star → YOU)
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
- **Faber auto-merges clean, low-risk PRs.** Under your standing authorization, Faber
  merges a PR once CI is green and Codex is clean — no per-PR confirmation — **unless it is
  high-risk**. The merge is **pinned to the reviewed head** (`gh pr merge --squash
  --match-head-commit <reviewed-sha>`), so a commit landing between the head-check and the
  merge makes it **fail atomically** rather than merge a head Codex never reviewed.
  High-risk PRs always come to your merge gate even when CI-green + Codex-clean
  (auth, DB/schema migrations, shared/production repos, security-sensitive or other
  operator-judgment changes). You're also brought in for `needs-human`/round-cap escalations,
  safety-rail changes, and **north-star milestones / goal drift**. The high-risk carve-out is
  the last word on merging — when in doubt about risk, it comes to you.
- **One rounds counter (~3).** Comments resolved or disagreement burned both count;
  a single push-back doesn't escalate — only an unresolved one at the cap reaches you.
- **State lives in labels, not memory.** Each coder is a fresh subagent with no memory of
  the last round, so rounds + escalation live in **labels** (`round-0..3`, `needs-human`)
  that Faber reads and bumps each round.
- **Runs on the plan** in an ordinary Claude Code session (Claude coder subagents) plus
  Codex's built-in review via `scripts/codex-review.sh` — compliant ordinary use, metered.
  Prototype on personal repos; apply terms diligence before any work/shared repo.

> **Future, not wired.** An autonomous mode — GitHub events waking the coder and Codex's
> GitHub integration reviewing on PR open/update, with no Faber session in the loop — is a
> possible later upgrade. It is **not built**; nothing in this repo wires it. The one path
> that exists today is the in-session loop above.

## Layout

```
QUICKSTART.md              The ~10-min golden path: stand the team up from scratch
CLAUDE.md                  Repo conventions + self-modification safety rails (vs manager/CLAUDE.md = Faber's persona)
manager/CLAUDE.md          Faber's persistent role (paste into Claude Code)
routines/coder.md          Coder baseline instructions Faber passes to a spawned coder subagent
routines/coder-revision.md Coder fix-mode instructions (handle review feedback)
routines/brief.md          Brief instructions Faber can run (resurfacing; not auto-scheduled)
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

- **Phase 1** — prove the in-session loop on one seeded target repo. Front gate held the
  judgment; merge was manual while the loop earned trust.
- **Phase 2** — live: the **brief** resurfaces what needs you (read-only — it surfaces
  state, never merges), and on a **status / Tracking pass** Faber **auto-merges clean,
  low-risk PRs** (CI green + Codex clean) under standing authorization — escalating only
  `needs-human`/round-cap, safety-rail changes, and north-star milestones / goal drift.
- **Phase 3** — widen the auto-merge envelope as the loop proves out; always back-look
  high-risk work (auth, migrations, shared repos).
