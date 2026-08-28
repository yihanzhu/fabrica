---
intent-blob: 3ed8bb434c096ec126d680019a9491ab8a113e31
drafted: 2026-08-28
---

# Spec: portable core contracts

Define one small, vendor-neutral JSON contract family and a pure validator for it.
The validator checks canonical bytes, document shape, and relationships among
documents supplied by its caller. It never reads Git, runs an adapter, grants
authority, or changes the live ystack profile.

## Requirements

- **R1 — one bounded concern.** This initiative owns canonical records and pure
  validation only. It does not resolve a profile from Git, execute a fake or real
  adapter, run the 2×2 matrix, authenticate a record, grant a permission, publish a
  change, or activate a profile. The current Claude Code, Codex, and GitHub path
  keeps working unchanged.
- **R2 — seven document kinds.** Version 1 accepts exactly `stage_request`,
  `stage_result`, `adapter_manifest`, `profile`, `resolved_profile`,
  `adapter_contract_test_inventory`, and `adapter_contract_test_result`. These are
  the only top-level core documents. Evidence stays inside a stage result. Policy,
  selection, qualification, grant, gate, and inventory-acceptance records stay
  outside the core and enter only through typed immutable references.
- **R3 — strict canonical JSON.** Every document is UTF-8 JSON whose complete bytes
  equal the pinned jq 1.6 single-root canonicalizer defined in Design, followed by
  one line feed. Reject a BOM, invalid UTF-8, an empty stream, more than one root
  JSON value,
  duplicate keys, alternate escaping or whitespace, floats, negative integers,
  `null`, unknown fields, and non-canonical bytes. The full canonical envelope is
  what a document digest covers.
- **R4 — fixed resource limits.** Reject a document over 1,048,576 bytes, nesting
  deeper than 32, an object or array with more than 256 members, a decoded string
  over 8,192 UTF-8 bytes, or an integer outside `0..2147483647`. Arrays that mean a
  set are sorted by their stable ID and contain no duplicates. Arrays whose order
  has meaning are named as ordered lists in this spec.
- **R5 — explicit versioning and inert extensions.** Every envelope has exactly
  `schema_version: 1`, `kind`, `id`, `body`, and optional `extensions`. Unknown
  kinds, versions, and core fields fail closed. Extensions are allowed only at the
  top level. Their keys use a lowercase reverse-domain prefix and `/leaf`; each
  value is an object. They are preserved in canonical bytes but cannot fill a core
  field, add a role/capability/permission, change a result, choose a tool or policy,
  or reach an executor or publisher. Any new core field, including an optional
  field, or changed enum meaning requires a new major schema version.
- **R6 — references are claims, not trust.** The shared reference shapes in Design
  use full digests and safe logical IDs. Pure validation checks their syntax and
  equality only. A valid ref does not prove that content or a Git object exists,
  that a repository ID maps to the right repository, that an actor is authentic,
  or that a policy, selection, qualification, grant, gate decision, evidence
  verdict, or inventory acceptance is authoritative.
- **R7 — one operation per request.** A stage request names one resolved binding,
  one v1 capability, its exact effective permission set, and the capability's exact
  argument object. It also binds the initiative, workflow, stage, task class,
  target/source/input claims, risk claim, profile and environment, finish condition,
  verification instructions, required evidence kinds, and any caller-supplied
  selection, qualification, grant, or gate-decision refs. Retry attempts retain the
  same exact request document ref by later orchestrator policy; this pure validator
  checks one attempt and does not enforce retry sequence. A request cannot express merge, approval, bypass, human
  impersonation, policy activation, arbitrary command execution, or generic network
  access.
- **R8 — total result rules.** A stage result binds one exact request and one
  attempt. It records the controller, terminal status, whether the operation ran,
  the outcome when allowed, reason and diagnostics, expected/observed identities,
  outputs, evidence, actual performer and capability when executed, actual
  execution facts, and ordered times. Every status/outcome combination is defined
  in Design; all others fail. `completed` means the operation finished, not that it
  passed.
- **R9 — actual execution facts stay separate from requested config.** An executed
  result records its actual adapter/package/config, environment, tools, and either
  deterministic or model execution metadata. Every possibly hidden actual model
  fact—provider, model, snapshot, effort, prompt, skills, tools, trace, usage, and
  cost—uses the same typed availability union. Missing facts are `unavailable` with
  a reason, never guessed or copied from the profile. An unexecuted result
  cannot carry a performer, used capability, execution metadata, evidence, or a
  successful output.
- **R10 — evidence is exact and non-transferable.** Each evidence record carries the
  complete `stage_request` document ref, attempt ID/number, finish condition, every
  enclosing output ref, resolved profile, qualification scope when present,
  environment, performer, actual binding/package/config, verification instructions,
  proof bytes, kind, and verdict. A completed result covers exactly the evidence
  kinds requested before execution. Evidence from another request body, attempt,
  output, profile, environment, or instruction version cannot be replayed as current
  proof even if a stable request ID was reused.
- **R11 — risk and authority references stay separate.** Risk is a claim containing
  a tier, reason IDs, policy ref, and required gate refs. Selection, repository
  context, qualification, grant, policy, authority, gate decision, and inventory
  acceptance use distinct `scope_ref.purpose` values and cannot substitute for one
  another. There is no core `trusted`, `authorized`, `qualified`, `approved`, or
  `active` boolean.
- **R12 — offer, request, grant, and use never collapse.** A manifest offers roles,
  capabilities, permissions, and execution kinds. A profile requests a subset. A
  resolved profile records the resolver's claimed deterministic result. An external
  accepted policy/permission record may grant. An executed result records actual
  use. Validation never infers one step from another.
- **R13 — protected roles stay separate.** Producer, verifier, reviewer, and
  publisher bindings are pairwise different in binding ID, adapter instance,
  principal, and execution boundary. Authority record IDs and scope digests also
  differ when present. The same implementation may serve more than one role only
  through those distinct bindings. Producer has no publish permission; verifier has
  no model or forge-write permission; reviewer is exact-change read-only; publisher
  has no model or candidate-execution permission; a human decision is not an
  adapter role or capability.
