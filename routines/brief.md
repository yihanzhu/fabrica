# Brief instructions — daily resurfacing

These are the **brief instructions** Faber can run on demand to resurface what needs your
attention. It is **read-only** and **not currently auto-scheduled** — there is no cron
wired; Faber runs it when you ask (or you can wire a schedule yourself later).

```
Scan my repos by LABEL (the labels are the state) and send me ONE short message,
action-first:

- PRs labeled `merge-ready` whose CI is now green (with links): this report is read-only —
  it surfaces state, it does not merge. Report any low-risk ones as **awaiting merge** — they
  get merged when Faber reviews them **in-session** (auto-merge happens back-to-back with a
  review, not on a scan), or when I merge. (A status/Tracking pass is read-only too; neither
  the brief nor a scan auto-merges — that unattended path is deferred to #46.) `merge-ready`
  means the reviewed head passed, so if a PR's head changed after the label was applied, flag
  it as **stale — needs a fresh Codex review of the current head**. Call out the ones held
  for me — high-risk (auth / migrations / shared repos / security-sensitive), safety-rail, or
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
