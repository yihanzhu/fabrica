# Target repo setup checklist

Do this once per target repo before pointing the team at it.

## 1. Labels
Create these labels (the loop uses them as its state — the state lives in labels, not agent
memory):
- `ready` — the record of your approval. Faber applies it after you approve. In **in-session
  mode** (default) it is Faber's cue to spawn the coder; in **autonomous mode** it fires the
  `issues.labeled` coder routine. Exactly one coder launch per approved issue, never both.
- `round-0`, `round-1`, `round-2`, `round-3` — review-loop counter
- `needs-human` — escalation: round cap hit, ambiguous spec, oversized PR, or failure

```bash
scripts/setup-target-repo.sh <owner>/<repo>
```

This is idempotent — safe to re-run. The labels are the loop's shared state in **both**
modes. It only creates labels; the steps below (and the mode choice in step 5) are manual —
the script prints the same reminders.

## 2. Branch protection (main)
- ✅ Require status checks to pass before merging (your CI) — the **hard gate**
- ✅ Require branches to be up to date before merging
- ⛔️ **Phase 1: no auto-merge** — you merge manually after CI is green
- (Phase 3, once trusted) enable auto-merge for low-risk PRs only

## 3. CI
- A workflow that runs tests + lint/typecheck on every PR. Without real tests, the
  hard gate is hollow — invest here first.

## 4. Conventions
- Add `CLAUDE.md` (from `templates/target-CLAUDE.md`), filled in for this repo.

## 5. Wire the agents — pick ONE end-to-end mode
Choose **one** complete mode for launch + review + revision and wire it consistently.
The two are mutually exclusive — **never mix**, or a combo will double-launch the coder or
strand revisions. Invariant either way: **exactly one coder launch per approved issue.**

### In-session mode (default)
Faber drives the whole loop in a Claude Code session: applies `ready`, spawns the coder,
runs the Codex review via `scripts/codex-review.sh`, and on review feedback spawns a
fix-mode coder + bumps the round label. **No coder routines, no Claude GitHub App.**
- Launch + revisions: **nothing to wire** beyond the `/faber` command.
- Reviewer: install/sign in to the **Codex CLI** so Faber can run `scripts/codex-review.sh`.

### Autonomous mode (optional)
Routines + the Codex GitHub integration run the loop without a Faber session. **Requires
the Claude GitHub App.** Faber does not spawn in this mode. Wire all three together:
- Claude **Coder** routine → trigger on this repo's `issues.labeled`
- Claude **Coder-revision** routine → trigger on this repo's `pull_request_review.submitted`
- **Codex GitHub integration** reviewer → connected to this repo, comments only (its
  review event is what fires the coder-revision routine)

### Always (both modes)
- Claude **brief** routine → include this repo in the daily scan (independent of the mode).