- **R14 — every v1 capability is closed.** The registry in Design is exhaustive.
  Every capability has one role, one outcome family, an exact argument shape, exact
  permissions, and a closed allowed evidence set with required members. Unknown or
  extra argument fields fail.
  There is no wildcard, prefix match, alias, generic shell/argv/env/URL/API,
  credential read, generic filesystem write, force/delete, merge, approval, bypass,
  deploy, or policy-activation capability.
- **R15 — profile provenance is resolver-produced.** A profile contains requested
  bindings and immutable refs, but no source ref, selection, trust root, grant,
  qualification, gate, or activation claim. `resolved_profile` carries the profile
  and manifest document refs plus source-value, selection, and repository-context
  claims produced by the later resolver. Core validation compares supplied
  documents and subsets but never reads a repository or accepts self-declared
  profile provenance.
- **R16 — test expectations and observations are different records.** The inventory
  alone owns expected phase, verdict/error, equivalence group, fixture digest, and
  assertion IDs. The result contains observations only and binds the exact inventory
  plus an external inventory-acceptance ref. Pure validation checks one-for-one case
  and assertion sets and a correctly derived overall outcome. It does not execute a
  case, authenticate acceptance, or treat a structurally valid pass report as proof.
- **R17 — one pure validator boundary.** `core/v1/contracts.jq` is the only
  executable source of shapes, enums, registries, and relational rules.
  `scripts/core-contract.sh` exposes only the four pure commands in Design. It does
  not read Git, physical repository mappings, raw fixtures, network, environment
  config, executables, or credentials. Success is exit 0 with empty stdout. Failure
  is nonzero, emits one stable error code first, and never echoes untrusted input.
- **R18 — adversarial proof and delivery.** Hermetic tests cover every valid kind,
  every capability argument shape, and the rejection matrix in Design. Tests derive
  mutations from small valid baselines; they do not run an adapter or use a network.
  New load-bearing files enter `ci/required-files.txt`; README states the contract
  and that it is not live-wired. CI runs the suite with checksum-pinned jq 1.6.
  An operator-driven implementation may update `.github/workflows/ci.yml`; an
  unattended implementation must submit that constitution change under
  `proposals/` for operator application.
- **R19 — normal review size.** The implementation budget is at most 220 net lines
  for `contracts.jq`, 45 for the wrapper, 100 for table-driven tests, and 35 for
  docs, manifest, and CI: 400 net lines total. The plan must validate these estimates
  before code. If it cannot meet them without dropping a requirement, return to G2
  and reduce or split v1. This spec does not accept the old #154 size exception.

## Design

### Canonical envelope and primitive rules

Core IDs match `^[a-z0-9][a-z0-9._:-]{0,127}$`. SHA-256 values are 64 lowercase
hex characters. Versions are exact IDs, never ranges. Optional fields are omitted;
`null` is always invalid.

An extension key has two or more lowercase DNS labels, each 1–63 characters with
no leading or trailing hyphen, then `/`, then a 1–128 character lowercase leaf made
from letters, digits, `.`, `_`, or `-`. For example, `com.example/trace` is valid;
`trace`, `Com.example/x`, and `com..example/x` are not.

The wrapper checks the byte limit before parsing. It invokes pinned jq 1.6 as
`jq -s -S -c 'if length == 1 then .[0] else error("root-count") end'`, which rejects
empty and multi-value streams before selecting the one root and emitting canonical
bytes. It compares those bytes with the original, then applies depth, member,
string, integer, shape, and relational checks. The byte comparison makes a duplicate
key or alternate escape non-canonical even though jq would otherwise keep only the
final decoded key. Regression tests protect that boundary.

### Normative schema notation and shared shapes

All objects below are exact: a field not listed is invalid. `T?` means the field may
be omitted; `set<T>(key,min..max)` is a JSON array sorted by `key`, unique by that
key, and within the stated cardinality; `list<T>(min..max)` preserves order.
`present<T>` is exactly `{state:"present",value:T}` or `{state:"absent"}`.
`availability<T>` is exactly one of:

```text
{state:"recorded",value:T,source_ref:content_ref}
{state:"computed",value:T,source_ref:content_ref}
{state:"unavailable",reason_id:ID}
{state:"not-applicable"}
```

`ShortText` is 1–1,024 decoded UTF-8 bytes and is always untrusted prose. `Time` is
the UTC value defined below. `Version` is an exact core ID. `MediaType` is a
lowercase media type matching
`^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$`.
`GitOID` is 40
lowercase hex characters for SHA-1 or 64 for SHA-256. `RepoPath` follows the lexical
rules below. `TopicRef` is `refs/heads/` plus slash-separated 1–64 character
segments made from lowercase letters, digits, `.`, `_`, or `-`; no segment is `.`,
`..`, ends in `.` or `.lock`, or contains `..`. `IdempotencyKey` is an `ID`.
`ExtensionPrefix` is the reverse-domain portion of the extension-key grammar.
`canonical-sha256` as a set key means SHA-256 of the nested value's canonical JSON;
`value` means the primitive string itself.
`ErrorCode` matches `^E_[A-Z][A-Z0-9_]{0,62}$`; it is not a lowercase core `ID`.

The adapter-role registry is exactly `producer`, `verifier`, `reviewer`, `forge`,
`ci`, `execution`, `identity`, and `publisher`. Actor roles may also be `operator`,
`manager`, `orchestrator`, or `observer`; those four can request/report but cannot
be an adapter binding or operation performer. Human approval is not an actor role.
An `operator` actor ref is attribution only and never a human decision record.

