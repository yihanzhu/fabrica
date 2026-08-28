# Intent: portable core contracts
Author: Yihan (operator). Status: draft.

## Problem

ystack has accepted the need for a portable control-plane core, but the first spec
tried to define both the core records and the system that executes adapter contract
tests. That made one change too broad. It also left capability inputs open-ended,
which could turn a portable adapter seam into an arbitrary command or network escape.

This is the record/validation child of accepted parent intent
`portable-control-plane-core` at blob
`bd6f37e60aa12378aa00d0ff57aebd36b93c4a32`. The parent's G2 PR reached the review
cap and will not proceed to plan or code. Separate G1 chains own deterministic
profile resolution and executable adapter contract tests. The parent roadmap item
remains open until all child slices and later real-adapter proof are complete.

The product still lacks a small, machine-checked vocabulary that every later
adapter and workflow can share without naming Claude, Codex, GitHub, or another
vendor. Until that vocabulary is settled, evidence, profile resolution, role
separation, and stage results can drift between implementations.

## Proposed outcome

ystack has a compact, versioned contract layer for stage requests and results,
artifact and evidence references, risk and qualification references, adapter
manifests, profile declarations, capabilities, and permissions. Each v1 capability
has a closed argument shape. Status, outcome,
evidence, actor, environment, actual tool/model metadata, and profile provenance
have one meaning across adapters.

The contracts reject malformed, ambiguous, overreaching, or internally inconsistent
data with hermetic tests. They carry claims and exact references without pretending
to authenticate them or grant authority. The current live profile keeps working
unchanged.

## Affected users and systems

The operator; future plan and implementation authors; target repositories; the
`work/` artifact chain; future producer, verifier, reviewer, forge, CI, execution,
identity, and publisher adapters; canonical record validators; profile resolution;
and the separate profile-resolution, adapter-test, policy, qualification, and
telemetry initiatives that consume these records.

## Constraints

- Core records, fields, capabilities, and arguments are harness-, model-, forge-,
  and CI-neutral.
- Producer, verifier, reviewer, publisher, and human decisions remain separate.
  No machine capability can express merge, approval, bypass, human impersonation,
  policy activation, or an unrestricted command, network call, or branch write.
- Producer has no publish authority. Verifier has no model or forge-write authority.
  Reviewer is exact-change read-only and cannot edit, approve, publish, or merge.
  Publisher has no model or candidate execution and performs one fixed typed write.
  Their protected principals, execution boundaries, and authorities remain distinct.
- A manifest declares support, a profile requests it, later policy may grant it,
  and a result records actual use. None implies another.
- Exact Git and content references are recoverable claims, not proof that the caller
  or selection is trusted. Authentication and runtime enforcement remain later work.
- Profile, manifest, config, and skill metadata are data from exact caller-selected
  committed objects. They are never sourced, evaluated, executed, remotely fetched,
  or expanded from ambient environment. Candidate content cannot choose or activate
  its own trust root, profile, gate, grant, or policy.
- Extensions cannot alter core safety meaning. Any new core field or changed meaning
  requires a new contract version.
- The implementation includes strict, offline positive and adversarial validation
  tests, but not an executable adapter test runner or 2×2 adapter matrix.
- It defines profile/manifest record shapes and the references needed by the
  profile-resolution child, but does not read Git objects or resolve profiles.
- Do not wire or migrate a real adapter, activate a profile, move skills, or enable
  autonomous writes.
- Do not draft another spec or implementation under `portable-control-plane-core`,
  or claim this child closes the accepted parent. The operator records the old G2
  PR as superseded when all three replacement G1 PRs exist.
- Keep the change small enough for one reviewable implementation PR. If design
  cannot meet that bound without weakening the contracts, return to G2.
- Any constitution-path change follows the operator/`proposals/` boundary, and the
  operator remains the merge authority.

## Open questions

- What is the smallest set of top-level records and shared references that preserves
  the complete future lifecycle without implementing later stages now?
- Which capability and permission IDs belong in v1, and what is the closed argument
  schema for each?
- Which shape, relational, path, provenance, and status/outcome rules must the core
  validator enforce in this initiative?
- What exact profile, selection, and provenance refs must the later deterministic
  resolver consume and produce without changing v1 meaning?
- What exact boundary lets the later adapter-contract-test initiative consume these
  contracts without adding a second schema or trusting self-reported observations?
