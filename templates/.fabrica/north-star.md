# North star

The single goal your team is currently steering toward. This file is where your project's
north star lives, and Fabrica's setup/doctor tooling (`scripts/setup-target-repo.sh`,
`scripts/doctor.sh`) reads it here. The proactive manager-debate
(`scripts/manager-review.sh`) adopts this file as its source once the source switch lands
(issue #98); until then it still debates proposals against the control-plane north star.

**This file lives in your repo, at `.fabrica/north-star.md`.** It is *your* project's
steering, owned by your repo — not Fabrica's. Each target repo carries its own north star
here, so running Fabrica against your repo debates proposals against *your* goal.

**One north star is active at a time.** On a north-star transition, mark the achieved one
`achieved` and promote (or add) the next as `active`. Keep the log below so you can see where
the project has been.

**This is a placeholder — replace it.** The entry below is Fabrica's shipped default, carrying
the marker `<!-- fabrica-shipped-default -->`. While that marker is present, `scripts/doctor.sh`
WARNs that the north star is still the shipped default. **Write your own north star, then remove
the marker from the active heading line** — the warning clears, and once the manager-debate
adopts this file (issue #98) proactive autonomy applies to your repo.

**Approval gates proactive autonomy.** The active north star is your authorization for *all*
proactive work: Faber may consensus-gate and self-apply the `ready` label to a proactive issue
**only when you have explicitly approved the *active* north star**. Until you approve it, Faber
does **not** auto-pursue — it asks you to set and approve the north star first. (User-directed
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