| Shape | Exact object |
|---|---|
| `document_ref(K?)` | `{schema_version:1,kind:DocumentKind,id:ID,sha256:SHA256}`; when `K` is supplied, `kind=K` |
| `git_revision_ref` | `{repository_id:ID,hash_algorithm:"sha1"|"sha256",commit_id:GitOID}` with matching hash length |
| `git_object_ref` | `{revision:git_revision_ref,path:RepoPath,object_type:"blob"|"tree",object_id:GitOID,mode:"100644"|"100755"|"040000"}`; object ID length matches `revision.hash_algorithm`; tree requires `040000`, blob requires `100644|100755` |
| `content_ref` | `{content_id:ID,media_type:MediaType,sha256:SHA256}`; the ID is not a URL or host path |
| `artifact_ref` | `{type:"git-object",value:git_object_ref}` or `{type:"content",value:content_ref}` |
| `evidence_ref` | `{stage_result_ref:document_ref(stage_result),evidence_id:ID}` |
| `input_value_ref` | tagged `{type:"artifact",value:artifact_ref}` or `{type:"document",value:document_ref}`; prior evidence has its own field |
| `claim_value_ref` | tagged `{type:"artifact",value:artifact_ref}`, `{type:"document",value:document_ref}`, `{type:"git-revision",value:git_revision_ref}`, `{type:"scope",value:scope_ref}`, or `{type:"environment",value:environment_ref}` |
| `source_value_ref` | `{source:git_object_ref,value_format:"raw-bytes"|"canonical-json",value_sha256:SHA256}` |
| `scope_subject_ref` | tagged `{type:"document",value:document_ref}` or `{type:"artifact",value:artifact_ref}` |
| `scope_ref(P?)` | `{purpose:ScopePurpose,decision_record_ref:content_ref,subject_ref:scope_subject_ref,scope_sha256:SHA256}`; when `P` is supplied, `purpose=P` |
| `actor_ref` | `{role:ActorRole,implementation_id:ID,implementation_version:Version,adapter_instance_id:ID,principal_id:ID,execution_boundary_id:ID,authority_ref?:scope_ref(authority)}` |
| `environment_ref` | `{environment_id:ID,fingerprint_sha256:SHA256}` |
| `tool_ref` | `{tool_id:ID,tool_version:Version,package_ref:artifact_ref,config_sha256:SHA256}` |
| `change_ref` | `{repository_id:ID,base:git_revision_ref,head:git_revision_ref,delta_ref:content_ref}`; both revisions use `repository_id` |

`ScopePurpose` is exactly `selection`, `repository-context`, `qualification`,
`grant`, `policy`, `authority`, `gate-requirement`, `gate-decision`, `inventory-acceptance`,
`config-contract`, `output-contract`, `allowed-delta`, `verification-plan`,
`review-policy`, `check-set`, `environment-policy`, `publisher-policy`,
`finish-condition`, or `verification-instructions`. A field expecting one purpose
rejects every other purpose.

A `RepoPath` has no leading or trailing slash, empty segment, `.` or `..` segment,
backslash, NUL, or ASCII control character. These are lexical checks only. The
profile resolver owns physical repository mapping, object existence, mode, symlink
containment, replacement-object disabling, and source provenance.

For `source_value_ref`, `raw-bytes` means SHA-256 of the exact Git object payload;
`canonical-json` means SHA-256 of the complete canonical JSON bytes and is valid
only for a blob. Core validates the tag, hash, and blob restriction but never reads
those bytes.

### Exact nested records

- `model_request` is `{provider_id:ID,model_id:ID,effort_id:ID}`.
- `profile_binding` is exactly `{binding_id:ID,role:AdapterRole,
  manifest_ref:document_ref(adapter_manifest),execution_kind:"model"|"deterministic",
  adapter_instance_id:ID,principal_id:ID,execution_boundary_id:ID,
  authority_ref?:scope_ref(authority),package_ref:git_object_ref,
  config_ref?:git_object_ref,prompt_ref?:git_object_ref,
  skill_refs:set<git_object_ref>(canonical-sha256,0..256),
  requested_tool_refs:set<tool_ref>(tool_id,0..256),model_request?:model_request,
  requested_capabilities:set<CapabilityID>(value,1..256),
  requested_permissions:set<PermissionID>(value,1..256)}`. `model_request` and
  `prompt_ref` are required exactly when `execution_kind=model`. Tool refs inside a
  manifest or profile require a `git-object` package ref.
- `resolved_binding` is exactly `{binding:profile_binding,
  adapter_implementation:{id:ID,version:Version},
  manifest_source:source_value_ref,package_source:source_value_ref,
  config_source?:source_value_ref,prompt_source?:source_value_ref,
  skill_sources:set<source_value_ref>(canonical-sha256,0..256),
  tool_sources:set<source_value_ref>(canonical-sha256,0..256)}`. Optional/source set
  presence and source object refs exactly match the binding refs they claim to resolve.
- `named_input` is `{input_id:ID,value:input_value_ref}`.
- `risk_claim` is `{tier:{namespace:"core",name:"routine"|"high"|"bootstrap"}
  |{namespace:ExtensionPrefix,name:ID},reason_ids:set<ID>(value,1..256),
  policy_ref:scope_ref(policy),required_gate_refs:set<scope_ref(gate-requirement)>
  (scope_sha256,0..256)}`. A non-core tier is inert.
- `operation` is `{role:AdapterRole,binding_id:ID,capability_id:CapabilityID,
  permissions:set<PermissionID>(value,1..256),arguments:CapabilityArgs}` where the
  argument schema is selected only by `capability_id` from the registry below.
- `Outcome` is exactly `{family:"change",value:"changed"|"no-change"|
  "inconclusive"}`, `{family:"check",value:"passed"|"failed"|"inconclusive"}`,
  or `{family:"advisory",value:"proceed"|"refine"|"drop"|"inconclusive"}`.
- `TerminalStatus` is exactly `completed`, `skipped`, `stale`, `blocked`, `failed`,
  or `cancelled`. `EvidenceKind` is exactly `deterministic`, `behavioral`,
  `architecture`, or `independent-review`.
- `reason` is `{reason_id:ID,summary?:ShortText}`. Summary text never drives a tool,
  status, label, permission, or gate.
- `output_record` is `{output_id:ID,purpose:"subject"|"auxiliary"|"release",
  ref:input_value_ref}`. Output sets sort by `output_id`.
- `actual_binding` is `{binding_id:ID,
  adapter_implementation:{id:ID,version:Version},
  manifest_ref:document_ref(adapter_manifest),
  package_ref:git_object_ref,config_ref?:git_object_ref,execution_kind:"model"|
  "deterministic",adapter_instance_id:ID,principal_id:ID,
  execution_boundary_id:ID,authority_ref?:scope_ref(authority)}`.
- `usage_value` is `{input_tokens:Int,output_tokens:Int,cache_read_tokens:Int,
  cache_write_tokens:Int}`. `cost_value` is `{currency_id:ID,microunits:Int}`.
