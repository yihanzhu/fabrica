# North star

The single goal your team is steering toward. **This file is where your project's north
star lives** — at `.fabrica/north-star.md`, in your repo, owned by your repo (not Fabrica's).
It is the foundation for per-target steering: Fabrica's tooling reads your north star from
here, so running Fabrica against your repo debates proposals against *your* goal rather than
a shared one.

**Fabrica's tooling uses this file.** You create it yourself: copy this shipped template into
your repo as `.fabrica/north-star.md`, replace the placeholder, remove the
`<!-- fabrica-shipped-default -->` marker, then commit it (`scripts/setup-target-repo.sh` only
creates the loop labels — it does **not** seed this file). Once it exists, `scripts/doctor.sh`
check (h) reports whether it is set (and not still the shipped default), and the proactive
manager-debate (`scripts/manager-review.sh`) reads its **committed** content as the gate a
proactive issue is debated against. The gate reads the **committed** file (pinned to the commit
the review runs on) — an uncommitted local edit does **not** authorize proactive work, so
**commit your north star** after you set it.

**One north star is active at a time.** On a north-star transition, mark the achieved one
`achieved` and promote (or add) the next as `active`. Keep the log below so you can see where
the project has been.

**This is a placeholder — replace it.** The entry below is Fabrica's shipped default, carrying
the stable marker `<!-- fabrica-shipped-default -->`. **Write your own north star, then remove
that marker from the active heading line, and commit the file.** The marker lets Fabrica's
tooling tell a still-default placeholder from a real, adopter-set north star without re-hardcoding
any phrase: while the marker is present, `manager-review.sh` treats this as an un-replaced
placeholder and FAILs the gate (it will not debate against a template), and `doctor.sh` warns.
Keep the marker on the shipped entry until you replace it.

**Approval gates proactive autonomy.** The active north star is your authorization for proactive
work: Faber may consensus-gate and self-apply the `ready` label to a proactive issue **only when
you have explicitly approved the *active* north star** (approve it *to Faber in-session* — an
in-file note is the prior owner's history, not your go). Until you set + commit + approve it,
Faber will not auto-pursue — it asks you to set and approve the north star first. (User-directed
issues are unaffected — your approval of the spec Faber drafts from your one-liner is its own
gate.)

---

## Current north star

### Placeholder — replace with your own goal  ·  status: **active** · <!-- fabrica-shipped-default --> shipped default: this is a placeholder, not your project's goal — write your own north star below and remove the `fabrica-shipped-default` marker on this line when you do.

Describe, in a sentence or two, the single outcome your project is steering toward right now.
A good north star is concrete enough that the manager-reviewer can judge whether a proposed
issue genuinely serves it, and has a clear done-signal.

- **Why it's the north star:** why this is the one thing worth steering toward now.
- **Done-signal:** the observable condition that means this north star is achieved.
- **Safety note (optional):** any guardrail the team must respect while pursuing it.

---

## North-star log

A short history of north stars, so you can see the project's trajectory and override anything
consensus dropped.

- **Placeholder** — *active; replace with your own north star (and remove the shipped-default
  marker on the active heading above).*

### Vetoed-but-Faber-thought-relevant (manager-debate filtered these out)

When the manager-reviewer vetoes a proactive issue Faber believed was genuinely
north-star-relevant, Faber logs it here (default-drop, but surfaced) so you can see what
consensus filtered out and override if you want. Empty until the first such case.

- _(none yet)_
