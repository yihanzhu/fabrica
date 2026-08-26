---
spec-blob: a68dc49437e56c7553181e99210e892481e0cea7
drafted: 2026-08-26
---

# Plan: rename-ystack

The spec's four steps, at file level. Ops steps are operator-session actions;
the two PRs carry all content. This impl branch keeps the OLD prefix
(fabrica/impl/…) — the convention changes inside the rename itself.

## Files that change

**Ops 1 (before any PR):** `gh repo rename ystack`, ruleset renamed
`ystack-main-gate` (API), then verify: an old URL redirects; the Actions
secret, Claude app, Codex review, and Cloudflare Pages still respond.

**PR a — code (this branch)**
- `work/rename-ystack/plan.md` — this file, first commit.
- `scripts/lib/north-star.sh` — resolver reads `.ystack/` then `.fabrica/`.
- `scripts/lib/models-conf.sh` — `YSTACK_*` keys, `FABRICA_*` fallback.
- `scripts/lib/gh-remote.sh` — `YSTACK_ALLOW_LOCAL_MIRROR` + legacy alias.
- `scripts/manager-review.sh`, `scripts/doctor.sh` — read through the
  resolver; both shipped-default markers accepted.
- `scripts/codex-review.sh` — its anchored `.fabrica/models.conf` read gets
  the same fallback.
- `scripts/install.sh` + `templates/faber-command.md` →
  `templates/yshifu-command.md` + the matching manifest line — one PR,
  nothing dangling.
- `scripts/setup-target-repo.sh` — label text, `/yshifu`, `.ystack/` steps.
- `config/models.conf` — ships BOTH names during the bridge: `YSTACK_*`
  canonical plus `FABRICA_*` mirrors, because the live manager still asks
  for the old keys until PR b updates it (Codex P1, post-merge). PR b
  removes the mirrors when manager/CLAUDE.md switches keys.
- `scripts/merge-pr.sh` — its operator-facing messages say ystack/yshifu.
- `scripts/v2/*.sh`, `.github/workflows/plumbing-test.yml`,
  `.claude/hooks/no-merge-guard.sh` — `YSTACK_*`, `ystack/*` branches,
  guard messages say ystack.
- `scripts/check-rename.sh` (new) — the grep gate; authored here, wired
  into ci.yml only in PR b.
- All touched tests + new fallback tests (resolver, models.conf, alias).

**PR b — words (branch fabrica/impl/rename-ystack-b, after PR a merges)**
- README (identity line replaces the trio — operator approves wording),
  QUICKSTART, RESTORE, NORTH_STAR, CLAUDE.md, manager/CLAUDE.md (prose —
  its functional lines [paths, keys, marker] moved to PR a because the
  gate tests pin them; deviation noted here per protocol),
  routines/*, reviewer/*, templates/* (`.fabrica/` template dir →
  `.ystack/`), work/ + proposals/ readmes.
- `.claude/skills/{intent,spec,plan}-draft` — `ystack/*` branches,
  `.ystack/` paths.
- `work/v2-phase-2/` sweep + hash rebaseline; helpers must then show
  v2-phase-2 quiet (plain-language-cleanup stays pending — expected).
- `website/*` including a regenerated `og.png` (ystack name + domain).
- `.github/workflows/ci.yml` — wire the grep gate (repo is clean by then).
- Manifest updates for renamed/added files.

**Ops 4 (after PR b):** move clone to `~/git/ystack`, update the remote,
re-run `install.sh` (→ `/yshifu`), delete `~/.claude/commands/faber.md`,
re-run `setup-target-repo.sh` (live label), `doctor.sh` green, Cloudflare:
custom domain `ystack.yihanzhu.com` + redirect from the old one. Plus two
external-state fixes (Codex, post-merge): any shell-rc PATH entry pointing
at `~/git/fabrica/scripts` moves to the new path, and the live Claude
project's pasted persona (per RESTORE.md) is replaced with the yshifu
version — repo changes don't propagate there by themselves.

## Order of work

1. Ops 1 → verify → PR a (build, test, dual review, operator merges).
2. Operator re-runs nothing yet — the installed command still works from
   the old path until Ops 4.
3. PR b (build, dual review, operator approves the README line, merges).
4. Ops 4 → final verification checklist in the PR-b thread.

## Risks

- **The GitHub Actions outage**: no CI runs until it clears. PRs open now,
  merge only on green — same rule as always, just slower.
- **The redirect window**: between Ops 1 and Ops 4 every local remote and
  doc link runs on GitHub's redirect. Known-safe; Ops 4 closes it.
- **Missed strings**: the grep gate exists precisely for this; it patrols
  from PR b onward.
- **og.png**: regenerated deterministically (script or manual export);
  eyeballed in PR b review since grep can't see pixels.
- **Riskiest step**: the rebaseline — wrong hashes would make the helpers
  report v2-phase-2 stale forever. Proof: run both helpers in PR b's CI-less
  interim locally and paste output.

## Proof

- PR a: all hermetic tests green (incl. new fallback tests); shellcheck
  clean; verify output pasted, bound to the head SHA.
- PR b: grep gate clean; helpers show v2-phase-2 quiet; website diff read;
  og.png eyeballed.
- Ops: redirect check, doctor green from the new path, `/yshifu` installed,
  old command gone, site + redirect live.