- `execution_metadata` is exactly `{kind:"model"|"deterministic",
  provider:availability<ID>,model:availability<ID>,snapshot:availability<ID>,
  effort:availability<ID>,prompt:availability<artifact_ref>,
  skills:availability<set<artifact_ref>(canonical-sha256,0..256)>,
  tools:availability<set<tool_ref>(tool_id,0..256)>,trace:availability<content_ref>,
  usage:availability<usage_value>,cost:availability<cost_value>}`. Deterministic
  execution requires provider/model/snapshot/effort/prompt/skills to be
  `not-applicable`; model execution requires each of those fields to be recorded,
  computed, or unavailable, never not-applicable.
- `evidence_record` is exactly `{evidence_id:ID,
  request_ref:document_ref(stage_request),attempt_id:ID,attempt_number:Int,
  finish_condition_ref:scope_ref(finish-condition),
  resolved_profile_ref:document_ref(resolved_profile),
  qualification_ref?:scope_ref(qualification),environment_ref:environment_ref,
  performer:actor_ref,actual_binding:actual_binding,
  verification_instruction_ref:scope_ref(verification-instructions),
  outputs:set<output_record>(output_id,0..256),delta_ref?:content_ref,
  kind:EvidenceKind,
  verdict:"passed"|"failed"|"inconclusive",proof_ref:content_ref}`.
- `stale_selector` is `{kind:"target"|"source"|"base"|"selection"|
  "repository-context"|"qualification"|"grant"|"environment"|
  "resolved-profile"}`, `{kind:"input",input_id:ID}`, or
  `{kind:"gate-decision",scope_sha256:SHA256}`. It can name only a baseline that
  exists as a field or set member in the request.
- `stale_comparison` is `{selector:stale_selector,
  expected:present<claim_value_ref>,observed:present<claim_value_ref>}`. Validator
  derives `expected` from the selected request baseline and requires exact equality.
  Observed uses the same semantic type when present: same document kind; same
  artifact variant; same Git repository/hash algorithm/path/object type/mode, or
  same content ID/media type; same document kind/schema/ID; same scope purpose and
  decision-record/content identity plus subject logical identity; or same
  environment ID. Presence or canonical value must differ.
- `test_assertion_result` is `{assertion_id:ID,passed:Boolean}`.
- `test_case` is `{case_id:ID,phase:TestPhase,fixture_ref:artifact_ref,
  expected_status:"accepted"|"rejected"|"transport-failed",
  expected_error_code?:ErrorCode,equivalence_group?:ID,
  assertion_ids:set<ID>(value,1..256)}`. Error is forbidden for `accepted` and
  required otherwise.
- `test_observation` is `{case_id:ID,phase:TestPhase,
  observed_status:"accepted"|"rejected"|"transport-failed"|"inconclusive",
  observed_error_code?:ErrorCode,produced_document_refs:set<document_ref>(sha256,0..256),
  assertions:set<test_assertion_result>(assertion_id,1..256)}`. Error is forbidden
  for accepted and required otherwise.

### Exact top-level document bodies

The envelope `id` is respectively the adapter ID, profile ID, resolved-profile ID,
stable request ID, result ID, inventory ID, or contract-test-result ID. Body fields
do not repeat it.

- `adapter_manifest.body` is `{adapter_version:Version,protocol_version:
  "core-stage/v1",package_ref:git_object_ref,
  offered_roles:set<AdapterRole>(value,1..8),
  offered_execution_kinds:set<"model"|"deterministic">(value,1..2),
  offered_capabilities:set<CapabilityID>(value,1..256),
  offered_permissions:set<PermissionID>(value,1..256),
  offered_tool_refs:set<tool_ref>(tool_id,0..256),
  config_contract_ref?:scope_ref(config-contract)}`.
- `profile.body` is `{profile_version:Version,
  bindings:set<profile_binding>(binding_id,1..8)}` with at most one binding per
  adapter role. It contains no source, selection, trust, grant, qualification,
  gate, or activation field.
- `resolved_profile.body` is `{profile_ref:document_ref(profile),
  profile_source:source_value_ref,selection_ref:scope_ref(selection),
  repository_context_ref:scope_ref(repository-context),
  bindings:set<resolved_binding>(binding.binding_id,1..8)}`. Profile source uses
  `canonical-json` and its value digest equals `profile_ref.sha256`.
- `stage_request.body` is `{initiative_id:ID,workflow_id:ID,stage_id:ID,
  task_class_id:ID,requested_by:actor_ref,target_ref:git_revision_ref,
  source:present<artifact_ref>,base:present<git_revision_ref>,
  inputs:set<named_input>(input_id,0..256),
  prior_evidence_refs:set<evidence_ref>(stage_result_ref.sha256+evidence_id,0..256),risk:risk_claim,
  resolved_profile_ref:document_ref(resolved_profile),
  selection_ref:scope_ref(selection),
  repository_context_ref:scope_ref(repository-context),
  qualification_ref?:scope_ref(qualification),grant_ref?:scope_ref(grant),
  gate_decision_refs:set<scope_ref(gate-decision)>(scope_sha256,0..256),
  environment_ref:environment_ref,operation:operation,
  finish_condition_ref:scope_ref(finish-condition),
  verification_instruction_ref:scope_ref(verification-instructions),
  required_evidence_kinds:set<EvidenceKind>(value,1..4),requested_at:Time}`.
- `stage_result.body` is `{request_ref:document_ref(stage_request),
  resolved_profile_ref:document_ref(resolved_profile),attempt_id:ID,
  attempt_number:Int,reported_by:actor_ref,executed:Boolean,status:TerminalStatus,
  outcome?:Outcome,reason?:reason,
  stale_comparisons?:set<stale_comparison>(canonical-sha256,1..256),
  outputs:set<output_record>(output_id,0..256),delta_ref?:content_ref,
  diagnostics:set<content_ref>(content_id,0..256),performer?:actor_ref,
  used_capability?:CapabilityID,actual_binding?:actual_binding,
  execution_metadata?:execution_metadata,
  evidence:set<evidence_record>(evidence_id,0..256),started_at?:Time,
  finished_at?:Time,recorded_at:Time}`. Presence follows the total status table.
- `adapter_contract_test_inventory.body` is `{inventory_version:Version,
  cases:set<test_case>(case_id,1..256)}`.
