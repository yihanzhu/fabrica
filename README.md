# ystack

A small autonomous coding team. **yshifu** (the manager) runs the shop in a Claude Code
session: you approve specs, and yshifu spawns a Claude coder subagent to build and runs a
Codex reviewer to review.

Claude Code + Codex + GitHub are the **current default profile**, not product
requirements. The portable target architecture and rollout live in
[`ROADMAP.md`](ROADMAP.md).

This repo is the **control plane** — it defines *how the team works*. Target product
code normally lives in separate repos; ystack is intentionally its own target when
the team is improving the control plane itself.

**ystack** — Yihan's stack for the AI-native SDLC: an autonomous coding team, gated by human judgment.

**Get started →** [QUICKSTART.md](QUICKSTART.md) · **Direction →** [ROADMAP.md](ROADMAP.md)

## Current status

- **Live today:** yshifu drives the GitHub issue/label loop in one Claude Code
  session. The coder opens PRs, Codex reviews, CI runs, and the operator merges.
- **Landed v2 foundation:** the hash-linked `work/<slug>/` chain runs by hand;
  the no-merge guard is active, and the lane helpers are diagnostic only.
- **Paused:** the event-driven stage workflows from draft PR #146 are not on
  `main` and must not be described or restored as live.
- **Next:** the portable core and adapter rollout in [`ROADMAP.md`](ROADMAP.md).

## The current default team

You talk **only** to yshifu, in a Claude Code session. yshifu orchestrates the other roles
within that session — spawning the coder and running the reviewer — so there is no
separate human channel to the workers. The manager debate uses an issue thread; code
review uses a PR thread.

| Agent | Vendor | How it runs | Writes? |
|-------|--------|-------------|---------|
| **yshifu** (manager) | Claude | You talk to it in a Claude Code chat (`manager/CLAUDE.md`) | issues only; never authors code/PRs; **never merges** (labels `merge-ready`, hands the PR to you) |
| **Coder** | Claude | A subagent yshifu spawns with the issue/PR context — two modes: build (`routines/coder.md`) then fix (`routines/coder-revision.md`) | yes (branches, PRs) |
| **Manager-reviewer** | Codex (OpenAI) | yshifu runs `scripts/manager-review.sh` at the **direction altitude** — debates whether a proactive issue serves the north star → PROCEED/REFINE/DROP | **veto only / read-only** (never labels or merges) |
| **Code-reviewer** | Codex (OpenAI) | yshifu runs `scripts/codex-review.sh` at **code altitude, after coding** — against the PR diff | **comments only / read-only** |

## The current in-session loop

The loop is **in-session**: yshifu drives every step from one Claude Code chat. There is
exactly one coder launch per cleared issue, one review path, and one revision path.
Here, “spec” means the current profile's GitHub issue spec, not the v2
`work/<slug>/spec.md` artifact.

```
  one-liner → yshifu drafts spec → opens issue
                                       │
        gate (front gate = at the north-star altitude):
          • user-directed issue → your one-liner is the request → yshifu drafts
              the spec → YOU approve that drafted spec → yshifu labels it `ready`
              (drafting alone never earns `ready`)
          • proactive issue → yshifu⇄Codex manager-debate CONSENSUS
              → yshifu removes `debating`, labels it `ready` (no per-issue ask)
          (yshifu alone never self-approves; the consensus IS the gate
           for proactive north-star work — see manager-review.md)
                                       ↓
              yshifu spawns [Coder] subagent  → opens PR (label round-0)
                                       ↓
              yshifu runs scripts/codex-review.sh  → Codex posts comments only
                                       ↓
              yshifu spawns [Coder, fix mode]  adopt reasonable / push back
                                       │              (bump round-N)
                          ┌── round < 3 ┘
                          ↺  yshifu re-runs codex-review.sh
                          └── round = 3 (cap) → SCOPE DOWN + FOLLOW-UP (productive):
                                 land the converged core (one scoped-down change →
                                 clean review → `merge-ready` → YOU merge) + open a
                                 follow-up issue for the contested remainder; only a
                                 genuine standoff / safety-rail / north-star →
                                 label `needs-human` → pings YOU
                                       ↓
              CI green + Codex clean at that head → yshifu labels the PR `merge-ready`
                 and hands it to YOU → YOU merge (yshifu never merges; a status scan
                 or brief only reports). New commits void `merge-ready` — re-review first.
                 (high-risk / escalations / rail changes / north-star → named at handoff)
```

