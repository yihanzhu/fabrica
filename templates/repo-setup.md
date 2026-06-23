# Target repo setup checklist

Do this once per target repo before pointing the team at it.

## 1. Labels
Create these labels (the loop uses them as its state — the state lives in labels, not agent
memory):
- `ready` — the record of your approval; Faber applies it, then spawns the coder (active
  path). If you wire the optional coder routine instead, this label fires that routine —
  never both, so exactly one coder launch per approved issue.
- `round-0`, `round-1`, `round-2`, `round-3` — review-loop counter
- `needs-human` — escalation: round cap hit, ambiguous spec, oversized PR, or failure

```bash
scripts/setup-target-repo.sh <owner>/<repo>
```

This is idempotent — safe to re-run. It only does the labels; the steps below are
manual (the script prints these reminders too).

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

## 5. Wire the agents
Pick **one** coder-launch mechanism — never both, or one approval launches the coder twice
(invariant: exactly one coder launch per approved issue):
- **Active (default): Faber-driven** — no coder routine. Faber spawns the coder subagent
  in-session after applying `ready`. Nothing to wire here beyond the `/faber` command.
- **Optional alternative: autonomous routines** — only if you are NOT using the Faber-driven
  path:
  - Claude **Coder** routine → trigger on this repo's `issues.labeled`
  - Claude **Coder-revision** routine → trigger on this repo's `pull_request_review.submitted`

Always wire, regardless of which coder mechanism you chose:
- **Codex** PR review → connected to this repo, comments only
- Claude **brief** routine → include this repo in the daily scan