- `adapter_contract_test_result.body` is `{inventory_ref:
  document_ref(adapter_contract_test_inventory),inventory_acceptance_ref:
  scope_ref(inventory-acceptance),runner:actor_ref,environment_ref:environment_ref,
  execution_metadata:execution_metadata,started_at:Time,finished_at:Time,
  recorded_at:Time,overall:"passed"|"failed"|"inconclusive",
  observations:set<test_observation>(case_id,1..256)}`. Runner role is `verifier`,
  execution metadata is deterministic, and `started_at <= finished_at <= recorded_at`.

The resolver must not copy a profile-declared source because no such field exists.
`validate-profile-set` recomputes document refs from supplied canonical files and
checks every binding, source presence, subset, and equality rule above. It cannot
prove any Git read.

### Status, outcome, and evidence rules

Outcome is one tagged union:

- `change`: `changed`, `no-change`, or `inconclusive`;
- `check`: `passed`, `failed`, or `inconclusive`;
- `advisory`: `proceed`, `refine`, `drop`, or `inconclusive`.

An advisory is data for a later gate. It is never approval or a gate decision.

| Status | Executed | Outcome and allowed records |
|---|---:|---|
| `completed` | true | outcome required; full requested evidence required |
| `skipped` | false | no outcome; reason required; no performer/evidence/output |
| `stale` | false | no outcome; reason and one or more differing stale comparisons required; no performer/evidence/output |
| `blocked` | false | no outcome; reason required; diagnostics allowed; no performer/evidence/output |
| `failed` | false | no outcome; machinery reason and diagnostics required; no performer/evidence/output |
| `failed` | true | only an inconclusive outcome; reason, diagnostics, and attempt evidence required; no successful subject output or delta |
| `cancelled` | false | no outcome; reason required; no performer/evidence/output |
| `cancelled` | true | only an inconclusive outcome; reason and attempt evidence required; no successful subject output or delta |

Outcome is present exactly when `executed=true`. Performer, used capability,
actual binding, execution metadata, start time, and finish time are also present
exactly when executed. Reason is required for every non-completed status and every
inconclusive outcome; it is forbidden for a completed non-inconclusive outcome.
`stale_comparisons` is present exactly for `stale`; every expected value is derived
from its request selector, every observed value is type-compatible, and every pair
differs. Diagnostics are non-empty for
`failed`, may be non-empty for `blocked` or `cancelled`, and are empty otherwise.

Every result has `recorded_at`. An unexecuted result omits start/finish times and
requires `request.requested_at <= recorded_at`. An executed result requires
`requested_at <= started_at <= finished_at <= recorded_at`. Times are real UTC
calendar values in exact second-level `YYYY-MM-DDTHH:MM:SSZ` form. Attempt number
must be at least 1. Monotonic attempt numbering, duplicate delivery, and retry
continuity require history and belong to the durable orchestrator.

Only `change/changed` may have subject or release outputs and a delta ref. It
requires at least one subject output and the delta.
`change/no-change` and `change/inconclusive` forbid both. Auxiliary artifacts are
allowed only on completed outcomes and are bound by every evidence record.
Diagnostics never satisfy requested evidence.

Evidence kinds are exactly `deterministic`, `behavioral`, `architecture`, and
`independent-review`; verdicts are `passed`, `failed`, and `inconclusive`. A
completed result has at least one evidence record for every requested kind, no
unrequested kind, and unique evidence IDs. `check/passed`, `change/changed`,
`change/no-change`, and non-inconclusive advisory outcomes require all requested
evidence to pass. For a completed result, failed evidence takes precedence: a check-family result is
`check/failed`; a change/advisory result is its family's `inconclusive`. If there is
no failed evidence but at least one inconclusive verdict, every family uses its
`inconclusive` value. `check/failed` therefore requires at least one failed verdict
and may retain inconclusive verdicts. A family-inconclusive outcome requires at
least one failed or inconclusive verdict. No true verdict is discarded.

For `failed|cancelled + executed=true`, evidence is non-empty, its kinds are a
subset of the request's required kinds, every verdict is `failed` or
`inconclusive`, at least one is non-passing, and its output set is empty. It records only the interrupted attempt and cannot satisfy a
later completed result. An unexecuted result has an empty evidence set.

`validate-stage-run` recomputes the complete request document ref and requires it
to equal the result and every nested evidence `request_ref`. Evidence attempt values
equal the enclosing result. Finish condition, profile, qualification presence,
environment, verification instructions, performer, actual binding, every output
record, and delta presence/value also equal the request/result/binding values exactly. Every evidence
record on a completed result covers the complete output set. Prior-stage evidence
appears only in `request.prior_evidence_refs`; its body is never copied into the new
result.

For an executed result, `performer` matches the selected resolved binding's role,
implementation, instance, principal, and boundary. `actual_binding` matches that
binding's manifest/package/config and execution kind. Execution metadata kind
matches it too. All nested evidence repeats those exact performer, binding, and
environment values. These are equality checks over claims, not identity proof.

Every possibly hidden model fact uses `availability<T>` as defined above. A profile
model request is desired configuration only and cannot fill an actual result field.

### Capability, permission, and argument registry

The permission registry is the union of the full IDs in this table plus the
conditional `core.perm.model.invoke.v1`. No short name is an alias. Every argument
object has exactly the fields and types shown. `D`, `B`, `A`, and `R` mean
deterministic, behavioral, architecture, and independent-review evidence.
`core.perm.record.read.v1` reads only canonical core documents named by supplied
`document_ref`s; `core.perm.content.read.v1` reads only bytes named by supplied
`content_ref`s. Neither permits path, directory, database, generic network, or
credential reads.

