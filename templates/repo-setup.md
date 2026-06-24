# Target repo setup checklist

Do this once per target repo before pointing the team at it.

## 1. Labels
Create these labels (the loop uses them as its state — each coder spawn is stateless):
- `ready` — the record of your approval; Faber's cue to spawn the coder
- `round-0`, `round-1`, `round-2`, `round-3` — review-loop counter
- `needs-human` — escalation: round cap hit, ambiguous spec, oversized PR, or failure
- `merge-ready` — Codex review passed; awaiting your merge

```bash
scripts/setup-target-repo.sh <owner>/<repo>
```

This is idempotent — safe to re-run. It only does the labels; the steps below are
manual (the script prints these reminders too).

The script is the **canonical source of truth** for these labels: a normal run
force-edits each existing label to the script's definitions, so re-running reconciles
any drift live labels have picked up. To check for drift **without** mutating anything,
run the read-only dry mode:

```bash
scripts/setup-target-repo.sh --check <owner>/<repo>
```

It reports per label `matches` / `differs` (which of name/color/description) / `missing`,
and exits non-zero if anything is missing or differs (zero if all match).

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

## 5. Connect the in-session team
The team runs from a Claude Code session — there are no per-repo routine triggers to wire.
- Install the **`/faber`** command: run `scripts/install.sh` (no args) from your fabrica
  clone. Faber then orchestrates the loop here, spawning Claude coder subagents.
- Connect the **Codex CLI** (installed + signed in) so Faber can run
  `scripts/codex-review.sh <PR#>` against this repo's PRs — the cross-vendor, comments-only
  reviewer.
