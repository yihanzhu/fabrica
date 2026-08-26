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

- Runs after Stack A (#131) merges and before Stack B, so the lane's four
  workflows are born with the right names.
- Target repos must not break: the resolver reads `.ystack/` first and falls
  back to `.fabrica/` until targets migrate.
- Verify after the repo rename: Cloudflare Pages, the Claude GitHub app,
  Codex code review, and the CLAUDE_CODE_OAUTH_TOKEN secret all still work
  (they follow the repo, but check, don't assume).
- Small PRs per the size rule; mechanical sed changes and code/tests split
  sensibly.

## Open questions

- What replaces the "Otium · Valor · Fabrica" trio line in the README?
- Rename the ruleset (`fabrica-main-gate` → `ystack-main-gate`) in the same
  pass, or leave it (cosmetic, API-side only)?