| Role / capability | Exact arguments | Exact base permissions | Outcome / allowed evidence; required |
|---|---|---|---|
| producer / `core.harness.plan.v1` | `{output_contract_ref:scope_ref(output-contract)}` | `core.perm.target.read.v1`, `core.perm.scratch.write.v1` | change / `{A}`; A |
| producer / `core.harness.produce.v1` | `{deliverable_kind:"git-patch"|"structured-artifact",allowed_delta_ref:scope_ref(allowed-delta)}` | `core.perm.target.read.v1`, `core.perm.scratch.write.v1` | change / `{D}`; D |
| verifier / `core.verify.run.v1` | `{verification_plan_ref:scope_ref(verification-plan),network_mode:"deny"}` | `core.perm.target.read.v1`, `core.perm.execution.candidate.v1`, `core.perm.evidence.write.v1` | check / `{D,B,A}`; D |
| reviewer / `core.review.check.v1` | `{change_ref:change_ref,review_policy_ref:scope_ref(review-policy)}` | `core.perm.target.read.v1`, `core.perm.evidence.write.v1` | check / `{R}`; R |
| reviewer / `core.review.advise.v1` | `{change_ref:change_ref,review_policy_ref:scope_ref(review-policy)}` | `core.perm.target.read.v1`, `core.perm.evidence.write.v1` | advisory / `{R}`; R |
| forge / `core.forge.observe.v1` | `{observation_kind:ForgeObservation,subject:ForgeSubject}` | `core.perm.forge.read.v1` | check / `{D}`; D |
| ci / `core.ci.observe.v1` | `{repository_id:ID,commit_ref:git_revision_ref,check_set_ref:scope_ref(check-set),required_only:true}` | `core.perm.ci.read.v1` | check / `{D}`; D |
| execution / `core.execution.provision.v1` | `{environment_spec_ref:scope_ref(environment-policy),input_snapshot_ref:git_object_ref,network_mode:"deny",tool_refs:set<tool_ref>(tool_id,0..256)}` | `core.perm.execution.provision.v1` | check / `{D}`; D |
| identity / `core.identity.resolve.v1` | `{subject_actor_ref:actor_ref,purpose:"performer"|"verifier"|"reviewer"|"publisher"|"observer"}` | `core.perm.identity.read.v1` | check / `{D}`; D |
| publisher / `core.publish.branch-bounded.v1` | `{repository_id:ID,publisher_policy_ref:scope_ref(publisher-policy),topic_ref:TopicRef,expected_old_tip:present<git_revision_ref>,new_commit_ref:git_revision_ref,delta_ref:content_ref,idempotency_key:IdempotencyKey}` | `core.perm.target.read.v1`, `core.perm.content.read.v1`, `core.perm.forge.read.v1`, `core.perm.forge.topic-ref.write.v1` | change / `{D}`; D |
| publisher / `core.publish.change-request.v1` | `{repository_id:ID,publisher_policy_ref:scope_ref(publisher-policy),source_result_ref:document_ref(stage_result),head_ref:{name:TopicRef,commit:git_revision_ref},base_ref:git_revision_ref,title_ref:content_ref,body_ref:content_ref,draft:Boolean,idempotency_key:IdempotencyKey}` | `core.perm.target.read.v1`, `core.perm.record.read.v1`, `core.perm.content.read.v1`, `core.perm.forge.read.v1`, `core.perm.forge.change-request.write.v1` | change / `{D}`; D |
| publisher / `core.publish.comment.v1` | `{repository_id:ID,publisher_policy_ref:scope_ref(publisher-policy),subject:{kind:"issue"|"change-request",id:ID},source_result_ref:document_ref(stage_result),body_ref:content_ref,idempotency_key:IdempotencyKey}` | `core.perm.record.read.v1`, `core.perm.content.read.v1`, `core.perm.forge.comment.write.v1` | change / `{D}`; D |
| publisher / `core.publish.status.v1` | `{repository_id:ID,publisher_policy_ref:scope_ref(publisher-policy),commit_ref:git_revision_ref,source_result_ref:document_ref(stage_result),context_id:ID,state:"success"|"failure"|"neutral",details_ref?:content_ref,idempotency_key:IdempotencyKey}` | `core.perm.record.read.v1`, `core.perm.content.read.v1`, `core.perm.forge.read.v1`, `core.perm.forge.status.write.v1` | change / `{D}`; D |

`ForgeObservation` is exactly `repository-identity`, `default-branch`,
`change-request-state`, `approval-state`, `head-base-identity`, `branch-controls`,
or `code-owner-controls`. `ForgeSubject` is `{repository_id:ID}` for repository,
default-branch, branch-control, and code-owner observations, and
`{repository_id:ID,change_id:ID}` for the other three. There is no query, path, URL,
or arbitrary payload.

Both reviewer capabilities require the same exact `change_ref`; they differ only in
outcome family. Advice about a non-change subject belongs to a later manager or
orchestrator contract, not the reviewer role.

Scope-ref arguments carry identity and scope only. They do not embed or expose the
referenced bytes, and v1 defines no command that dereferences them. A later trusted
caller/adapter may use an accepted, separately validated policy or instruction
record, but it cannot reinterpret that record as shell, argv, environment, URL, or
an extra capability under this schema.

Direct work-subject refs equal the request target repository: reviewer changes,
forge subjects, CI commits, a Git execution snapshot, and publisher repository,
head/base/new commits. Change base/head revisions share that repository. Policy,
adapter, package, config, prompt, skill, and tool refs may live in other logical
repositories and instead must match the resolved profile/binding claims. Publisher title,
body, and details refs have media type `text/plain`.
`source_result_ref` appears in the request's named document inputs; pure validation
checks the ref linkage, while the later publisher verifies that the projected bytes
are an allowed output of that result.

`expected_old_tip` is `absent` or a present commit from the same repository. The
later publisher verifies real branch policy, current tip, ancestry, actual delta,
credential scope, and atomic compare-and-swap. Branch arguments cannot express
force, delete, merge, or bypass. Change-request arguments can only ensure/open a
request; they cannot close, merge, approve, or assign a reviewer. Status is a
projection, not a gate result. A generic label write is deliberately absent because
labels may carry gate state; a later fixed projection needs a new core version.

Before any grant or execution, the authenticated publisher must validate the exact
publisher-policy record. For status, it queries the forge controls and rejects a
context used by any required, protected, approval, merge, or production gate. For
change-request and comment text, it dereferences the fixed source output and rejects
mention-like control tokens, provider/bot directives, a line whose first non-space
character is `/`, and control characters. It never rewrites unsafe bytes into safe
ones. If the adapter cannot prove these checks, the capability remains ungranted
and cannot execute. Branch, change-request, and status publishers use their exact
`core.perm.forge.read.v1` immediately before the fixed write and abort on an unknown
or moved control state. This narrows but cannot eliminate the read/write race; later
server-side controls remain required. Core validation checks only the policy ref and
closed proposal shape; it does not claim these external checks already happened.

