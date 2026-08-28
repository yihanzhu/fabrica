---
intent-blob: bd6f37e60aa12378aa00d0ff57aebd36b93c4a32
drafted: 2026-08-28
---

# Spec: portable control-plane core

Define a small vendor-neutral contract family and prove it with declarative fake
adapters. Keep the live Claude Code, Codex, and GitHub path unchanged.

## Requirements

- **R1 — bounded foundation.** Add contract validation, deterministic profile
  resolution, declarative fake adapter packages, and hermetic contract tests.
  Do not wire a real adapter, activate a profile, grant authority, or enable an
  autonomous write; live jobs/gates keep their meaning and CI only gains this test.
- **R2 — one strict JSON family.** Accept six top-level kinds:
  `stage_request`, `stage_result`, `adapter_manifest`, `profile`,
  `resolved_profile`, and `adapter_contract_test_result`. Every valid document is
  UTF-8 canonical JSON: compact, keys sorted as jq `-S`, no floats, and exactly one
  final newline. Limits are 1,048,576 bytes, depth 32, 256 collection members,
  8,192 decoded UTF-8 bytes per string, and integers in `0..2147483647`. Unknown
  versions/kinds/fields, duplicate keys, alternate encodings, malformed JSON, and
  limit violations fail closed. `core/v1/contracts.jq` is the only executable schema.
- **R3 — version and extension rules.** Every document carries
  `schema_version: 1`, `kind`, `id`, and optional `extensions`. IDs are 1–128
  lowercase ASCII letters, digits, dots, colons, underscores, or hyphens. Extension keys match
  `^([a-z0-9]|[a-z0-9][a-z0-9-]{0,61}[a-z0-9])(\.([a-z0-9]|[a-z0-9][a-z0-9-]{0,61}[a-z0-9]))+/[a-z0-9][a-z0-9._-]{0,127}$`
  (`com.example/trace` passes; `trace`, `Com.example/x`, and `com..x/y` fail); values
  are objects. Unknown extensions are preserved but inert. Changed meaning, a new
  required field, or a changed core enum requires a new major version.
- **R4 — exact references.** A `document_ref` names a canonical document by kind,
  ID, and SHA-256 of its complete canonical bytes. An `artifact_ref` is a tagged
  union: `git_object` names repository, full commit, normalized repo-relative path,
  object type `blob|tree`, and full object ID; `content` names media type, a safe
  locator ID matching the core ID grammar, and SHA-256. The core never dereferences
  a content locator ID. Git SHA-1 and SHA-256 repositories are
  supported. Reject absolute paths, empty or dot segments, `..`, backslashes,
  control characters, shortened or floating refs, wrong object type/mode, and
  symlinks. Raw invalid fixtures instead use fixture refs with a normalized path
  beneath the caller's canonical fixture root. Every path component must be a real
  non-symlink entry, and the resolved path must stay inside that root.
- **R5 — one operation per stage.** A `stage_request` has exactly one operation:
  role, resolved binding, one capability, exact permission IDs, optional opaque
  grant ref, and exact gate-decision refs. Publication is a separate publisher
  stage; it is never hidden inside a producer, verifier, or reviewer result. The
  request also names initiative, workflow, stage, task class, target/source,
  inputs, risk claim, resolved profile, optional qualification ref, environment,
  finish condition, verification instructions, required evidence kinds, request
  time, stable request ID, and capability-specific arguments. Retry attempts keep
  the same request ID.
- **R6 — total status/outcome matrix.** A `stage_result` binds the exact request
  and resolved profile, attempt, controller/reporter, terminal status, outcome when
  allowed, structured reason, expected/observed identities, subject/auxiliary
  outputs, diagnostics, evidence, and timestamps. `executed=true` also requires the
  exact performer and used capability; `executed=false` forbids both. Allowed
  combinations are fully defined in Design.
  No machine outcome represents human approval or merge.
