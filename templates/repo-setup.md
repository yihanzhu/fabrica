# Target repo setup checklist

Do this once per target repo before pointing the team at it.

## 1. Labels
Create these labels (the loop uses them as its state — routines are stateless):
- `ready` — your approval; applying it triggers the coder
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
- Claude **Coder** routine → trigger on this repo's `issues.labeled`
- Claude **Coder-revision** routine → trigger on this repo's `pull_request_review.submitted`
- **Codex** PR review → connected to this repo, comments only
- Claude **brief** routine → include this repo in the daily scan
