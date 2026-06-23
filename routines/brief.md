# Brief instructions — daily resurfacing

These are the **brief instructions** Faber can run on demand to resurface what needs your
attention. It is **read-only** and **not currently auto-scheduled** — there is no cron
wired; Faber runs it when you ask (or you can wire a schedule yourself later).

```
Scan my repos and send me ONE short message, action-first:

- PRs approved + CI green, waiting on my merge (with links)
- Items labeled `needs-human` (round cap hit, ambiguous spec, oversized PR,
  coder failure) — say which and why
- Issues labeled `ready` with no PR yet (coder hasn't picked them up)
- Open issues idle > 7 days — name the likely next step (resurfacing)

Lead with what needs my action. Be brief. If nothing needs me, say "all clear"
in one line.
```
