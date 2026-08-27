# work/ — the v2 artifact chain

One initiative per directory: `work/<slug>/`. Every stage commits an artifact the
next stage reads; the operator's PR merges are the only human gates.

| Artifact | Written by | Gate that accepts it |
|---|---|---|
| `intent.md` | operator + `/intent-draft` | **G1** — operator merges the `intent: <slug>` PR |
| `spec.md` | `/spec-draft` (spec stage) | **G2** — operator merges the `spec: <slug>` PR |
| `plan.md` | `/plan-draft`, first commit of the impl branch | **G3** — operator approves + merges the implementation PR (plan + code + tests) |

**Chain state is the artifacts themselves, hash-linked.** `spec.md` frontmatter
records `intent-blob` — the `git hash-object` of the intent it was drafted from;
`plan.md` records `spec-blob`. Before acting on any artifact, compare its recorded
hash against main's current upstream file: on mismatch, label the PR `stale` and
stop — never build on a moved artifact.

**Deterministic branches:** `ystack/intent/<slug>`, `ystack/spec/<slug>`,
`ystack/impl/<slug>`. A re-run updates the existing open branch/PR. A closed PR
is history; after closing a stale PR, an operator dispatch may open a fresh one
for that slug.

If upstream moves after the operator approves an open PR, the stage labels it
`stale`, comments once, and stops. Close it, then dispatch the stage to rebuild.
Never merge the stale PR.

**Two lanes run the same chain.** In a Claude Code session, `/intent-draft`,
`/spec-draft`, and `/plan-draft` run by hand. The autonomous lane uses
`.github/workflows/spec-on-intent.yml` after an intent merge,
`.github/workflows/implement-on-spec.yml` after a spec merge, and
`.github/workflows/review-on-pr.yml` on every same-repo PR. Both lanes keep the
same hash checks and operator merge gates. Autonomous review posts comments
only; until the deferred fix stage lands, the operator handles findings in a
session.
