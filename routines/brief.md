# Brief instructions — daily resurfacing

These are the **brief instructions** Faber can run on demand to resurface what needs your
attention. It is **read-only** and **not currently auto-scheduled** — there is no cron
wired; Faber runs it when you ask (or you can wire a schedule yourself later).

```
Scan my repos by LABEL (the labels are the state) and send me ONE short message,
action-first:

- PRs labeled `merge-ready` whose CI is now green (with links): this report is read-only —
  it surfaces state, it does not merge. Report any low-risk ones as **auto-merge-eligible**
  (Faber merges these on a status/Tracking pass — CI may have gone green after the loop
  ended, so they're picked up there, not here), and call out the ones held for me —
  high-risk (auth / migrations / shared repos / security-sensitive), safety-rail, or
  north-star — as waiting on my merge gate
- Items labeled `needs-human` — the escalation comment's short reason says which
  (`round-cap` / `ambiguous-spec` / `oversized` / `failure`); say which and why.
  Skip anything I've already acted on: once resolved, `needs-human` is cleared, so
  never re-report a resolved item.
- Issues labeled `ready` (a direct label query) — approved but no PR picked up yet
- Open issues idle > 7 days — name the likely next step (resurfacing)

Lead with what needs my action. Be brief. If nothing needs me, say "all clear"
in one line.
```