## Design decisions (the "why")

- **Responsibilities are stable; adapters are replaceable.** Add a role only for a
  distinct *job + trigger + tool surface* — not per discipline. The current profile
  maps those responsibilities to Claude and Codex.
- **Cross-vendor review is a preference, not a requirement.** The requirement is an
  independent reviewer identity, context, and permission boundary. A different vendor
  is the preferred default because it can reduce common blind spots.
- **Reviewer is read-only, comments only, never the author.** Non-negotiable.
- **Judgment lives at the direction (front gate at the north-star altitude), not the diff.**
  You approve the **north star** — each target repo's own committed
  [`.ystack/north-star.md`](templates/.ystack/north-star.md) (when the target *is* this
  control-plane repo, that file is the root [`NORTH_STAR.md`](NORTH_STAR.md) — ystack is its
  own target) — and yshifu pursues it
  autonomously — you stop reading diffs line by line (you still merge every PR, but on the
  strength of `merge-ready`), and for **proactive** work you stop approving each issue.
  Two paths clear an issue to run: a **user-directed** issue where your one-liner is the
  *request* — yshifu drafts the spec, **you still approve that drafted spec**, and *that approval*
  is the gate yshifu records with `ready` (drafting alone does not earn `ready`; user-directed
  issues are *not* exempt from per-spec approval);
  a **proactive** issue on **yshifu⇄Codex manager-debate consensus** — on consensus yshifu
  removes `debating` and applies `ready` itself, no per-issue ask (this is the only path with no
  per-issue approval, and it is conditional on your having explicitly approved the active north
  star). **yshifu acting alone never self-approves**; for proactive north-star work the
  cross-vendor consensus *is* the gate (see
  [`reviewer/manager-review.md`](reviewer/manager-review.md)). For *proactive* work you are
  pulled back in only at the north-star altitude: **north-star achieved**, **goal drift /
  transition**, and `needs-human` escalations — user-directed issues still come to you for the
  drafted-spec approval. The accepted roadmap adds a risk-tiered plan gate after intake:
  high-risk proactive or user-directed work will return to you for plan approval before
  code. That gate is not wired into the current manager yet; `ready` must not be described
  as plan approval.
- **CI is the hard gate** — ground truth. Autonomy rests on tests first, diverse
  reviewer second.