Only producer and reviewer bindings may use `execution_kind: model`. Their effective
permission set adds exactly `core.perm.model.invoke.v1`; every other role is
deterministic. Request evidence kinds are a subset of the capability's closed
allowed set and include every required kind. Only either review capability may
produce `independent-review` evidence. For every supplied profile set and stage run,
validation enforces:

```text
supplied manifest document refs equal the profile binding manifest-ref set
manifest capability roles are a subset of its offered roles
resolved binding-ID set equals the profile binding-ID set exactly
binding role and execution kind are offered by that manifest
binding package ref equals the manifest package ref
binding config ref is allowed only when the manifest has a config-contract ref
every requested capability belongs to the binding role in the core registry
binding requested tools are a subset of manifest offered tools
profile requested capabilities are a subset of manifest offers
profile requested permissions equal the exact union required by its capabilities
profile requested permissions are a subset of manifest offers
resolved binding.binding equals the profile binding
resolved adapter implementation ID/version equal manifest envelope ID/body version
profile/manifest source-value canonical-json digests equal their document refs
package/config/prompt/skill/tool source presence and object refs equal the binding refs
request resolved-profile ref equals the recomputed supplied resolved-profile ref
request selection/repository-context refs equal supplied resolved-profile body refs
operation binding ID and role equal the selected resolved binding
operation capability belongs to its resolved binding
execution-provision argument tools are a subset of resolved binding requested tools
operation permissions equal that capability's effective permissions
result request/resolved-profile refs equal the supplied request/profile documents
executed result used capability equals the request capability
executed result outcome family equals the request capability registry family
executed result metadata kind equals the resolved binding execution kind
recorded/computed actual tools are a subset of resolved binding requested tools
executed result performer and actual binding equal the resolved binding
performer implementation ID/version and authority presence/value equal that binding
all evidence performer/binding/environment values equal the result and request
```

The core validates only the shape of a publisher proposal and these document
relations. It does not make the write safe or authorized. A valid status proposal
can never stand in for a gate decision.

### Adapter-contract-test records

`TestPhase` is exactly `parse`, `document`, `profile-set`, `stage-run`,
`adapter-run`, or `matrix`. Expected observation is `accepted`, `rejected`, or
`transport-failed`, with an exact stable `ErrorCode` when applicable. The inventory
case set and each assertion-ID set are non-empty, sorted, and unique.

Each result observation has case ID, phase, observed status/error, produced document
refs when any, and one boolean result for every inventory assertion ID. It has no
expected fields. Missing, extra, duplicate, relabelled, or phase-mismatched cases or
assertions fail relational validation; missing execution never becomes a smaller
case set. The result is `inconclusive` if any observation is explicitly
`inconclusive`. Otherwise it is `passed` only when every observed status/error and
assertion matches the inventory, including an expected `transport-failed` case; any
complete mismatch or false assertion derives `failed`.

For a contract-test result, actual tools and trace must be recorded or computed.
If either is unavailable or not-applicable, every observation is `inconclusive` and
the overall result is `inconclusive`; the case set is still complete.

`inventory_acceptance_ref` has purpose `inventory-acceptance` and its subject equals
the inventory document ref. `EXPECTED_ACCEPTANCE_SCOPE` is a file containing exactly
one canonical `scope_ref(inventory-acceptance)` object without a document envelope;
it uses the same jq canonical bytes, limits, and extension-free shared-shape checks.
`validate-test-records` receives that caller-owned trust-context file and requires
object equality with the result field. This proves linkage only. The later
adapter-test runner must independently
execute every case, revalidate every produced document, verify Git through the
resolver-owned boundary, and bind real runner evidence. Copying expected fields into
observations can still form a structurally valid lie; core validation never calls it
proof.

### Pure validator interface and errors

`scripts/core-contract.sh` has exactly these commands:

```text
validate-document DOCUMENT
validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...
validate-stage-run REQUEST RESOLVED_PROFILE RESULT
validate-test-records INVENTORY RESULT EXPECTED_ACCEPTANCE_SCOPE
```

The relational commands receive every document they compare. They recompute each
`document_ref` from the supplied canonical bytes. No command accepts a repository,
physical root, executable, command line, environment map, URL, or credential.

Stable first-token errors are `E_USAGE`, `E_RUNTIME`, `E_PARSE`, `E_CANONICAL`,
`E_LIMIT`, `E_SHAPE`, `E_REF`, and `E_RELATION`. `E_RUNTIME` covers a missing or
wrong jq runtime and internal failure; candidate data cannot turn it into a valid
result. The wrapper never prints document content or local paths in an error.

The implementation files are:

- `core/v1/contracts.jq` — the sole executable contract source, at most 220 net lines;
- `scripts/core-contract.sh` — byte limits, canonical comparison, hashing, and the
  four safe modes, at most 45 net lines;
- `scripts/test/portable-core-contract.test.sh` — table-driven positive and
  adversarial tests with generated mutations, at most 100 net lines;
- small canonical fixtures only when table generation cannot express a byte case;
- README, `ci/required-files.txt`, and operator-applied CI wiring, together at most
  35 net lines. A fixture line consumes the same 400-line total budget.

The line budget depends on one declarative field/capability registry consumed by
generic exact-object, tagged-union, set, and relation helpers. Tests build one valid
seven-document bundle and apply table-driven mutations; they do not duplicate one
fixture per rule. If the plan needs per-capability validators or repeated fixture
trees, the estimate has failed and the work returns to G2 before code.

Implementation order is canonical parser and shared shapes; document shapes and
registry; relational modes and status/evidence rules; then adversarial tests, docs,
restore manifest, and CI. No second parser or copied registry is allowed.

### Required adversarial coverage

