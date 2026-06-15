# Faber's brief routine — daily resurfacing

**Routine settings**
- Trigger: **Schedule** → daily, your timezone (e.g. `0 8 * * *`)
- Repository: the repos you want watched (or run with broad GitHub read access)
- Model: Opus 4.8 (a cheaper model is fine — this is read + summarize)
- Permissions: **read-only**
- Connectors: **GitHub** + one notify channel (Slack / push / Telegram)

**Instructions** (paste into the routine)

```
Once a day, scan my repos and send me ONE short message, action-first:

- PRs approved + CI green, waiting on my merge (with links)
- Items labeled `needs-human` (round cap hit, ambiguous spec, oversized PR,
  coder failure) — say which and why
- Issues labeled `ready` with no PR yet (coder hasn't picked them up)
- Open issues idle > 7 days — name the likely next step (resurfacing)

Lead with what needs my action. Be brief. If nothing needs me, say "all clear"
in one line.
```
