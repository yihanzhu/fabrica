# Brief instructions — daily resurfacing

These are the **brief instructions** yshifu can run on demand to resurface what needs your
attention. It is **read-only** and **not currently auto-scheduled** — there is no cron
wired; yshifu runs it when you ask (or you can wire a schedule yourself later).

```
Scan my repos by LABEL (the labels are the state) and send me ONE short message,
action-first:

- PRs labeled `merge-ready` whose CI is now green (with links): this report is read-only —
  it surfaces state, it does not merge. Nothing else merges either: yshifu applies
  `merge-ready` once CI is green and the reviewer passed that exact head/base, then hands the PR to me.
  **I merge, always.** So report every one of these as **waiting on my merge**.
  Authenticate evidence exactly like `scripts/merge-pr.sh`: resolve the current `gh`
  operator, take the newest comment by that author with the exact Codex clean header,
  and parse both anchored 40-hex `Reviewed-head` / `Reviewed-base` lines from that same
  comment. Bare, cross-author, mixed, missing, or malformed evidence is **unknown/stale,
  not waiting on merge**. Also require parent-intake `ready|claimed|needs-human` absent
  and PR `claimed|needs-human` absent; otherwise it is paused/not waiting. Compare both with the current PR. If either changed, report it as
  **stale — not waiting on merge; the next active review-loop action must clear
  `merge-ready` and run a fresh review of the current head/base**. This brief remains
  read-only. Call out
  the ones that need my judgment on top of the review — high-risk (auth / migrations /
  shared repos / security-sensitive), safety-rail, or north-star
- Items labeled `needs-human` — the escalation comment's short reason says which
  (`plan-refresh` / `round-cap` / `ambiguous-spec` / `oversized` / `failure`); say which and why.
  `plan-refresh` may be waiting only for the recorded review gate; ask the user only
  when an operator merge/decision or a mismatch is actually pending.
  Skip anything I've already acted on: once resolved, `needs-human` is cleared, so
  never re-report a resolved item.
- Issues labeled `ready` (a direct label query) with both `claimed` and `needs-human`
  absent — intake plus
  the applicable artifact or named-bootstrap path and plan gate are all clear, but no
  PR has been picked up. If both labels are present, report an inconsistent paused state,
  never runnable; this brief remains read-only.
- Items labeled `claimed` — an active or unresolved coder pickup. Report the exact claim
  ID/tuple and whether its PR or pushed fix exists. Under the one-manager invariant,
  never spawn another coder until that manager reconciles and clears the claim. If two
  managers are detected, report `needs-human`; the label is not a cross-manager mutex.
- Open implementation PRs with exactly one `round-0..3`, none of
  `claimed|needs-human|merge-ready` on the PR, and parent-intake
  `ready|claimed|needs-human` absent — resumable
  review-loop handoff. With no current authenticated review, report fresh review as the
  next action. Otherwise require the complete raw review: pass resumes authenticated
  head/base+CI relabel/handoff for ordinary PRs, or human-only no-label handoff for a
  gate-creating bootstrap; not-pass needs diagnosis + a fix claim. This brief writes
  nothing. Missing/duplicate round is a paused failure.
- Issues labeled `debating` (a direct label query) — a proactive issue still mid
  manager-debate; if the session ended before consensus, flag it as **resumable** (the
  issue-as-bus thread holds the last verdict) — re-run `manager-review.sh` to continue, or drop it
- Open issues idle > 7 days — name the likely next step (resurfacing)

Lead with what needs my action. Be brief. If nothing needs me, say "all clear"
in one line.
```
