# Intent: portable profile resolution
Author: Yihan (operator). Status: draft.

## Problem

The accepted `portable-control-plane-core` umbrella combined record schemas,
profile resolution, and executable adapter tests in one oversized design. Its G2
PR reached the review cap and will not proceed. Exact profile and manifest files
alone are not enough: a candidate can still choose its own commit, path, config,
identity mapper, or gate unless selection and provenance are resolved outside the
candidate data.

This is the deterministic profile-resolution child of parent intent
`portable-control-plane-core` at blob
`bd6f37e60aa12378aa00d0ff57aebd36b93c4a32`. The sibling
`portable-core-contracts` chain owns record schemas and validation. Executable
adapter tests have their own later child. The parent roadmap item remains open.

## Proposed outcome

ystack can resolve a selected profile and its adapter manifests into one immutable,
auditable result using exact caller-supplied Git context and the accepted portable
core contracts. The result records profile, manifest, package, config, skill,
capability, permission, principal, boundary, authority, model/tool, and source-value
provenance without claiming that the caller or selection is authenticated.

Resolution is deterministic, data-only, offline, and safe against path confusion,
symlinks, replacement objects, ambient environment, executable config, and remote
lookup. It checks contract compatibility and role separation but does not grant,
activate, qualify, execute, publish, or migrate anything.

## Affected users and systems

The operator; target repositories; future plan and implementation authors; selected
profiles and adapter manifests; the portable-core contract validator; Git object
resolution; future default and alternative adapters; and later policy,
qualification, execution, and audit stages that consume the resolved result.

## Constraints

- `portable-core-contracts` is a declared dependency, not yet accepted. Both G1s may
  exist in parallel. This child waits to finalize G2 until the contracts G2 artifact
  is merged and pinned by blob/version; implementation waits for contracts G3 and
  pins its exact commit. Dependency movement makes downstream artifacts stale.
- Resolver code invokes the accepted contract validator and never copies or
  redefines its schemas, capabilities, permissions, arguments, or separation rules.
- Every profile, manifest, package, config, and skill input is read as data from
  exact caller-selected committed Git objects. Never source, evaluate, execute,
  remotely fetch, or expand it from PATH, cwd, environment, mutable refs, or tags.
- The caller supplies an exact one-to-one repository-ID→physical-repo mapping.
  Resolution records its provenance and verifies commits, object types/modes, paths,
  object IDs, symlinks, and replacement-object state inside each mapped repo. The
  logical ID↔repo association remains an unauthenticated claim for later policy.
- The caller supplies selection and repository context separately from profile
  data. The resolver records those refs but does not authenticate or activate them.
- Candidate content cannot select or replace its trust root, profile source,
  identity adapter, gate, grant, policy, or qualification.
- Manifests only declare offers. Profiles only request bindings. Resolution checks
  exact versions, closed capabilities/permissions, config references, and role
  separation; it never turns compatibility into authority.
- Producer, verifier, reviewer, and publisher principals, boundaries, and authority
  refs preserve the immutable separation rules from the parent and contract child.
- No real adapter runs. Do not mint credentials, read secret values, publish a
  branch or PR, change live config, activate a profile, or enable autonomous writes.
- Executable fake adapters and the 2×2 contract matrix stay in
  `portable-adapter-contract-tests`.
- Keep the implementation offline, reconstructable, and small enough for one
  reviewable PR. Constitution changes follow the operator/`proposals/` boundary.
- Do not continue spec or code under the old parent slug or claim this child closes
  the parent roadmap item.

## Open questions

- What exact caller inputs and trust-context refs does resolution require, and what
  provenance must the resolved profile return?
- How should one invocation map every repository ID to a physical repo without
  leaking personal paths into canonical records?
- Which Git object, path, file-mode, symlink, replacement-object, and hash-format
  checks are required for both SHA-1 and SHA-256 repositories?
- How should data config, secret-reference names, skill tree refs, and identity refs
  be validated without reading secret values or executing target content?
- What compatibility, separation, error-code, idempotency, and adversarial fixtures
  must prove deterministic resolution before real adapters can consume it?
