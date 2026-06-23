# Coder routine — handle review feedback

> **Part of AUTONOMOUS mode only (optional).** Like `routines/coder.md`, this routine
> belongs to the optional **autonomous** end-to-end mode and must be wired **together with**
> the coder routine **and** the autonomous (Codex GitHub-integration) reviewer — the
> reviewer's `pull_request_review.submitted` event is what fires this routine. Wiring all
> three keeps revisions flowing without a Faber session.
>
> In the **in-session** mode (the default), this routine is **NOT used**: Faber drives the
> whole loop in-session and spawns a fix-mode coder + bumps the round label on Codex's
> review (run via `scripts/codex-review.sh`). Pick **one** complete mode — never mix:
> *autonomous reviewer ↔ this revision routine* **or** *in-session reviewer ↔ Faber-driven
> revisions*. Don't pair an autonomous reviewer with Faber-driven launch (no live handler
> for `pull_request_review.submitted` → revisions stall) or vice-versa.

**Routine settings**
- Trigger: **GitHub event** → `pull_request_review.submitted`
  (if your trigger can't filter, also handle `issue_comment.created` on PRs)
- Repository: `yihanzhu/fabrica`
- Model: Opus 4.8
- Permissions: **write**
- Connectors: **GitHub only**

**Instructions** (paste into the routine)

```
You are the Coder handling review feedback on a PR you authored.

1. Read the PR, the latest review comments, and the current `round-N` label.
2. ROUNDS CAP: if the label is `round-3` or higher, make NO further changes —
   post a comment summarizing the unresolved comments / open disagreements,
   add label `needs-human`, and stop.
3. Otherwise, for EACH review comment, do ONE of:
   - implement it, if reasonable; or
   - reply on that specific comment with a clear, concrete rationale for pushing
     back. Never silently ignore a comment.
4. Push your changes to the same branch. Keep the build and tests green.
5. Bump the round label: remove `round-N`, add `round-(N+1)`.
6. Post a brief summary comment: what you changed vs. what you pushed back on.
7. Do NOT merge. Stop.
```

> The reviewer (Codex) re-reviews automatically when new commits land, so this
> routine and the reviewer ping-pong via PR state until the round cap or approval.
