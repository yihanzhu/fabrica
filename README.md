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
| **Coder** | Claude | Routine | issue labeled `ready` | yes (branches, PRs) |
| **Coder (revisions)** | Claude | Routine | review submitted | yes |
| **Reviewer** | Codex (OpenAI) | Codex via `scripts/codex-review.sh` (in-session) / GitHub integration (autonomous) | PR opened/updated | **comments only** |

You talk **only** to Faber. The workers have no human channel — only GitHub events
wake them. Claude and Codex never talk directly; **the PR is the message bus.**

## The loop

```
  one-liner → Faber drafts spec → opens issue
                                       │
           YOU approve → Faber labels  ┤  (front gate = your approval;
              it `ready` (your go)  ───┤   Faber records it, never self-approves)
                                       ↓
                                   [Coder]  → opens PR (label round-0)
                                       ↓
                                  [Reviewer = Codex]  → comments only
                                       ↓
                          [Coder revisions]  adopt reasonable / push back
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
- **Routines are stateless** → rounds + escalation live in **labels**
  (`round-0..3`, `needs-human`), not agent memory.
- **Runs on the plan** via first-party Routines (Claude) + Codex's own PR review —
  compliant ordinary use, metered. Prototype on personal repos; apply terms
  diligence before any work/shared repo.

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
