# Working in this repo

ystack is a control plane for an autonomous coding team, and it is its own
target repo — agents here are improving the team itself. Read these before
changing anything:

- **`CLAUDE.md`** — conventions, commands, PR rules, and the safety rails.
  Everything in it applies to every agent, whatever vendor.
- **`REVIEW.md`** — how work is reviewed here: three passes, what counts as
  Important, the nit cap, and how disagreements end.
- **`work/<slug>/`** — the artifact chain: `intent.md` → `spec.md` →
  `plan.md`. If you are implementing, your brief is that slug's plan; it is
  written so someone who never saw the conversation can build from it.

## The rules that bite

- **One concern per PR**, soft budget ~300–400 net lines. Split if bigger.
- **Plain language** in every artifact, PR description, and review comment:
  short sentences, everyday words. Jargon is a review nit.
- **Never merge.** Opening a PR is the end of an agent's authority; the
  operator merges. Pushing to `main` is refused server-side anyway.
- **Never edit the constitution unattended** — `.github/**`, `.claude/**`,
  `CLAUDE.md`, `REVIEW.md`. Propose changes as patches under `proposals/`
  unless the operator is driving the session.
- **Prove it.** Run the checks the plan names, paste the output, and say
  which commit you ran them on. Old proof on a new commit is stale.
- **Old names are gone.** The project and its manager were renamed;
  `scripts/check-rename.sh` fails CI if either old name survives in a
  tracked file. A line that documents real back-compat must carry the word
  "legacy" — that is how the gate tells intent from leftovers. Run the
  script to see what it accepts.
