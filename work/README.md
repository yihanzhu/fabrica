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

**Deterministic branches:** `fabrica/intent/<slug>`, `fabrica/spec/<slug>`,
`fabrica/impl/<slug>`. A re-run updates the existing branch/PR; it never opens a
second PR for the same slug.

Today the stages run by hand (`/intent-draft`, `/spec-draft`, `/plan-draft` in a
Claude Code session); Phase 2 wires them to GitHub events. The gates never change
either way.