- **R7 — evidence covers the request.** Each evidence record binds the exact
  request digest, attempt ID, finish-condition digest, target, source/base, output
  or release when required, resolved profile, qualification scope, environment,
  performer, adapter package/config, verification instructions, and a `content`
  ref to proof bytes. Proof kind is exactly
  `deterministic|behavioral|architecture|independent-review`; verdict is exactly
  `passed|failed|inconclusive`. Required evidence kinds are non-empty and unique.
  A completed result's evidence-kind set equals the request's set: no missing or
  unrequested kind. Every evidence record binds every subject and auxiliary output.
  Evidence performer, adapter package, and config must match the request's resolved
  binding. Qualification is omitted exactly when the request omits it; JSON `null`
  is invalid. Prior-stage evidence is cited through that stage's exact result ref
  and cannot be copied into a new record with a new performer.
  Missing kinds, changed finish conditions, or replay across request, attempt,
  target, output, profile, environment, or instructions fail validation. A comment,
  label, check name, mutable URL, prose claim, or unbound hash is not evidence.
- **R8 — risk, qualification, grants, and gates stay distinct.** Risk carries a
  claimed tier, reasons, policy ref, and required-gate refs. Core tiers are
  `routine`, `high`, and `bootstrap`; target tiers are namespaced and inert.
  `qualification_ref`, `grant_ref`, `selection_ref`, and `gate_decision_ref` are
  separate immutable refs with scope digests. The core validates and carries them
  but never issues, authenticates, activates, or treats them as authority. There is
  no `qualified: true` or `approved: true` field.
- **R9 — capabilities are not authority.** An adapter manifest **offers** exact
  capability and permission IDs. A profile binding **requests** them. Later policy
  may **grant** them. A result records the one capability **used**. Validation proves
  each binding's requested capabilities are a subset of its manifest, requested
  permissions equal their required union and are a manifest subset, the operation
  belongs to the binding, and used equals requested. It never infers a grant. IDs
  are closed byte values with no wildcards, aliases, prefixes, or generic escape.
- **R10 — core separation matrix.** Producer, verifier, reviewer, and publisher
  bindings are pairwise distinct in binding ID, adapter instance, principal, and
  execution boundary. Authority-ref IDs and scope digests must differ when present;
  semantic overlap beyond exact equality remains later policy work. The same adapter
  implementation may fill two roles only through those distinct bindings. The core
  role/capability table in Design is mandatory. There is no machine capability for
  merge, approval, branch-rule bypass, human impersonation, policy activation,
  arbitrary shell, arbitrary network, or unbounded branch update. The bounded
  branch entry is a typed proposal whose external safety is enforced later.
- **R11 — deterministic, caller-selected resolution.** A profile selects exact
  adapter versions, package trees, skill trees, capabilities, permissions, and
  data-only config refs. It has no inheritance, floating range, ambient default,
  executable path, environment substitution, remote schema, or literal secret.
  Resolution reads profile/manifests with `git ls-tree`, `git cat-file`, and
  `git show` from one caller-supplied exact commit plus a separate `selection_ref`.
  The profile does not self-declare its Git source. The resolver derives its exact
  commit/path/blob provenance and records it only in `resolved_profile`. This initiative does not
  authenticate the caller or selection ref; later policy decides whether it is
  trusted. Profile data cannot contain or override selection, grant, gate, or
  activation fields.
- **R12 — relational validation.** Shape validation alone is insufficient.
  Commands validate: one document; profile/manifests into a resolved profile; a
  request + resolved profile + result; and a complete contract-test result with
  its raw fixtures. Cross-document checks cover exact refs, capability subsets,
  role bindings, evidence coverage, status/outcome rules, risk/gate immutability,
  and request/result identity.
- **R13 — honest fake swap proof.** Four distinct Git package trees represent
  producer/harness A, producer/harness B, forge A, and forge B. They are declarative
  fixtures, not executed programs. Each matrix case is an ordered two-stage chain:
  one producer stage followed by one read-only forge-projection stage. One semantic
  fixture derives four resolved profiles and eight unique stage requests, linked by
  one `equivalence_group`. Neutral artifact, risk, gate, status/outcome, evidence, and
  audit meaning must match; IDs, times, and honest package/profile provenance must
  differ. The driver verifies each observed package tree against its manifest.
