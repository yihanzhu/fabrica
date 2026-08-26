---
intent-blob: 0462210f4ef74d37490f78990e9eee9b154087af
drafted: 2026-08-26
---

# Spec: rename to ystack

One complete rename — repo, docs, code, website, local clone, persona — with
back-compat so target repos keep working. Runs now, before Stack B, so the
lane is born as ystack.

## Requirements

Each is checkable when done.

- **R1 — repo.** `yihanzhu/fabrica` becomes `yihanzhu/ystack`. Old URLs
  redirect (check one). The ruleset is renamed `ystack-main-gate` in the same
  pass (answering the intent's open question: yes — one API call, do it now
  or it drifts forever).
- **R2 — local.** The clone moves to `~/git/ystack`, the git remote points at
  the new URL, `install.sh` regenerates the installed command as `/yshifu`,
  and the old `~/.claude/commands/faber.md` is deleted. `doctor.sh` passes
  from the new path.
- **R3 — content sweep.** No "fabrica" or "Faber" left in repo content
  except: the back-compat layer (R4) and lines explicitly marked as history.
  Checkable: a grep gate script that CI can run.
- **R4 — back-compat (nothing external breaks).** Legacy names keep working
  until targets migrate: the north-star resolver reads `.ystack/` first,
  then `.fabrica/`; the shipped-default marker check accepts both markers;
  `.fabrica/models.conf` with `FABRICA_*` keys still parses (new
  `.ystack/models.conf` with `YSTACK_*` preferred); `FABRICA_ALLOW_LOCAL_MIRROR`
  works as an alias of `YSTACK_ALLOW_LOCAL_MIRROR`. Hermetic tests cover each
  fallback.
- **R5 — no stragglers.** Every consumer goes through the resolver: the
  manager gate and doctor lose their hardcoded `.fabrica/` paths (Codex P1
  from the intent review).
- **R6 — website.** The site serves at `ystack.yihanzhu.com`;
  `fabrica.yihanzhu.com` redirects to it; canonical URL, sitemap, robots,
  and social meta all say ystack. The social preview image (`website/og.png`)
  is regenerated with the ystack name and domain — the grep gate can't see
  inside a PNG, so this is its own requirement.
- **R7 — chain rebaseline.** Sweeping text inside `work/v2-phase-2/` changes
  its files, so their recorded hashes are refreshed in the same PR (spec.md
  gets the new intent-blob, plan.md the new spec-blob). Afterward the
  pending-* helpers must not report `v2-phase-2` as stale or pending.
  (Scoped to this initiative: unrelated queued work — e.g.
  `plain-language-cleanup`, which correctly shows as pending — is expected.)
- **R8 — conventions.** Branch prefixes become `ystack/*`, env vars
  `YSTACK_*` (helpers + their tests updated), and the stage skills
  (`.claude/skills/{intent,spec,plan}-draft`) stop hardcoding `fabrica/*`
  branches and `.fabrica/` paths. The persona is **yshifu** everywhere.
  The live `stale` label on GitHub is external state: after PR a merges,
  the operator re-runs `setup-target-repo.sh` to reconcile it.

## Design

- **Order of operations** (repo rename first, so everything after lands under
  the real name; each step verifiable before the next):
  1. Operator-session ops: `gh repo rename ystack` → rename the ruleset →
     verify redirect + integrations (Actions secret, Claude app, Codex
     review, Cloudflare Pages all follow the repo — check, don't assume).
  2. **PR a — code**: `scripts/lib/north-star.sh` (resolver order),
     models-conf lib (key fallback), `gh-remote.sh` (env alias),
     `manager-review.sh` + `doctor.sh` (via resolver, both markers),
     **`codex-review.sh`** (its own anchored read of
     `.fabrica/models.conf` goes through the same fallback — it is an
     independent consumer, with anchored-path tests),
     **`install.sh` together with its template** (`templates/faber-command.md`
     → `templates/yshifu-command.md` — they move in the same PR so the
     installer never points at a file that doesn't exist), the
     **no-merge-guard hook** (`.claude/hooks/no-merge-guard.sh` — its runtime
     messages and ruleset reference are live content, not history),
     `scripts/v2/*` + workflows (`YSTACK_*`, ystack branches), the grep-gate
     script, all hermetic tests.
  3. **PR b — words**: README (new identity line replaces the trio — operator
     writes or approves the wording at this PR), QUICKSTART, RESTORE,
     NORTH_STAR, CLAUDE.md, manager/, routines/, reviewer/, templates/
     (`.ystack/` copies),
     `.claude/skills/` stage skills (branch prefixes + paths —
     constitution files, operator-driven session), work/ + proposals/
     readmes, `work/v2-phase-2/` sweep + hash rebaseline (R7), website
     files including the regenerated `og.png` (R6).
  4. Operator-session ops: move the local clone, update the remote,
     re-run `install.sh` (→ `/yshifu`), delete the old
     `~/.claude/commands/faber.md`, re-run `setup-target-repo.sh` (live
     label reconciliation), `doctor.sh` green. Cloudflare custom domain
     switched + redirect.
- **Persona:** `manager/CLAUDE.md` retitled for yshifu (same duties, same
  rails); `templates/faber-command.md` → `templates/yshifu-command.md`.
- The two PRs keep the size rule; the sweep is mechanical but reviewed like
  anything else (both reviewers are live).

## Out of scope

Target repos' own migration to `.ystack/` (MapleFolio keeps working on the
fallback; a later note tells targets how to move). Stack B. Any behavior
change beyond names.

## Areas of concern

1. **The rename touches the constitution** (`.claude/`, workflows, CLAUDE.md)
   — permitted only because these are operator-driven sessions; flagged as
   always.
2. **Website domain** is half outside git (Cloudflare dashboard): the
   redirect + custom-domain switch are operator clicks; the spec treats them
   as ops steps with a checklist, not code.
3. **History vs. present:** old PRs/issues keep saying fabrica — fine, they
   are history. The grep gate only patrols current content.

## Open questions — disposition

- README identity line: operator writes or approves it at PR b (carried).
- Ruleset rename: answered — yes, in R1.
