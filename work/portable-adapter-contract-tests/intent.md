# Intent: portable adapter contract tests
Author: Yihan (operator). Status: draft.

## Problem

The accepted `portable-control-plane-core` umbrella put record schemas, profile
resolution, and executable adapter testing into one oversized G2 design. Its PR
reached the review cap and will not proceed. The test portion also trusted a
driver's reported observations instead of independently running each accepted
case and revalidating every produced document and Git object.

This is the executable adapter-test child of parent intent
`portable-control-plane-core` at blob
`bd6f37e60aa12378aa00d0ff57aebd36b93c4a32`. The sibling
`portable-core-contracts` owns schemas and validation;
`portable-profile-resolution` owns deterministic Git-backed resolution. The parent
roadmap item stays open until all child slices and later real-adapter proof finish.

## Proposed outcome

ystack has a self-contained contract-test runner that executes only test-owned fake
adapters, independently runs every externally accepted inventory case, validates
all inputs and outputs with the accepted core validator, and verifies every Git
artifact against explicit repository mappings. Results contain observations only;
the runner cannot rewrite expected verdicts, errors, fixtures, groups, or assertions.

A 2×2 matrix swaps producer/harness A and B while holding forge A or B fixed, then
swaps forge A and B while holding the harness fixed. The matrix proves that the
portable artifact, risk, gate, outcome, evidence, and audit projection stays the
same while adapter and profile provenance changes honestly. It proves contract
substitution only, not real-vendor safety or portability.

## Affected users and systems

The operator; future adapter authors; target fixtures; accepted case inventories;
the portable-core validator; the deterministic profile resolver; fake producer and
forge packages; temporary Git repositories; contract-test result artifacts; CI;
and later real-adapter qualification and regression suites that reuse the accepted
schemas, comparison projection, regression cases, and observation semantics.

## Constraints

- Parent intent: `portable-control-plane-core`, blob
  `bd6f37e60aa12378aa00d0ff57aebd36b93c4a32`.
- This G1 may proceed in parallel. Its G2 waits for accepted G2 artifacts from both
  sibling chains and pins their blobs/versions. Implementation waits for and pins
  both siblings' G3 commits; dependency movement makes downstream artifacts stale.
- Reuse the accepted core validator and profile resolver. Do not copy, reinterpret,
  or weaken their schemas, capability arguments, path rules, role separation, or
  trust boundaries.
- The runner independently executes and revalidates every inventory case. The
  inventory is selected outside the runner, fake adapter, candidate data, and
  observed result. An immutable `inventory_acceptance_ref` or sibling-defined
  equivalent binds its exact digest and is carried unchanged in the result. This
  child validates the digest linkage but does not authenticate the external
  acceptance. The inventory binds case ID, phase, fixture digest, expected
  verdict/error, equivalence group, and assertion IDs.
- Manifests and candidate data cannot select an executable. The test harness maps
  allowlisted fake package IDs to digest-pinned, test-owned committed executables.
  Every process runs in a disposable temporary directory with inherited environment
  and credential variables cleared. These trusted test fixtures are forbidden by
  contract from using the network or host files outside their fixture root. This
  child does not claim mechanical network or host-filesystem isolation; later
  control-foundation work must provide those controls before untrusted code runs.
- One request and one response use a closed typed protocol. Stdout is data only;
  stderr is diagnostic; nonzero exit is transport failure. Empty, malformed,
  partial, timed-out, degraded, mismatched, or self-relabelled output fails closed.
- All Git reads disable replacement objects and use explicit one-to-one repository
  mappings. Fixture paths stay beneath a canonical non-symlink root.
- Test results cannot grant authority, qualification, approval, merge, publish, or
  branch-write capability. No real adapter or live profile runs.
- Real-adapter execution cannot reuse this fake-only launcher. It requires a
  separately accepted, sandboxed, credential-controlled launcher and qualification
  chain; only the accepted schemas, projection, cases, and observation semantics
  may carry forward.
- Keep the fixtures self-contained, the run reconstructable, and the implementation
  small enough for one reviewable PR. CI changes follow the operator/`proposals/`
  constitution boundary.
- Do not continue spec or code under the old parent slug or claim this child closes
  the parent roadmap item.

## Open questions

- What exact fake-adapter request/response protocol, environment clearing, and
  process limits keep the runner useful without becoming a generic command launcher?
- How are accepted inventory identity, raw fixture bytes, produced documents,
  repository mappings, and observed assertions supplied so every case is rerun and
  independently revalidated?
- Which fields form the vendor-neutral comparison projection, which provenance
  fields must differ, and how are false equivalence or dropped cases rejected?
- What fixture packages, positive/negative cases, timeouts, cleanup checks, and
  stable errors are required for the two-stage 2×2 matrix?
- What exact evidence is enough for this fake matrix to qualify the contract runner
  itself without claiming that any real adapter or external target is qualified?
