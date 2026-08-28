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
- **R2 — one strict JSON family.** Accept seven top-level kinds:
  `stage_request`, `stage_result`, `adapter_manifest`, `profile`,
  `resolved_profile`, `adapter_contract_test_inventory`, and
  `adapter_contract_test_result`. Every valid document is
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
  are objects. Unknown extensions are preserved but inert. Changed meaning, any new
  core field (required or optional), or a changed core enum requires a new major.
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
- **R6 — total status/outcome matrix.** A `stage_result` binds request/profile,
  attempt, reporter, status/outcome/reason, expected/observed identities, outputs,
  diagnostics, evidence, and times. `executed=true` requires exact performer/used
  capability; false forbids performer, used capability, execution metadata, nested
  evidence, and subject/auxiliary outputs. Design defines every combination and
  timestamp order. No machine outcome represents human approval or merge.
- **R6a — actual execution metadata.** `executed=false` forbids metadata; true
  requires a closed `model|deterministic` tagged union. Model requires actual
  provider/model/effort and prompt/skill refs; deterministic forbids model fields.
  Snapshot, trace, token usage, and currency/cost microunits each use
  `recorded|computed|unavailable|not-applicable`; unavailable requires reason, and
  null or invented zero is invalid. Both variants record the sorted unique actual
  tool refs used (empty only when no tool ran). These are run facts, not requests.
- **R7 — evidence covers the request.** Evidence binds request/attempt/finish,
  target/source/base/output/release, profile/qualification/environment/performer,
  package/config/instructions, and proof `content_ref`. Kinds are
  `deterministic|behavioral|architecture|independent-review`; verdicts are
  `passed|failed|inconclusive`. Requested kinds are non-empty/unique and equal the
  completed result's set. Every record binds all subject/auxiliary outputs and the
  resolved performer/package/config. Qualification is absent iff request omits it;
  null is invalid. Prior evidence stays under its exact stage-result ref. Missing,
  changed, replayed, mutable, prose-only, or unbound evidence fails validation.
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
  Producer/reviewer may be model-backed; every other role is deterministic. A model
  binding also requires `core.perm.model.invoke.v1` in manifest and profile.
- **R11 — deterministic, caller-selected resolution.** A profile selects exact
  adapter versions, package trees, skill trees, capabilities, permissions, and
  data-only config refs, with no inheritance, floating range, ambient default,
  executable path, env substitution, remote schema, or literal secret. Resolution
  uses one wrapper for every resolver/driver/test Git call; it exports
  `GIT_NO_REPLACE_OBJECTS=1` before `ls-tree|cat-file|show`. Reads use one exact
  caller commit plus `selection_ref`. Profile source provenance is resolver-derived,
  never self-declared. V1 does not authenticate the caller/selection, and profile
  data cannot override selection, grant, gate, or activation.
- **R12 — relational validation.** Shape validation alone is insufficient.
  Commands validate: one document; profile/manifests into a resolved profile; a
  request + resolved profile + result against explicit repository-ID/path mappings;
  and a complete contract-test result against an external inventory-acceptance ref
  and raw fixtures. Cross-document checks cover exact refs, capability subsets,
  role bindings, evidence coverage, status/outcome rules, risk/gate immutability,
  and request/result identity.
- **R13 — honest fake swap proof.** Four distinct Git package trees represent
  producer/harness A/B and forge A/B as data, never programs. Each case is a producer
  stage then read-only forge projection. One semantic fixture derives four profiles
  and eight requests under one `equivalence_group`. Neutral artifact/risk/gate/result/
  evidence/audit meaning matches; IDs, times, package, and profile provenance differ.
- **R14 — typed contract-test result.** Every case records phase
  `parse|shape|resolve|run|matrix`, observed status/error/assertions, and canonical
  refs only when produced. Independent `adapter_contract_test_inventory` fixes suite
  ID and each case's ID, phase, fixture digest, verdict/error, group, and assertions.
  A separately supplied `inventory_acceptance_ref` scope-ref binds its exact document
  digest; the result carries that same ref. Observations match one-for-one; replaced
  inventories, missing results, changed expectations, dropped/tautological assertions,
  vacuous pass, and fabricated canonical results fail. V1 carries but does not
  authenticate the external acceptance ref.
