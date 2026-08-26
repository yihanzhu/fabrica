# Intent: rename to ystack

Author: Yihan (operator). Status: draft.

## Problem

The project is becoming my personal SDLC stack, and the name should say so.
"fabrica" no longer fits the identity, and the Latin trio it belonged to
(Otium · Valor · Fabrica) is not how I think about it anymore.

## Proposed outcome

The project is named **ystack** everywhere: repo name, docs, website, branch
prefixes, env vars, markers. One clean sweep — no half-renamed leftovers.
The console persona is renamed too: **Faber becomes Shifu** (师傅 — the master
craftsman you hand work to). The `/faber` command becomes `/shifu`.

## Affected users and systems

The repo (rename to `yihanzhu/ystack`; GitHub redirects old URLs), all docs
and the website, branch conventions (`fabrica/*` → `ystack/*`), env vars
(`FABRICA_*` → `YSTACK_*`, including models.conf keys and their parser +
tests), the `fabrica-shipped-default` marker and doctor's check for it, the
`fabrica-main-gate` ruleset name, my local clone path, the persona files
(`manager/CLAUDE.md`, `templates/faber-command.md`, `install.sh` — Faber →
Shifu, `/faber` → `/shifu`), and **target repos that carry `.fabrica/` dirs
today (MapleFolio)**.

## Constraints

(Extended after Codex's review of this PR — 7 findings folded in.)

- Runs after Stack A (#131) merges and before Stack B, so the lane's four
  workflows are born with the right names.
- Target repos must not break. Back-compat covers everything that reads
  legacy names, not just the north-star resolver: the `.fabrica/` fallback,
  the `fabrica-shipped-default` marker check (shared by doctor and the
  manager gate), `.fabrica/models.conf` with its `FABRICA_*` keys, and a
  `FABRICA_ALLOW_LOCAL_MIRROR` alias — all honored until targets migrate.
- Every consumer moves together: the manager gate and doctor read through the
  resolver (no hardcoded `.fabrica/` paths left behind), and `install.sh`
  regenerates the installed command after the clone moves (the old
  `~/.claude/commands/faber.md` is removed, not orphaned).
- Website: `fabrica.yihanzhu.com` → `ystack.yihanzhu.com` with redirects —
  canonical URL, sitemap, robots, and social meta all move.
- Chain hygiene: renaming text inside `work/v2-phase-2/` breaks its recorded
  hashes — the rename rebaselines those artifacts so Stack B starts from a
  fresh chain, never a stale one.
- Verify after the repo rename: Cloudflare Pages, the Claude GitHub app,
  Codex code review, and the CLAUDE_CODE_OAUTH_TOKEN secret all still work
  (they follow the repo, but check, don't assume).
- Small PRs per the size rule; mechanical sed changes and code/tests split
  sensibly.

## Open questions

- What replaces the "Otium · Valor · Fabrica" trio line in the README?
- Rename the ruleset (`fabrica-main-gate` → `ystack-main-gate`) in the same
  pass, or leave it (cosmetic, API-side only)?
