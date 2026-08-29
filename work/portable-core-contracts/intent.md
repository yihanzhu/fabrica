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

The first implementation attempt also proved that one large validator PR is not
reviewable enough for this contract. Four exact review rounds found 15, then 8,
then 4, then 4 actionable gaps. The same rule families kept resurfacing across
document, profile-set, and stage-run validation. PR #183 is preserved at its
round-cap state as evidence and possible source material; it is not accepted code.

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

The contract is delivered as one versioned package through small parts that land
in dependency order and can be reviewed on their own. Every rule has one clear
home. Incomplete parts stay private and inactive. A final assembly exposes the
public validator only after the full package and its cross-part proof pass.

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
- This amendment changes only how the work is split and delivered. The five
  document kinds, three capability IDs, five permission IDs, v1 field meanings,
  canonical bytes, error classes, and claims-not-authority boundary stay unchanged.
- The implementation includes strict, offline positive and adversarial validation
  tests, but not an executable adapter test runner or 2×2 adapter matrix.
- It defines profile/manifest record shapes and the references needed by the
  profile-resolution child, but does not read Git objects or resolve profiles.
- Do not wire or migrate a real adapter, activate a profile, move skills, or enable
  autonomous writes.
- Do not draft another spec or implementation under `portable-control-plane-core`,
  or claim this child closes the accepted parent. The operator records the old G2
  PR as superseded when all three replacement G1 PRs exist.
- Keep one versioned contract identity and one public command entry. Private files
  and implementation parts may separate responsibility, but they must not copy a
  role or capability list, record shape, policy table, or acceptance rule into a
  second home.
- Deliver parts in dependency order and keep each one small enough to review on its
  own. A partial part cannot expose a public validator or claim the v1 package works.
  The final assembly owns the public command and full-package proof.
- Every independently merged implementation part uses its own child slug and normal
  artifact, CI, independent-review, and human-merge gates. If a proposed part is not
  reviewable without weakening proof, split it before code rather than compressing
  code or reducing tests.
- Keep PR #183 frozen until accepted G2 and plan artifacts decide its exact reuse
  and disposition. Do not merge it under the old delivery plan. Reuse only code and
  tests that give every rule one clear home and pass independent review; do not treat
  its commit history as accepted implementation evidence.
- Any constitution-path change follows the operator/`proposals/` boundary, and the
  operator remains the merge authority.

## Open questions

- What is the smallest dependency order that gives shared types, profile relations,
  request closure, result status/outcome rules, and final assembly one clear home?
- How do we identify the whole versioned package and load its fixed files without
  allowing caller-supplied code or search paths?
- What are the exact child slugs and dependencies, and what must the final assembly
  wait for before it may expose the public validator?
- Which parts of PR #183 can be moved behind the new boundaries, and which
  hard-to-read rules or tests must be rewritten rather than copied?
- Which tests show which commands run which rules, and which outcome-table,
  forced-failure, and full-package cases prove every rule runs everywhere it must?
- What evidence-based review-size range applies to each child, and do the result
  status/outcome rules need to split again before implementation begins?
