# North star

The single goal your team is steering toward. **This file is where your project's north
star will live** — at `.fabrica/north-star.md`, in your repo, owned by your repo (not
Fabrica's). It is the foundation for per-target steering: once per-target support is wired
in (issue #98), Fabrica's tooling begins reading your north star from here, so running
Fabrica against your repo debates proposals against *your* goal rather than a shared one.

**Status today: dormant.** Shipping this template is step one. No Fabrica script reads or
gates on this file yet — `scripts/setup-target-repo.sh`, `scripts/doctor.sh`, and the
proactive manager-debate (`scripts/manager-review.sh`) all still use Fabrica's control-plane
north star. That does not change until issue #98 wires the consumers to this resolver. So
filling this in now records your intended goal, but does not yet alter Fabrica's behavior.

**One north star is active at a time.** On a north-star transition, mark the achieved one
`achieved` and promote (or add) the next as `active`. Keep the log below so you can see where
the project has been.

**This is a placeholder — replace it.** The entry below is Fabrica's shipped default, carrying
the stable marker `<!-- fabrica-shipped-default -->`. **Write your own north star, then remove
that marker from the active heading line.** The marker exists so that, once #98 lands, Fabrica's
tooling can tell a still-default placeholder from a real, adopter-set north star without
re-hardcoding any phrase — but until then it drives no behavior. Keep the marker on the shipped
entry until you replace it.

**Approval will gate proactive autonomy (once #98 lands).** The active north star is intended to
be your authorization for proactive work: after the consumer switch, Faber may consensus-gate and
self-apply the `ready` label to a proactive issue **only when you have explicitly approved the
*active* north star**. Until you approve it, Faber will not auto-pursue — it asks you to set and
approve the north star first. (User-directed issues are unaffected — your approval of the spec
Faber drafts from your one-liner is its own gate. And none of this applies until #98 wires the
consumers to this file.)

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
