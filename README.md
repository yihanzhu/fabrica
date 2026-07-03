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
exactly one coder launch per cleared issue, one review path, and one revision path.

```
  one-liner → Faber drafts spec → opens issue
                                       │
        gate (front gate = at the north-star altitude):
          • user-directed issue → your one-liner is the request → Faber drafts
              the spec → YOU approve that drafted spec → Faber labels it `ready`
              (drafting alone never earns `ready`)
          • proactive issue → Faber⇄Codex manager-debate CONSENSUS
              → Faber removes `debating`, labels it `ready` (no per-issue ask)
          (Faber alone never self-approves; the consensus IS the gate
           for proactive north-star work — see manager-review.md)
                                       ↓
              Faber spawns [Coder] subagent  → opens PR (label round-0)
                                       ↓
              Faber runs scripts/codex-review.sh  → Codex posts comments only
                                       ↓
              Faber spawns [Coder, fix mode]  adopt reasonable / push back
                                       │              (bump round-N)
                          ┌── round < 3 ┘
                          ↺  Faber re-runs codex-review.sh
                          └── round = 3 (cap) → SCOPE DOWN + FOLLOW-UP (productive):
                                 land the converged core (one scoped-down change →
                                 clean review → merge) + open a follow-up issue for
                                 the contested remainder; only a genuine standoff /
                                 safety-rail / north-star → label `needs-human` → pings YOU
                                       ↓
              CI green + Codex clean (low-risk) → Faber runs scripts/merge-pr.sh <PR#>
                 (in-session, back-to-back; SHA-pinned merge — status scan / brief only report)
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
- **Judgment lives at the direction (front gate at the north-star altitude), not the diff.**
  You approve the **north star** — each target repo's own committed
  [`.fabrica/north-star.md`](templates/.fabrica/north-star.md) (when the target *is* this
  control-plane repo, that file is the root [`NORTH_STAR.md`](NORTH_STAR.md) — Fabrica is its
  own target) — and Faber pursues it
  autonomously — you stop reviewing diffs, and for **proactive** work you stop approving each
  issue. Two paths clear an issue to run: a **user-directed** issue where your one-liner is the
  *request* — Faber drafts the spec, **you still approve that drafted spec**, and *that approval*
  is the gate Faber records with `ready` (drafting alone does not earn `ready`; user-directed
  issues are *not* exempt from per-spec approval);
  a **proactive** issue on **Faber⇄Codex manager-debate consensus** — on consensus Faber
  removes `debating` and applies `ready` itself, no per-issue ask (this is the only path with no
  per-issue approval, and it is conditional on your having explicitly approved the active north
  star). **Faber acting alone never self-approves**; for proactive north-star work the
  cross-vendor consensus *is* the gate (see
  [`reviewer/manager-review.md`](reviewer/manager-review.md)). For *proactive* work you are
  pulled back in only at the north-star altitude: **north-star achieved**, **goal drift /
  transition**, and `needs-human` escalations — user-directed issues still come to you for the
  drafted-spec approval.
- **CI is the hard gate** — ground truth. Autonomy rests on tests first, diverse
  reviewer second.
- **Faber auto-merges clean, low-risk PRs — in-session only.** Under your standing
  authorization, Faber **may auto-merge a PR it reviewed in-session** when it is CI-green,
  Codex-clean, and low-risk — no per-PR confirmation — **unless it is high-risk**. Faber does
  this by running **`scripts/merge-pr.sh <PR#>`** from within the target repo's clone (it does
  not hand-craft a merge command). `merge-pr.sh` owns the mechanical safety: it reads the
  reviewed head+base SHAs from the authenticated `codex-review.sh` marker, confirms the PR's
  current head **and** base still match those (refusing if either moved since the review),
  gates on the base branch's **required status checks** (falling back to ≥1 real passing CI
  check with none failing when no required checks are defined — optional checks like preview
  deploys are informational), refuses a PR that needs an **approving review**
  (`reviewDecision=REVIEW_REQUIRED`, since the comments-only reviewer never approves), and
  merges with a **repo-permitted method** (squash if allowed) **pinned via
  `--match-head-commit`** — refusing otherwise. The merge is **scoped to the target repo** (never another repo) and **bound to the
  exact head Faber reviewed** — if the head moved, Faber **re-reviews rather than merges** (the
  script itself refuses a moved head; a head Codex never reviewed is never merged). A later
  **status/Tracking scan and the brief only surface `merge-ready` PRs (read-only)** — they never
  auto-merge; those get merged on a fresh in-session review, or by you. High-risk PRs always
  come to your merge gate even when CI-green + Codex-clean (auth, DB/schema migrations,
  shared/production repos, security-sensitive or other operator-judgment changes) — Faber does
  **not** run `merge-pr.sh` for those. You're also brought in for `needs-human`/round-cap
  escalations, safety-rail changes, and **north-star milestones / goal drift**. The high-risk
  carve-out is the last word on merging — when in doubt about risk, it comes to you. The
  **unattended status-scan / cross-repo auto-merge** (a daemon merging without a Faber session)
  is a **future extension of `merge-pr.sh`, deferred to [#46](../../issues/46)** — not supported
  yet per the script's header.
- **One rounds counter (~3), and the cap is productive.** Comments resolved or disagreement
  burned both count; a single push-back doesn't escalate. At the ~3-round cap Faber **scopes
  down + splits** rather than dead-ending: land the part the reviewer is satisfied with (one
  scoped-down final change → clean review → merge the core) and **open a follow-up issue** for
  the contested remainder (logged, not lost). `needs-human` is **reserved** for when even the
  scoped-down core is contested, it's a genuine coder↔reviewer standoff, or it's a
  safety-rail / north-star decision — only then does the cap reach you. The cap **count** is
  unchanged; only how it resolves.
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
reviewer/manager-review.md Codex manager-reviewer mechanism (issue-as-bus): rounds + consensus / veto-only
scripts/install.sh         Generate the /faber command with a repo-derived path (idempotent)
scripts/codex-review.sh    Codex reviewer harness: post `codex exec review` to a PR, verbatim (stamps Reviewed-head: marker)
scripts/manager-review.sh  Codex manager-reviewer harness: debate a proposed issue vs. the north star, post the verdict to the issue verbatim
scripts/merge-pr.sh        Safe in-session merge harness: SHA-pin to reviewed head + repo-scope + required-checks gate + review-required refuse, then merge (repo-permitted method)
scripts/setup-target-repo.sh  Bootstrap a target repo's loop labels (idempotent)
scripts/lib/north-star.sh  Resolver: returns the active target repo's committed .fabrica/north-star.md (or root NORTH_STAR.md for a Fabrica-self run)
templates/faber-command.md Template for the /faber command (path placeholder)
templates/target-CLAUDE.md Drop into each target repo (conventions + PR-size rule)
templates/.fabrica/north-star.md  Template each target copies to .fabrica/north-star.md as its own committed north star
templates/repo-setup.md    Labels + branch protection checklist
NORTH_STAR.md              Fabrica-self's own target north star + done-signal + log — the resolver returns it only for a Fabrica-self run; other targets keep theirs in .fabrica/north-star.md
RESTORE.md                 Disaster-recovery runbook: rebuild the team from this repo
```

## Rollout

- **Phase 1** — prove the in-session loop on one seeded target repo. Front gate held the
  judgment; merge was manual while the loop earned trust.
- **Phase 2** — live: Faber **auto-merges clean, low-risk PRs in-session** (CI green +
  Codex clean, back-to-back with the review it just ran) under standing authorization —
  escalating only `needs-human`/round-cap, safety-rail changes, and north-star milestones /
  goal drift. Both the **brief** and a **status / Tracking pass** are **read-only — they
  surface `merge-ready` PRs, they never merge** (those get merged on a fresh in-session
  review, or by you).
- **Phase 3** — widen the auto-merge envelope as the loop proves out, including the
  **unattended status-scan / cross-repo auto-merge** — a future extension of `merge-pr.sh`
  **deferred to [#46](../../issues/46)** (the script's header notes it is not supported yet);
  always back-look high-risk work (auth, migrations, shared repos).
