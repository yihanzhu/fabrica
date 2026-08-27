# North star

The single goal the team is currently steering toward. yshifu pushes *proactive* issues
toward this; the manager-reviewer ([`scripts/manager-review.sh`](scripts/manager-review.sh))
reads the **current** north star below and debates whether a proposed issue genuinely
serves it (see [`reviewer/manager-review.md`](reviewer/manager-review.md)).

**One north star is active at a time.** yshifu updates this file on a north-star
transition: mark the achieved one `achieved` and promote (or add) the next as `active`.
Keep the log below so the human can see where the team has been.

**Shipped-default marker.** The active entry below carries a stable marker —
`<!-- ystack-shipped-default -->` — meaning *"this is ystack's own shipped default
direction, not the adopter's."* `scripts/doctor.sh` check (h) greps for this marker (not
for any north-star phrase) to warn that the shipped default is still in place, so
detection never has to be re-hardcoded per transition. (The check also still counts the legacy `fabrica-shipped-default` marker, so targets on the old name keep working.)
Two rules keep it accurate:
- **Adopters remove this marker** when they set (and approve) their own north star. Once
  it's gone, doctor stops warning — the active star is genuinely theirs.
- **On an internal north-star transition in this repo, carry the marker onto the new
  shipped/active default entry** (and strip it from the one being retired). It always sits
  on exactly the one entry that is ystack's own shipped default, so doctor's marker-based
  detection keeps working without any code edit.

**Approval gates proactive autonomy.** The active north star is the user's authorization for
*all* proactive work: yshifu may consensus-gate and self-apply `ready` to a proactive issue
**only when the operator has explicitly approved the *active* north star** (yshifu knows this
from the operator, not from a line in this file). Until the operator approves it, yshifu does
**not** auto-pursue — it asks them to set and approve the north star first. The approval notes
below are **descriptive owner-history**, not a machine token: a fresh clone inheriting them is
**not** auto-approved for a new operator. The shipped entry below is **ystack's own** direction;
an **adopter must replace it with their own north star and explicitly approve that** before
proactive autonomous mode applies to their repo. (User-directed issues are unaffected — the
user's approval of the spec yshifu drafts from their one-liner is its own gate.)

---

## Current north star

### D — "Any harness, any Git forge, one governed loop" · status: **active** · <!-- ystack-shipped-default --> history: set + approved by the **operator** (2026-08-27). **Adopters:** this is ystack's goal, not yours — replace it with your own north star and explicitly approve *that* before proactive mode applies to your repo (and remove the `ystack-shipped-default` marker on this line when you do). This history line is **not** a token that auto-approves a clone.

ystack is a harness-neutral and forge-neutral control plane for an AI-native
software-delivery loop. It can meet a Git project at any stage, then run the same
versioned artifacts, risk gates, verification, review, and human authorization through
replaceable adapters.

- **Portable core:** intent, spec, accepted plan, evidence, review, incident records,
  state, policies, evals, and gates do not require Claude, Codex, GitHub, or another
  named vendor. Git is the first canonical artifact protocol; GitHub, GitLab, and
  Bitbucket are forge adapters.
- **Preference profiles:** the first profile may prefer Claude Code as producer, Codex
  as reviewer, and GitHub Actions as CI. A profile selects these implementations; it
  cannot weaken separation of duties, deterministic proof, human merge, or production
  gates.
- **Any-stage adoption remains required:** greenfield bootstrap establishes a real,
  operator-approved CI/merge gate before autonomous 1→N work. An existing project is
  understood before change. Both paths commit the target's own approved north star.
  ystack is its own first dogfood target, but an unrelated external target is required
  to prove the core did not special-case itself.
- **Complete loop:** work moves through
  `intent → spec → accepted plan → build → verify → independent review → human merge →
  deploy/rollback → production feedback/new intent`. Events only wake the loop; durable
  reconciliation reads canonical state and repairs missed work.
- **Done-signal:** the same canonical contracts and gates complete a real target change
  under the default profile, while at least one alternative harness and one alternative
  forge pass the adapter contract and smoke path. No core rule or artifact requires a
  Claude, Codex, or GitHub-specific command, event, secret, model, or file layout. A real
  target then completes the full loop through a rehearsed rollback or production signal
  that creates a new intent and permanent eval.
- **Why it's the north star:** faster code generation is useful only when the whole system
  stays portable, recoverable, measurable, and governed. The durable product is the
  control plane and its contracts, not one vendor harness.
- **Safety note:** the operator remains the merge and production authority. High-risk work
  receives plan approval before code. Model-controlled commands and candidate code cannot
  read model, forge, or deployment credentials; inference and external writes cross a
  brokered boundary. No adapter may downgrade the core gates.

---

## North-star log

A short history of north stars and consensus-filtered proposals, so the human can see the
trajectory and override anything consensus dropped.

- **D — "Any harness, any Git forge, one governed loop"** — *active; set + approved by
  the operator (2026-08-27) (history, not an inheritable token).* Done-signal: a portable
  core runs the governed artifact-to-production-feedback loop under the default profile,
  with alternative harness and forge adapters proving the same contracts and gates.
- **B — "Pick up any project at any stage"** — *superseded — folded into D.* Any-stage
  greenfield and existing-project adoption remains a requirement of the portable loop.
  B was substantially built but not independently proven on a real fresh clone, so it is
  folded forward rather than marked achieved. Original done-signal: from both starting
  points, a first manager session reaches a merged, CI-gated PR toward the operator's
  goal, with an operator-approved gate established before autonomous work.
- **A — "Frictionless first-run"** — *superseded — folded into B.* Frictionless adoption of
  an existing repo is a subset of any-stage adoption. Substantially built out via #54–#82,
  but **not** independently proven on a real fresh clone, so folded into B rather than marked
  *achieved*. Original done-signal: `doctor.sh` exits 0 + an accurate fresh-clone
  `QUICKSTART.md` walkthrough.
- **C — "Numbers I can trust" (MapleFolio)** — *the team's **first real external run**; set +
  approved by the operator (2026-07-01, in an in-session manager chat); **achieved 2026-07-02**. Logged
  here as a completed external run — this repo's own active star stays D.* Goal: MapleFolio's
  Canadian room/cash/FX calculation engine verified by an automated test suite run as the hard
  CI gate, so real-money contribution decisions rest on correct math. This run motivated the
  **per-target north-star architecture** (#97 resolver, #98/98a atomic flip, 98b adoption) — a
  target's goal must live in the target's `.ystack/north-star.md`, not the control plane's
  own file.

### Vetoed-but-manager-thought-relevant (manager-debate filtered these out)

When the manager-reviewer vetoes a proactive issue yshifu believed was genuinely
north-star-relevant, yshifu logs it here (default-drop, but surfaced) so the human can see
what consensus filtered out and override if they want. Empty until the first such case.

- _(none yet)_