- **R15 — adversarial cases.** Tests cover malformed and noncanonical JSON;
  limits/version/kind/new fields; missing/wrong repo mappings and unsafe objects;
  replaced inventory/acceptance, unexecuted evidence, bad refs/status/replay;
  capability, permission, role, model/tool metadata, branch, merge/approval/bypass;
  profile injection, package relabeling/replacement objects, and reversed times;
  risk/gate mutation; pass-looking prose; and degraded/empty output. Positive cases
  prove same implementation with separate boundaries.
- **R16 — neutral skill seam.** A profile may carry `skill_package_ref` entries
  for target `.ystack/skills/<name>` trees in the open
  [Agent Skills shape](https://agentskills.io/specification). V1 validates tree/path/
  name/format ID, not YAML or external conformance. Harness roots are later bridges;
  skill text and `allowed-tools` never grant capability.
- **R17 — restore, docs, and delivery bound.** Add every load-bearing file to
  `ci/required-files.txt`, keep scripts executable and ShellCheck 0.11.0 clean, and
  run the hermetic suite in CI against a checksum-pinned jq 1.6. README documents
  the commands, exit behavior, jq minimum, and that the core is not wired live.
  One deterministic PR is expected at 520–780 net lines; the exact plan requests an
  exception capped at 800 or returns to G2. Operator-driven work may edit CI; unattended
  work writes a `proposals/` patch and waits for operator application.

## Design

### Canonical documents and shared refs

All canonical document digests cover the full canonical JSON envelope, not only
payload bytes. Timestamps are UTC RFC 3339 strings. Every JSON integer is in
`0..2147483647`.

| Kind | Required body |
|---|---|
| `stage_request` | initiative, workflow, stage, task class, target/source, inputs, risk, resolved-profile ref, selection ref, qualification ref if any, gate-decision refs, environment, one operation, finish condition, instruction ref, evidence kinds, requested time |
| `stage_result` | request/profile refs, attempt, controller/reporter, `executed`, status/outcome/reason, expected/observed refs, subject/auxiliary/delta/diagnostic refs, nested evidence, performer/used capability iff executed, actual execution metadata, ordered times |
| `adapter_manifest` | adapter ID/version, protocol, `execution_kind`, roles, offered capabilities/permissions, exact package-tree ref; no entrypoint or command |
| `profile` | profile ID/version, skill refs, at most one binding for each role with exact adapter/package/config refs, instance/principal/boundary/authority refs, requested capabilities/permissions; no self source ref; every requested role exists |
| `resolved_profile` | resolver-derived exact profile commit/path/blob, selection ref, manifest/package/config provenance, resolved bindings and validated subsets; no authorization claim |
| `adapter_contract_test_inventory` | suite ID and non-empty unique cases fixing ID, phase, fixture ref/digest, expected verdict/error, equivalence group, and required assertion IDs |
| `adapter_contract_test_result` | exact inventory and external acceptance refs, ordered times, overall status, observed cases/errors/assertions and conditional refs; no expected fields |

- `document_ref`: `kind`, `id`, `sha256` of canonical bytes.
- `git_object_ref`: repository ID, full commit/path, blob|tree type, Git hash algorithm, and full object ID.
- `content_ref`: media type, safe locator ID, and SHA-256; core never dereferences it.
- `fixture_ref`: normalized fixture-root-relative path, media type, and SHA-256.
  Validation resolves real non-symlink components beneath canonical root.
- nested `evidence_record`: ID; closed kind/verdict; request/attempt/finish and
  target/source/base/output/release bindings; profile/qualification/environment/
  performer/package/config/instruction refs; and proof `content_ref`. The enclosing
  stage-result digest covers it; it is not a top-level document.
- `scope_ref`: artifact/document ref plus scope SHA-256 for selection, qualification, grant, policy, or gate.
- `actor_ref`: provider principal, adapter implementation/instance, boundary, and optional authority; no secret.
- `environment_ref`: stable ID plus SHA-256 fingerprint.
- `tool_ref`: stable tool ID/version, exact implementation/package ref, and config digest.
- nested `execution_metadata`: model|deterministic tag; actual model/effort/prompt/
  skill fields when model; availability-tagged snapshot/trace/usage/cost; sorted tool refs.
- `skill_package_ref`: name, `.ystack/skills/<name>` path, format ID, and exact tree; no content parsing.

### Total status and outcome rules

Outcome is one tagged union:

- `change`: `changed|no-change|inconclusive`
- `check`: `passed|failed|inconclusive`
- `advisory`: `proceed|refine|drop|inconclusive`

`advisory` is not a gate decision. Only an external `gate_decision_ref` records a
human or policy gate.

Parsed UTC times satisfy `request.requested_at <= result.started_at <= result.finished_at`;
contract-test start is not after finish. Reversed or unparseable times fail.

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

Only producer and reviewer bindings accept `execution_kind:model`; all other rows
require deterministic. Model bindings add `core.perm.model.invoke.v1`.

There is no wildcard or implied prefix. For every binding and operation:

```text
effective_permissions(capability, binding) = capability.required_permissions
  + core.perm.model.invoke.v1 iff binding.execution_kind = model
binding.requested_capabilities ⊆ manifest.offered_capabilities
binding.requested_permissions = union(effective_permissions for requested capabilities)
binding.requested_permissions ⊆ manifest.offered_permissions
operation.capability ∈ binding.requested_capabilities
operation.permissions = effective_permissions(operation.capability, binding)
if result.executed: result.used_capability = operation.capability
if result.executed: result.execution_metadata.kind = binding.execution_kind
if not result.executed: performer, used_capability, execution_metadata, evidence,
  subject_outputs, and auxiliary_outputs are absent
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
validate-run <request-file> <resolved-profile-file> <result-file> --repo <id>=<path>...
validate-suite <suite-result-file> <inventory-file> <acceptance-ref-file> <fixture-root>
```

`validate` enforces canonical bytes, limits, shape, and local invariants. One shared
wrapper sets `GIT_NO_REPLACE_OBJECTS=1` for every resolver/driver/test Git call.
`resolve` uses exact Git objects and rejects symlinks, missing/wrong objects, config outside
the selected commit, unsafe paths, mismatched adapter versions/packages, subset
violations, and separation conflicts. It records the caller-supplied selection ref
but does not call it trusted or active. `validate-run` requires exactly one physical
Git repo for every referenced repository ID (no extra/duplicate mapping) and verifies
commit, path, mode, object ID, symlink state, request/profile/result relations, and
evidence coverage. `validate-suite` verifies the external acceptance ref matches the
independently supplied typed inventory digest, then checks fixture digests, conditional
refs, non-vacuous status, and one-for-one observations. Each inventory entry fixes case ID, phase, fixture ref, expected verdict
and error, group, and required assertion IDs; the result supplies observations only.
Fixture paths use the Git-path grammar. The command canonicalizes the root, rejects
symlinks at every component, and refuses any
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

1. Canonical parser, limits, shared refs, and seven shape validators.
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

- **Smallest extensible result:** seven strict JSON kinds, tagged refs, total status/outcome rules, and inert extensions.
- **Risk/capabilities:** risk and selection/qualification/grant/gate refs stay separate from offers, requests, and use.
- **Canonical skills:** exact `.ystack/skills/<name>` tree refs; bridges and format conformance come later.
- **Compatibility seams:** canonical records, exact manifests, deterministic resolution, closed IDs, and fake substitution.
- **Evidence/test fields:** exact request/scope/output/provenance bindings plus raw fixtures, phases, refs, and assertions.