- **R14 — typed contract-test result.** Every case records phase
  `parse|shape|resolve|run|matrix`, observed status/error/assertions, and canonical
  refs only when produced. An independent inventory fixes each case's ID, phase,
  raw fixture ref/digest, expected accept/reject, expected stable error when relevant,
  equivalence group, and non-empty required assertion IDs. Observed cases match every
  fixed field and ID one-for-one and add observations only. Missing accepted results,
  changed expectations, tautological/dropped assertions, vacuous pass, or fabricated
  canonical results fail.
- **R15 — adversarial cases.** Tests cover malformed and noncanonical JSON;
  limits; wrong version/kind; unknown fields; unsafe blob/tree paths and modes;
  missing/mismatched refs; invalid status/outcome pairs; missing evidence kinds;
  cross-scope replay; capability/permission overreach; every forbidden role share;
  malformed branch proposal or explicit force/delete; merge/approval/bypass claims;
  profile command/env/selection injection; package
  relabeling; risk/gate mutation; pass-looking prose; and degraded/empty fixture
  output. A positive case proves same implementation, separate boundaries.
- **R16 — neutral skill seam.** A profile may carry `skill_package_ref` entries
  for target-owned `.ystack/skills/<name>` Git trees. The intended package shape is
  the open [Agent Skills format](https://agentskills.io/specification), with
  `SKILL.md` plus optional resources. V1 validates the exact tree, canonical path,
  name, and declared format ID; it does not parse YAML or claim conformance to a
  changing external spec. Harness locations such as `.claude/skills/` are later
  generated bridges. `allowed-tools` or other skill text never grants capability.
- **R17 — restore, docs, and delivery bound.** Add every load-bearing file to
  `ci/required-files.txt`, keep scripts executable and ShellCheck 0.11.0 clean, and
  run the hermetic suite in CI against a checksum-pinned jq 1.6. README documents
  the commands, exit behavior, jq minimum, and that the core is not wired live.
  Implementation uses one deterministic PR and is expected to add 520–780 net lines.
  The plan gives an exact estimate and asks for a soft-budget exception capped at
  800; above that, it returns to G2 or opens a separate accepted initiative.
  The plan also fixes the constitution route: an operator-driven session may edit CI;
  an unattended run writes a `proposals/` patch and stops until the operator applies it
  to the implementation branch before final review.

## Design

### Canonical documents and shared refs

All canonical document digests cover the full canonical JSON envelope, not only
payload bytes. Timestamps are UTC RFC 3339 strings. Every JSON integer is in
`0..2147483647`.

| Kind | Required body |
|---|---|
| `stage_request` | initiative, workflow, stage, task class, target/source, inputs, risk, resolved-profile ref, selection ref, qualification ref if any, gate-decision refs, environment, one operation, finish condition, instruction ref, evidence kinds, requested time |
| `stage_result` | request/profile refs, attempt, controller/reporter, `executed`, status, outcome when allowed, reason, expected/observed refs, subject/auxiliary/delta refs, diagnostic content refs, nested evidence, performer/used capability iff executed, times |
| `adapter_manifest` | adapter ID/version, protocol, roles, offered capabilities/permissions, exact package-tree ref; no entrypoint or command |
| `profile` | profile ID/version, skill refs, at most one binding for each role with exact adapter/package/config refs, instance/principal/boundary/authority refs, requested capabilities/permissions; no self source ref; every requested role exists |
| `resolved_profile` | resolver-derived exact profile commit/path/blob, selection ref, manifest/package/config provenance, resolved bindings and validated subsets; no authorization claim |
| `adapter_contract_test_result` | suite/inventory refs, times, overall status, observed cases/errors/assertions and conditional canonical refs; expected phase/fixture/verdict/error/group/assertion IDs live only in inventory |

- `document_ref`: `kind`, `id`, `sha256` of canonical bytes.
- `git_object_ref`: repository ID, full commit, path, `object_type: blob|tree`,
  object algorithm `git-sha1|git-sha256`, and full object ID.
- `content_ref`: media type, locator ID matching the core ID grammar, and SHA-256.
  The core records but never dereferences the locator ID.
- `fixture_ref`: normalized fixture-root-relative path, media type, and SHA-256.
  Validation resolves each real, non-symlink path component beneath the canonical
  root and refuses any escape.
- nested `evidence_record`: evidence ID; proof kind
  `deterministic|behavioral|architecture|independent-review`; verdict
  `passed|failed|inconclusive`; exact request/document digest, attempt ID,
  finish-condition SHA-256, target/source/base/output/release fields required by
  the outcome, profile/qualification/environment/performer/package/config and
  instruction refs; and `proof_ref: content_ref`. The enclosing `stage_result`
  document digest covers the whole nested record. It is not a seventh top-level
  document.
- `scope_ref`: artifact/document ref plus SHA-256 scope digest; used separately for
  selection, qualification, grant, policy, and gate decisions.
- `actor_ref`: provider-scoped stable principal, adapter implementation and instance,
  execution boundary, and optional authority ref. It contains no credential value.
- `environment_ref`: stable ID plus SHA-256 fingerprint.
- `skill_package_ref`: name, canonical `.ystack/skills/<name>` path, format ID, and
  exact Git tree ref. V1 does not inspect `SKILL.md` contents.

### Total status and outcome rules

Outcome is one tagged union:

- `change`: `changed|no-change|inconclusive`
- `check`: `passed|failed|inconclusive`
- `advisory`: `proceed|refine|drop|inconclusive`

`advisory` is not a gate decision. Only an external `gate_decision_ref` records a
human or policy gate.

| Status | `executed` | Outcome | Reason/evidence/output |
|---|---:|---|---|
| `completed` | true | required | all requested evidence kinds; reason if inconclusive |
| `skipped` | false | forbidden | reason required; no output |
| `stale` | false | forbidden | reason plus expected/observed refs; no output |
| `blocked` | false | forbidden | reason required; no output |
| `failed` | false | forbidden | machinery reason and one or more diagnostic `content_ref`s |
| `failed` | true | only inconclusive | reason plus attempt evidence; no successful output |
| `cancelled` | false | forbidden | reason required; no output |
| `cancelled` | true | only inconclusive | reason plus attempt evidence; no successful output |

- `change/changed` requires one or more subject outputs and an exact delta ref. A
  source-code subject also requires a new source revision and bounded Git diff.
- `change/no-change` and `change/inconclusive` forbid subject outputs and delta;
  auxiliary reports remain allowed. `no-change` still requires requested evidence.
- `check/failed` is valid with `completed`: the check ran and found a defect.
- Every inconclusive outcome has reason and durable attempt evidence.
- `change/changed`, `change/no-change`, `check/passed`, and a non-inconclusive
  advisory require every requested evidence verdict to be `passed`.
- `check/failed` requires at least one requested `failed` verdict and no
  `inconclusive` verdict. Any inconclusive outcome requires at least one requested
  `inconclusive` verdict and no `failed` verdict.
- Only `change/changed` may carry subject outputs or delta. Other completed
  outcomes may return auxiliary artifacts, and every evidence record binds them.
  Failed or cancelled work may return diagnostic content refs
  only, never subject outputs, a successful output revision, or a diff. Diagnostics
  never satisfy requested evidence.
- `completed + executed=false`, `skipped|stale|blocked + executed=true`, and any
  unlisted combination fail validation.

### Capability, permission, and separation tables

Initial mappings are exact. `D`, `B`, `A`, and `R` below mean deterministic,
behavioral, architecture, and independent-review evidence.

| Role | Capability | Permissions | Outcome / evidence |
|---|---|---|---|
| producer | `core.harness.plan.v1` | `core.perm.target.read.v1`, `core.perm.scratch.write.v1` | `change` / D,A |
| producer | `core.harness.produce.v1` | `core.perm.target.read.v1`, `core.perm.scratch.write.v1` | `change` / D |
| verifier | `core.verify.run.v1` | `core.perm.target.read.v1`, `core.perm.execution.candidate.v1`, `core.perm.evidence.write.v1` | `check` / D,B,A |
| reviewer | `core.review.read.v1` | `core.perm.target.read.v1`, `core.perm.evidence.write.v1` | `advisory` / R only |
| forge | `core.forge.read.v1` | `core.perm.forge.read.v1` | `check` / D |
| forge | `core.forge.project.v1` | `core.perm.forge.read.v1` | `change` / D |
| ci | `core.ci.observe.v1` | `core.perm.ci.read.v1` | `check` / D |
| execution | `core.execution.provision.v1` | `core.perm.execution.provision.v1` | `check` / D |
| identity | `core.identity.resolve.v1` | `core.perm.identity.read.v1` | `check` / D |
| publisher | `core.publish.branch-bounded.v1` | `core.perm.target.read.v1`, `core.perm.forge.topic-ref.write.v1` | `change` / D |
| publisher | `core.publish.change-request.v1` | `core.perm.target.read.v1`, `core.perm.forge.change-request.write.v1` | `change` / D |
| publisher | `core.publish.comment.v1` | `core.perm.target.read.v1`, `core.perm.forge.comment.write.v1` | `change` / D |
| publisher | `core.publish.status.v1` | `core.perm.target.read.v1`, `core.perm.forge.status.write.v1` | `change` / D |

There is no wildcard or implied prefix. For every binding and operation:

```text
binding.requested_capabilities ⊆ manifest.offered_capabilities
binding.requested_permissions = union(required permissions for requested capabilities)
operation.capability ∈ binding.requested_capabilities
operation.permissions = capability.required_permissions
binding.requested_permissions ⊆ manifest.offered_permissions
if result.executed: result.used_capability = operation.capability
if not result.executed: performer and used_capability are absent
```

For executed work, outcome/evidence must match the table and evidence performer,
package/config, result performer, and used capability must match the binding. For
unexecuted work, `reported_by` records the controller without impersonating the
operation actor. Producer, publisher, and forge cannot manufacture review evidence.

`core.publish.branch-bounded.v1` requires exact repository and policy refs, a
`refs/heads/` topic-ref proposal, expected old tip (or explicit absence), exact new
commit, and delta ref; force/delete fields are forbidden. V1 validates shape,
presence, ref syntax, and internal identity equality only. A later authenticated
publisher must verify real default/protected membership, current tip, ancestry,
actual diff, and atomic compare-and-swap before grant or execution. The operation
cannot express merge.

Producer, verifier, reviewer, and publisher are pairwise incompatible bindings:

| Field | Required rule |
|---|---|
| implementation | may match |
| binding and adapter instance | must differ |
| principal and execution boundary | must differ |
| authority ref ID and scope digest | must differ when present; semantic overlap is later policy |

Each request names one binding, capability, permission set, optional grant ref, and
gate-decision refs. An executed result's performer/used capability match that
binding; an unexecuted result omits both and records only `reported_by`. A reviewer
result can feed a later publisher request as an artifact, but the stages and actors
remain separate.

### Resolver and relational commands

`scripts/core-contract.sh` provides four commands:

```text
validate <file>
resolve <repo> <commit> <selection-ref-file> <profile-path> <manifest-path>...
validate-run <request-file> <resolved-profile-file> <result-file>
validate-suite <suite-result-file> <case-inventory-file> <fixture-root>
```

`validate` enforces canonical bytes, limits, shape, and local invariants. `resolve`
uses exact Git objects and rejects symlinks, missing/wrong objects, config outside
the selected commit, unsafe paths, mismatched adapter versions/packages, subset
violations, and separation conflicts. It records the caller-supplied selection ref
but does not call it trusted or active. `validate-run` performs request/profile/result
and evidence-coverage checks. `validate-suite` verifies fixture digests, conditional
refs, non-vacuous status, and one-for-one equality with an independent canonical
inventory. Each inventory entry fixes case ID, phase, fixture ref, expected verdict
and error, group, and required assertion IDs; the result supplies observations only.
Fixture paths use the same relative-path grammar as Git paths. The command canonicalizes the supplied
root once, rejects symlinks at the root and every child component, and refuses any
physical path outside it. Exit 0 means valid; nonzero writes one of
`E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RESOLVE|E_RELATION|E_SUITE` to stderr
and no success document to stdout.
On success, `validate`, `validate-run`, and `validate-suite` echo the validated
canonical document; `resolve` emits the canonical `resolved_profile`.

The front door uses jq-compatible canonicalization and only jq 1.6 language features.
CI runs an exact jq 1.6 Linux release asset pinned by version and SHA-256, following
the existing ShellCheck supply-chain pattern. The validator never downloads a remote
schema or another language runtime. Input that does not exactly match the canonical
bytes emitted by that path is invalid; duplicate keys and alternate escaped-key
spellings therefore fail before shape use.

### Declarative fake matrix

`scripts/test/fixtures/portable-core-target/` is initialized by the test as an
unrelated Git repo. It contains four distinct package trees and manifests. Each tree
has a canonical fixture response, not executable code. The trusted test driver reads
that response from the exact tree named by the manifest, verifies its tree/content
IDs, and builds canonical request/result records with honest provenance.

Each of the four matrix cases derives two unique requests from one semantic fixture:

1. producer/harness A or B produces the same neutral patch artifact;
2. forge A or B creates the same read-only neutral projection from that artifact.

The four chains share an `equivalence_group`, not a request ID or profile digest.
Comparison includes artifact refs, risk, gate refs, status/outcome, required evidence
semantics, and audit structure. It excludes IDs, times, and adapter/profile provenance,
then separately asserts that those excluded provenance fields identify the actual
different package trees. This proves contract substitution only, not runtime transport.

Negative cases mutate valid canonical fixtures or point at raw invalid bytes. The
case inventory is authored separately from observed results. A case
records its validation phase and includes resolved profile/request/result refs only
when that phase produced them. The suite cannot pass with zero cases/assertions,
changed inventory, or a missing/dropped rejected case.

- `core/v1/contracts.jq` — sole executable shapes, enums, registries, and relational
  checks.
- `scripts/core-contract.sh` — safe canonical front door and the four commands.
- `scripts/test/portable-core-contract.test.sh` — positive, negative, resolver,
  relational, and 2×2 tests.
- `scripts/test/fixtures/portable-core-target/` — unrelated target and four distinct
  declarative fake package trees.
- `.github/workflows/ci.yml`, `ci/required-files.txt`, and README — operator-applied
  CI wiring, restore coverage, CLI contract, and clear unwired status; unattended
  work reaches CI only through `proposals/` until the operator applies it.

1. Canonical parser, limits, shared refs, and six shape validators.
2. Resolver, exact object checks, capability/permission registry, and separation.
3. Run/suite relational checks, evidence coverage, and adversarial cases.
4. Four declarative packages, two-stage 2×2 matrix, CI/manifest/README sync.

## Out of scope

- Real adapters or current-profile activation; generic launchers, registries, executable manifests, or remote schemas.
- Runtime/secret/publisher enforcement, authenticated identity, attestations, evidence storage, or an actual Git write.
- Deciding selection, risk, grant, qualification, policy, gates, or semantic authority overlap; v1 carries refs only.
- Orchestration, deploy/rollback, incidents, evals, telemetry, cost, adoption, or audience interfaces.
- Config-schema or Agent Skills conformance; skill bridges/code; non-Git stores, profile ranges, or universal permissions.
- Changing artifact frontmatter or claiming declarative fakes prove real portability, authorization, or execution.

## Areas of concern

1. **References are not trust.** Exact refs are recoverable claims, not authentication or authority.
2. **Schema labels are not isolation.** They do not prove separate processes, credentials, sandboxes, or networks.
3. **Strict bytes and declarative fakes are narrow proof.** Do not trade checks for readability or overclaim fixtures.
4. **Size needs sign-off.** The plan needs an operator-approved 520–780 line exception, capped at 800.
5. **CI and skills stay gated.** CI is high risk; `.ystack/skills` does not replace live `.claude/skills` here.

## Open questions — disposition

- **Smallest extensible result:** six strict JSON kinds, tagged refs, total status/outcome rules, and inert extensions.
- **Risk/capabilities:** risk and selection/qualification/grant/gate refs stay separate from offers, requests, and use.
- **Canonical skills:** exact `.ystack/skills/<name>` tree refs; bridges and format conformance come later.
- **Compatibility seams:** canonical records, exact manifests, deterministic resolution, closed IDs, and fake substitution.
- **Evidence/test fields:** exact request/scope/output/provenance bindings plus raw fixtures, phases, refs, and assertions.