- **yshifu never merges — it labels, then hands you the PR.** Merging is the operator's,
  always. `main`'s branch ruleset requires a pull request plus **one approving review**, the
  Codex reviewer is **comments-only and never approves**, and **no agent has a bypass** — so
  there is no agent merge path at all. What yshifu does instead: when a PR's **current head**
  is CI-green **and** the reviewer passed **that same head**, yshifu applies **`merge-ready`** —
  a label that means only *"this head passed Codex review"* — and hands the PR to you, naming
  anything you should weigh. **You merge.** `merge-ready` is **void the moment new commits
  land**: GitHub keeps the label across a head change, so yshifu clears it, re-runs
  `codex-review.sh` on the new head, and re-applies it only on a fresh pass — a stale label is a
  false green. A later **status/Tracking scan and the brief only surface `merge-ready` PRs
  (read-only)** — they never merge either. High-risk PRs are handed over **with the risk named**
  even when CI-green and Codex-clean (auth, DB/schema migrations, shared/production repos,
  security-sensitive or other operator-judgment changes); `merge-ready` records a clean review,
  it never means "merge without looking." **Gate-creating bootstrap PRs get no `merge-ready` at
  all** — an "add PR CI" PR or a greenfield 0→1 scaffold *creates* the gate, so no real gate yet
  exists to certify it, and the new workflow can self-report green on its own PR; you approve and
  merge those by hand. You're also brought in for `needs-human`/round-cap escalations,
  safety-rail changes, and **north-star milestones / goal drift**. **`scripts/merge-pr.sh` stays
  in the repo for your own use** — it reads the reviewed head+base SHAs from the authenticated
  `codex-review.sh` marker and refuses if either moved, gates on the base branch's **required
  status checks** (falling back to ≥1 real passing CI check with none failing when none are
  defined — optional checks like preview deploys are informational), refuses a PR that still
  needs an **approving review** (`reviewDecision=REVIEW_REQUIRED`), stays **scoped to the target
  repo**, and merges with a **repo-permitted method** (squash if allowed) **pinned via
  `--match-head-commit`**. **yshifu never runs it, on any PR.**
- **One rounds counter (~3), and the cap is productive.** Comments resolved or disagreement
  burned both count; a single push-back doesn't escalate. At the ~3-round cap yshifu **scopes
  down + splits** rather than dead-ending: land the part the reviewer is satisfied with (one
  scoped-down final change → clean review → `merge-ready` → you merge the core) and **open a
  follow-up issue** for the contested remainder (logged, not lost). `needs-human` is **reserved** for when even the
  scoped-down core is contested, it's a genuine coder↔reviewer standoff, or it's a
  safety-rail / north-star decision — only then does the cap reach you. The cap **count** is
  unchanged; only how it resolves.
- **The current profile projects state into labels, not memory.** Each coder is a fresh
  subagent, so `round-0..3`, `needs-human`, and `merge-ready` currently survive in forge
  labels. The portable core moves canonical stage, retry, stale, and decision state into
  durable records; labels remain a UI projection rather than a second state machine.
- **Runs on the plan** in an ordinary Claude Code session (Claude coder subagents) plus
  Codex's built-in review via `scripts/codex-review.sh` — compliant ordinary use, metered.
  Prototype on personal repos; apply terms diligence before any work/shared repo.

> **Event-driven autonomous write is paused for re-planning.** The artifact spine is useful, but draft
> PR #146 bound the lane to one harness/forge and exposed missing credential, eval, and
> reconciliation controls. It must not merge. The portable core and control foundation in
> [`ROADMAP.md`](ROADMAP.md) come before any autonomous write is enabled.

## Model policy

**Spend by leverage, not by volume.** A run touches far more producer tokens (the
coder writing code) than gate tokens (a reviewer judging a diff), so naively giving
everything the same model either overspends on volume or underspends on judgment.
ystack instead routes by the *leverage* of the decision, not by how much text it
produces:

- **Gates decide → always max.** The code-review gate (`scripts/codex-review.sh`)
  and the manager-debate gate (`scripts/manager-review.sh`) run at maximum
  reasoning effort, always — there is no per-task/class routing that would lower
  them. A bad gate call (approving a broken PR, debating a proposal against the
  wrong bar) is expensive to unwind later, so gates never get a cheaper tier.
- **Producers type → fixed ceilings.** The coder subagent and "hands" work
  (mechanical, low-judgment steps) run at a fixed model ceiling, set once and never
  escalated at runtime — not even when a task looks hard. A task that seems to need
  a bigger model is a signal to **decompose the task or fix the spec upstream**,
  not to reach for more horsepower mid-run. Producer volume is what makes cost add
  up, so this is where the fixed ceiling lives.
- **Frontier thinks, never types.** The most capable models are reserved for
  judgment (gates), not generation (producers) — the opposite of routing by output
  volume.

**Config: `config/models.conf`.** Shell-sourceable (POSIX `KEY=value`, no bashisms)
shipped defaults, read by any script here via `. config/models.conf`:

