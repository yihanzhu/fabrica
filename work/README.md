# work/ — the v2 artifact chain

One initiative per directory: `work/<slug>/`. Every stage commits an artifact the
next stage reads. Within this artifact chain, G1/G2/G3 are the live operator merge
gates. The in-session manager still uses its existing intake, CI, review, and human
merge gates. The accepted roadmap adds a risk-based pre-code plan gate, but neither
lane enforces it yet. Once both lanes wire that gate, the operator's decision must be
recorded against the exact `plan.md` blob before high-risk implementation. Until the
portable stage record exists, that means a separately merged plan PR. Any plan change
invalidates that acceptance and must return to the plan gate. Do not claim this planned
gate passed before the enforcement change lands.

| Artifact | Written by | Gate that accepts it |
|---|---|---|
| `intent.md` | operator + `/intent-draft` | **G1** — operator merges the `intent: <slug>` PR |
| `spec.md` | `/spec-draft` (spec stage) | **G2** — operator merges the `spec: <slug>` PR |
| `plan.md` | `/plan-draft` | **G3 today; target plan gate after enforcement lands** — operator accepts the exact blob before high-risk code; routine work records an independent plan check before code, then the operator accepts plan + code + tests at G3 |

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
