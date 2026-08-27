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

### B — "Pick up any project at any stage"  ·  status: **active** · <!-- ystack-shipped-default --> history: set + approved by the **operator** (2026-06-28). **Adopters:** this is ystack's goal, not yours — replace it with your own north star and explicitly approve *that* before proactive mode applies to your repo (and remove the `ystack-shipped-default` marker on this line when you do). This history line is **not** a token that auto-approves a clone.

ystack can adopt a project wherever it is and drive it toward the operator's goal — whether
that project is an empty folder or an existing codebase with history.

- **Two modes:**
  - **Empty (0→1):** the operator's first command *becomes* the first north star; ystack
    scaffolds the skeleton + a **real PR-CI gate (the operator confirms that initial gate)**
    + a first commit + a **committed `.ystack/north-star.md`** (yshifu drafts the exact
    north-star text + done-signal from the operator's command as part of the approved bootstrap
    plan; the bootstrap coder commits THAT text into the target), then runs the loop.
  - **Existing (1→N):** ystack **understands the whole project first** (structure, stack,
    conventions, current state), then pursues the operator's north star.
- **Done-signal:** from BOTH starting points — (a) an empty folder/repo, and (b) an existing
  repo with no prior ystack setup — a first `/yshifu` session drives one real change to a
  **merged, CI-gated PR** toward the operator's stated goal, with the CI gate present
  (**operator-approved when ystack bootstrapped it**) before any autonomous merge. On the
  empty (0→1) path the bootstrap PR also lands a **committed `.ystack/north-star.md`** (active
  non-placeholder entry, no `ystack-shipped-default` marker) so the 0→1 target ends with the
  committed north star the shipped gate (`manager-review.sh`) requires — a `doctor.sh`
  north-star WARN *before* that bootstrap PR lands is advisory in greenfield (like missing
  PR CI), not a blocker.
- **Why it's the north star:** the team is only *"pick up my work"* useful if it meets a
  project where it is, instead of requiring a pre-wired repo.
- **Safety note:** ystack's autonomy rests on CI + cross-vendor review; on an empty project
  neither exists yet, so the gate is bootstrapped **early and operator-approved**, and the
  human stays in the loop until a real gate exists.

---

## North-star log

A short history of north stars and consensus-filtered proposals, so the human can see the
trajectory and override anything consensus dropped.

- **B — "Pick up any project at any stage"** — *active; set + approved by the operator
  (2026-06-28) (history, not an inheritable token).* Done-signal: from both an empty
  folder/repo and an existing un-set-up repo, a first manager session reaches a merged,
  CI-gated PR toward the operator's goal — gate present + operator-approved-if-bootstrapped
  before any autonomous merge.
- **A — "Frictionless first-run"** — *superseded — folded into B.* Frictionless adoption of
  an existing repo is a subset of any-stage adoption. Substantially built out via #54–#82,
  but **not** independently proven on a real fresh clone, so folded into B rather than marked
  *achieved*. Original done-signal: `doctor.sh` exits 0 + an accurate fresh-clone
  `QUICKSTART.md` walkthrough.
- **C — "Numbers I can trust" (MapleFolio)** — *the team's **first real external run**; set +
  approved by the operator (2026-07-01, in an in-session manager chat); **achieved 2026-07-02**. Logged
  here as a completed external run — this repo's own active star stays B.* Goal: MapleFolio's
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