| Key | Default | Meaning |
|-----|---------|---------|
| `YSTACK_CODER_MODEL` | `sonnet` | Claude coder subagent model. A floating alias tracks that alias's latest release; a full model ID pins an exact snapshot. Fixed ceiling by design — never escalated at runtime. |
| `YSTACK_HANDS_MODEL` | `haiku` | Model for mechanical "hands" work. Same never-escalated principle, cheaper ceiling. |
| `YSTACK_CODEX_MODEL` | *(empty)* | Codex model for the review/debate gates. Empty means inherit the operator's Codex CLI / `~/.codex/config.toml` default (whatever frontier codex that resolves to). Set only to pin a specific model — gates are never downgraded by task class. |
| `YSTACK_REVIEW_EFFORT` | `high` | Reasoning effort for the code-review gate. Always max. |
| `YSTACK_DEBATE_EFFORT` | `high` | Reasoning effort for the manager-debate gate. Always max. |

**Per-target override.** A target repo may commit its own `.ystack/models.conf`
(same format, same keys — copy it from
[`templates/.ystack/models.conf`](templates/.ystack/models.conf)) to override the
**producer/model keys only** (`YSTACK_CODER_MODEL`, `YSTACK_HANDS_MODEL`,
`YSTACK_CODEX_MODEL`) for that repo — **`YSTACK_REVIEW_EFFORT` /
`YSTACK_DEBATE_EFFORT` are never target-overridable**; a target can never lower or
otherwise change its own review/debate gate. This mirrors where the north star lives
(a target's own `.ystack/` directory — see
[`templates/.ystack/north-star.md`](templates/.ystack/north-star.md) and the
"Judgment lives at the direction" design decision above), so both kinds of
per-target committed state — the goal and the model policy — live in the same
place, owned by the target repo, not the ystack control-plane clone. The
review/debate gates (`scripts/codex-review.sh` / `scripts/manager-review.sh`) apply
it **after** the shipped defaults, so it only needs to set the keys it wants to
change, and it is a **static per-repo commitment** — set once and committed, never a
per-task rescue. Because it is target-committed content, the gates **parse it as
data** (`scripts/lib/models-conf.sh`) — never `source`/`.`/`eval` it — and
`codex-review.sh` reads it from the repo's gh-bound default branch (fetched fresh),
never the untrusted PR head under review. `scripts/doctor.sh` check (k) validates the
shipped defaults (`config/models.conf` present, sourceable, coder/hands values
non-empty) and check (l) warns if `CLAUDE_CODE_SUBAGENT_MODEL` is set in the
environment (it would silently override a per-spawn model argument).