Tests reject malformed/noncanonical/oversized JSON; empty or multiple-root streams;
BOM, duplicate/escaped keys,
deep/wide/long data, floats and integer limits; unknown fields/versions/kinds;
invalid error-code or extension keys/values, or an extension used in place of a
required core field; unsafe IDs, refs, paths,
hashes, modes, source provenance, or floating refs; capability wildcards, role
mismatch, extra/missing arguments, command/argv/env/URL/network/secret/entrypoint
fields, permission drift, and model-role drift; shared protected-role bindings;
request/profile/result mismatch, including a changed request body with the same ID;
wrong performer/package/config/environment or independent-review evidence from a
non-reviewer; altered risk/selection/qualification/grant/gate refs; unexecuted
evidence or output; invalid status/outcome/evidence/time rules; replayed proof;
missing resolved bindings, wrong outcome family, free/unbound stale selectors,
mixed evidence precedence errors, and unoffered execution tools;
content-backed or wrong-repository execution snapshots;
changed delta with replayed evidence, performer authority/version drift, missing
or wrong-purpose publisher-policy refs; invalid execution availability shapes,
source-claim refs, and model/deterministic combinations;
the absent generic label capability; empty or replaced inventories;
expected fields in results; dropped/extra/duplicate cases or assertions; mismatched
acceptance scope; and pass-looking prose, silence, empty, or degraded records that
omit required structured fields. Core tests do not judge whether a well-shaped
actual-fact or extension claim is truthful.

Positive cases cover all seven kinds and all thirteen capabilities, including one
adapter implementation used through separate protected bindings. Core tests use
neutral logical IDs and do not special-case ystack. The unrelated Git target,
physical object attacks, fake processes, 2×2 substitution, timeouts, cleanup, and
external-target smoke belong to the two sibling initiatives.
Protected-context lookup and directive-bearing text bytes are required later
publisher/control-foundation tests, not observable core-validator cases.

### Intent questions resolved

1. **Smallest top-level set:** seven kinds. Five describe normal stage/profile
   traffic. Separate inventory and observation records keep expectations outside the
   runner result without creating a second contract family. Evidence and authority
   records remain nested or referenced.
2. **Capabilities and permissions:** the thirteen-row closed registry and fifteen
   permissions above are v1. Every argument field is named and typed. Anything that
   cannot be expressed without a generic command, network request, credential, or
   unbounded write is absent and requires a later major version.
3. **Validator boundary:** core checks canonical bytes, limits, shape, lexical refs,
   closed registries, offer/request relations, protected-role separation,
   request/result/evidence/status/time relations, and inventory/result linkage. It
   does not read Git, authenticate, execute, authorize, or publish.
4. **Profile-resolution seam:** the resolver consumes canonical profile/manifests,
   exact caller-supplied source and repository context, plus selection refs and
   physical repository mappings. It produces canonical `resolved_profile` with
   derived source-value claims. The sibling owns Git algorithms, object/mode/symlink
   checks, replacement-object disabling, provenance derivation, and physical-path
   safety.
5. **Adapter-test seam:** core owns the inventory/result envelopes and pure linkage
   mode. The sibling owns external inventory selection, the fake-only launcher,
   process and credential clearing, independent execution/revalidation, resolver
   calls for Git facts, 2×2 comparison, unrelated-target fixtures, and proof that
   observations came from execution rather than copied expectations.

## Out of scope

- Git reads, repository-ID-to-path mappings, profile resolution, object existence,
  file mode or symlink checks, replacement-object handling, and physical containment.
- Executable manifests, fake or real adapter launch, raw fixture reads, process
  protocol, timeouts, environment/credential clearing, 2×2 execution, and the
  unrelated-target smoke.
- Authentication, credentials, secrets, permission or qualification issuance, risk
  policy evaluation, gate decisions, runtime sandbox/network enforcement, and
  publisher execution, generic label projection, or any actual external write.
- Real/default/alternative adapter extraction, Codex native review, neutral-manager
  implementation, profile activation, migration, packaging, install, or upgrade.
- Durable orchestration, retries, reconciliation, backpressure, kill switch,
  deployment, rollback, incidents, production feedback, eval qualification,
  telemetry aggregation, dashboards, or cost policy.
- Skill migration, bridge generation, YAML or Agent Skills conformance parsing,
  bundled skill execution, non-Git canonical stores, or changes to artifact
  frontmatter.
- Continuing PR #154 or implementation under `portable-control-plane-core`, closing
  the parent roadmap item, or claiming that valid records prove portability,
  authorization, isolation, or correct execution.

## Areas of concern

1. **The old spec is not authority.** PR #154 closed unmerged and superseded. This
   child restates only the record decisions needed now; it does not inherit the old
   resolver or runner design.
2. **Pure validation has a hard honesty boundary.** A Git/content/actor/evidence ref
   remains a claim. Downstream work must not advertise core exit 0 as proof of
   existence, identity, authorization, or execution.
3. **Closed arguments are a G2 blocker.** If implementation needs an argument not
   listed here, it returns to the artifact gate. It cannot add an opaque object,
   command field, or namespaced execution escape.
4. **The runner cannot certify itself.** Inventory/result linkage prevents dropped
   expectations but not fabricated observations. The sibling must independently run
   and revalidate every case before a stage result can carry evidence.
5. **Declarative separation is not isolation.** Distinct IDs and refs do not create
   separate credentials, sandboxes, or processes. Control-foundation work must prove
   those runtime boundaries.
6. **Publisher records are proposals only.** Comment, status, branch, and
   change-request shapes carry no permission to write and cannot project themselves
   into gate authority.
7. **Implementation size may still expose excess scope.** The old 800-line exception
   is gone. If the plan cannot stay within the normal review budget using one schema
   and table-driven tests, reduce v1 or split again rather than weakening checks.
8. **CI is a constitution path.** The implementation plan must identify an
   operator-driven edit or a `proposals/` handoff. G2 merge alone authorizes neither.
9. **No exceptional implementation is accepted here.** If jq limits, duplicate-key
   handling, or portability require an architectural exception, return to the
   accepted-artifact gate before code and satisfy the exceptional implementation
   rule. Do not hide it in a parser workaround.
10. **The north-star marker is intentional.** The ystack-self entry keeps its
    shipped-default marker and operator-history note for adopters. This user-directed
    G2 adds no new proactive authorization and does not approve a live profile change.
11. **This is high-risk architecture.** G2 accepts design only. A later plan must be
    reviewed under the repo's then-live risk gate; nobody may claim a pre-code plan
    gate passed merely because this spec merged.
12. **Nothing activates on merge.** Contract/source changes do not regenerate
    `/yshifu`, replace the manager persona, change adapters, or update an open
    session. The operator remains the only merge authority.
