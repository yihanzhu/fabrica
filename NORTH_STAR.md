# North star

The single goal the team is currently steering toward. Faber pushes *proactive* issues
toward this; the manager-reviewer ([`scripts/manager-review.sh`](scripts/manager-review.sh))
reads the **current** north star below and debates whether a proposed issue genuinely
serves it (see [`reviewer/manager-review.md`](reviewer/manager-review.md)).

**One north star is active at a time.** Faber updates this file on a north-star
transition: mark the achieved one `achieved` and promote (or add) the next as `active`.
Keep the log below so the human can see where the team has been.

---

## Current north star

### A — "Frictionless first-run"  ·  status: **active**

A new adopter can stand the team up from a fresh clone without getting stuck.

- **Done-signal:** `scripts/doctor.sh` exits `0` on a correctly set-up clone, **and** the
  `QUICKSTART.md` walkthrough is accurate end to end against a real fresh clone (every
  step does what it says, no missing prerequisite or dead pointer).
- **Why it's the north star:** the team is only *reusable by anyone* (a core Fabrica goal)
  if a stranger can reconstruct it from this repo. Until first-run is frictionless, every
  other improvement sits behind a setup wall.

---

## North-star log

A short history of north stars and consensus-filtered proposals, so the human can see the
trajectory and override anything consensus dropped.

- **A — "Frictionless first-run"** — *active.* Done-signal: `doctor.sh` exits 0 + an
  accurate fresh-clone `QUICKSTART.md` walkthrough.

### Vetoed-but-Faber-thought-relevant (manager-debate filtered these out)

When the manager-reviewer vetoes a proactive issue Faber believed was genuinely
north-star-relevant, Faber logs it here (default-drop, but surfaced) so the human can see
what consensus filtered out and override if they want. Empty until the first such case.

- _(none yet)_