**Wiring status: foundation + gates + coder spawn + hands all wired.** The review
and manager-debate **gates** (`scripts/codex-review.sh` / `scripts/manager-review.sh`)
already read `config/models.conf` (and a target's `.ystack/models.conf` override) to
resolve the Codex model + reasoning effort for every run. The **coder spawn** reads
this config too ([#111](../../issues/111)): yshifu's own instructions
(`manager/CLAUDE.md` / `templates/yshifu-command.md`) read `config/models.conf`, then a
target's committed `.ystack/models.conf` override if present, before every coder spawn
(round-0 or fix-mode), and pass the resolved `YSTACK_CODER_MODEL` as an explicit
`model` parameter — a fixed ceiling, never escalated at runtime, including on a bounced
review round (see the bounce protocol in `manager/CLAUDE.md`, which replaces any notion
of mid-round model escalation). The **hands-work ceiling** (`YSTACK_HANDS_MODEL`) is
now wired too ([#112](../../issues/112)): yshifu's instructions describe a delegation
policy — context-heavy reads and multi-step polling (watching CI to completion, PR-diff
summaries, review-thread collection, bulk `gh` queries) go to a `YSTACK_HANDS_MODEL`
subagent via the same config-resolution mechanism, passed as the spawn's `model`
parameter, while single quick writes (one comment, one label, one short handoff note) stay
inline; hands agents must return key raw lines plus a summary, never a bare conclusion,
so yshifu's decisions rest on evidence. This is a **prompt-level** wiring: it takes
effect once `scripts/install.sh` regenerates the live `/yshifu` command, not merely by
merging the doc change — `doctor.sh`'s static validation is unaffected.

## Layout

```
QUICKSTART.md              The ~10-min golden path: stand the team up from scratch
ROADMAP.md                 Portable architecture, control objectives, and rollout order
CLAUDE.md                  Repo conventions + self-modification safety rails (vs manager/CLAUDE.md = yshifu's persona)
manager/CLAUDE.md          yshifu's persistent role (paste into Claude Code)
routines/coder.md          Coder baseline instructions yshifu passes to a spawned coder subagent
routines/coder-revision.md Coder fix-mode instructions (handle review feedback)
routines/brief.md          Brief instructions yshifu can run (resurfacing; not auto-scheduled)
reviewer/codex-review.md   Codex reviewer mechanism + in-session review loop
reviewer/manager-review.md Codex manager-reviewer mechanism (issue-as-bus): rounds + consensus / veto-only
scripts/install.sh         Generate the /yshifu command with a repo-derived path (idempotent)
scripts/codex-review.sh    Codex reviewer harness: post `codex exec review` to a PR, verbatim (stamps Reviewed-head: marker)
scripts/manager-review.sh  Codex manager-reviewer harness: debate a proposed issue vs. the north star, post the verdict to the issue verbatim
scripts/merge-pr.sh        Safe merge harness for the OPERATOR's own use (yshifu never runs it): SHA-pin to reviewed head + repo-scope + required-checks gate + review-required refuse, then merge (repo-permitted method)
scripts/setup-target-repo.sh  Bootstrap a target repo's loop labels (idempotent)
scripts/lib/north-star.sh  Resolver: returns the active target repo's committed .ystack/north-star.md (or root NORTH_STAR.md when ystack itself is the target)
scripts/doctor.sh          Read-only restore + readiness self-check (install, auth, restore-critical files, north star, model config, ...)
config/models.conf         Shipped model-tiering defaults (coder/hands ceilings, gate models/effort) — see "Model policy" below
templates/yshifu-command.md Template for the /yshifu command (path placeholder)
templates/target-CLAUDE.md Drop into each target repo (conventions + PR-size rule)
templates/.ystack/north-star.md  Template each target copies to .ystack/north-star.md as its own committed north star
templates/.ystack/models.conf  Template each target may copy to .ystack/models.conf to override specific model-tiering keys
templates/repo-setup.md    Labels + branch protection checklist
NORTH_STAR.md              This repo's own target north star + done-signal + log — the resolver returns it only when ystack itself is the target; other targets keep theirs in .ystack/north-star.md
RESTORE.md                 Disaster-recovery runbook: rebuild the team from this repo
```

## Direction

- **Today** — the loop runs end to end in-session, and **you merge at the gate**.
  yshifu labels a PR **`merge-ready`** when its current head is CI-green and the reviewer
  passed that same head, then hands the PR to you — naming the risk on high-risk work, and
  escalating `needs-human`/round-cap, safety-rail changes, and north-star milestones / goal
  drift. Both the **brief** and a **status / Tracking pass** are **read-only — they surface
  `merge-ready` PRs, they never merge**. No agent merges: `main` needs a pull request plus an
  approving review the comments-only reviewer cannot give, and no agent has a bypass.
- **Next** — migrate the current profile behind portable adapters, establish the
  control/eval/reconciliation foundation, then qualify and enable one bounded
  workflow scope at a time in each execution environment.
  [`ROADMAP.md`](ROADMAP.md) is authoritative. **The merge gate does not widen**:
  the operator remains the only merge authority.
