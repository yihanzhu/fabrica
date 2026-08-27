# work/ — the v2 artifact chain

One initiative per directory: `work/<slug>/`. Every stage commits an artifact the
next stage reads. G1/G2/G3 are operator merge gates. High-risk work adds a
pre-code plan gate: the operator's decision is recorded against the exact
`plan.md` blob before implementation. Until the portable stage record exists,
use a separately merged plan PR. Any plan change invalidates that acceptance and
must return to the plan gate.

| Artifact | Written by | Gate that accepts it |
|---|---|---|
| `intent.md` | operator + `/intent-draft` | **G1** — operator merges the `intent: <slug>` PR |
| `spec.md` | `/spec-draft` (spec stage) | **G2** — operator merges the `spec: <slug>` PR |
| `plan.md` | `/plan-draft`, before implementation | **Plan gate** — operator accepts the exact blob before high-risk code; routine work records an independent plan check before code, then the operator accepts plan + code + tests at G3 |

**Chain state is the artifacts themselves, hash-linked.** `spec.md` frontmatter
records `intent-blob` — the `git hash-object` of the intent it was drafted from;
`plan.md` records `spec-blob`. Before acting on any artifact, compare its recorded
hash against main's current upstream file: on mismatch, label the PR `stale` and
stop — never build on a moved artifact.

**Deterministic branches:** `ystack/intent/<slug>`, `ystack/spec/<slug>`,
`ystack/impl/<slug>`. A re-run updates the existing branch/PR; it never opens a
second PR for the same slug.

Today the artifact stages run by hand. Autonomous wiring is paused: draft PR #146
proved that portable adapters, credential separation, evals, and durable
reconciliation must land first. [`ROADMAP.md`](../ROADMAP.md) is the authoritative
rollout order; no forge event name or agent harness is a core gate.
