---
intent-blob: 3ed8bb434c096ec126d680019a9491ab8a113e31
drafted: 2026-08-28
---

# Spec: portable core contracts

Define the smallest vendor-neutral record family that later adapters can share.
V1 validates five canonical documents, three executable capabilities, and five
permissions. It does not read Git, run an adapter, authenticate a claim, grant
authority, or perform an external write.

## Requirements

- **R1 — five documents.** V1 accepts `adapter_manifest`, `profile`,
  `resolved_profile`, `stage_request`, and `stage_result`. Evidence is nested in a
  result. Policy, qualification, grant, gate, adapter-test, and telemetry bodies
  remain outside core and enter only by immutable ref.
- **R2 — three capabilities.** V1 can produce one artifact, verify one candidate,
  or review one exact change. Publisher, forge, CI, execution, and identity remain
  dormant role IDs with no v1 operation. Unknown/wildcard/prefix/alias capabilities
  fail closed.
- **R3 — five bounded permissions.** Target read, scratch write, candidate execute,
  evidence write, and conditional model invoke have the exact resource/action bounds
  in Design. None grants shell, arbitrary command, environment, general network,
  credential, generic file/Git-ref write, approval, merge, bypass, deploy, or human
  impersonation. Exact instruction bytes arrive by value through the bounded launch
  seam in Design; the adapter gets no content-store read authority.
- **R4 — strict canonical JSON.** A document is exactly one UTF-8 JSON value whose
  bytes equal the pinned jq 1.6 single-root canonicalizer plus one line feed. Reject
  empty/multi-root streams, BOM, invalid UTF-8, duplicate keys, alternate
  whitespace/escaping, floats, negative integers, `null`, unknown fields, and
  non-canonical bytes.
- **R5 — fixed limits and versions.** Reject bytes over 1,048,576, depth over 32, an
  object/array over 256 members, a decoded string over 8,192 UTF-8 bytes, or an
  integer outside `0..2147483647`. Every envelope has exactly
  `schema_version:1`, `kind`, `id`, and `body`; v1 has no extensions. Any new field,
  kind, capability, permission, or changed enum meaning needs a new major.
- **R6 — refs are claims.** Core checks syntax, canonical digests, and relationships
  among caller-supplied documents. It does not prove Git/content existence,
  repository mapping, actor identity, evidence truth, or the authority of a policy,
  selection, qualification, grant, or gate ref.
- **R7 — offer/request/grant/use stay distinct.** A manifest offers. A profile
  requests. A resolved profile records claimed resolution. External policy may
  grant. A request names one operation. A result records observed use. No step
  implies another; there is no `trusted`, `qualified`, `approved`, or `active` flag.
- **R8 — protected roles stay separate.** Producer, verifier, reviewer, and dormant
  publisher bindings differ in binding ID, instance, principal, execution boundary,
  and authority scope. One implementation may serve several roles only through
  those distinct bindings. A human is not an adapter role or capability.
- **R9 — one closed operation per request.** A request binds one runnable resolved
  binding, one capability, its exact permissions/arguments, target and inputs,
  risk/gate claims, environment, finish condition, verification instructions,
  required evidence kinds, and time. The launcher derives one exact instruction set
  from those refs. Retry sequence and message delivery are later concerns.
- **R10 — total result truth.** A result records one terminal status and attempt,
  observed execution facts when work ran, outputs, diagnostics, and evidence.
  Completed conclusive execution equals the request. Failed, cancelled, and
  completed-inconclusive execution preserves different actual facts without
  granting them authority.
- **R11 — evidence is result-bound.** Nested evidence contains only ID, kind,
  verdict, and proof ref. The enclosing result binds the exact request/attempt,
  outputs/delta, profile/qualification, instructions, expected and observed
  execution facts, and time. External users reference `stage_result + evidence ID`;
  they never copy or re-sign the nested body.
- **R12 — actual model/tool facts are honest claims.** Actual provider, model,
  snapshot, effort, prompt, skills, and tools are recorded/computed/unavailable.
  Missing facts carry a reason and are never copied from requested profile values.
  Trace, usage, and cost move to telemetry.
- **R13 — pure validation.** One schema source validates canonical bytes, exact
  shapes, registries, manifest/profile/resolution relations, and
  request/result/status/evidence rules. It never resolves physical repositories,
  launches a process, reads a raw fixture, or evaluates policy.
- **R14 — credible delivery bound.** One jq source, one shell front door,
  table-driven tests, docs, restore entries, and operator-owned CI wiring must fit
  400 normally formatted net lines. If the plan cannot prove that, return to G2;
  no code-golf or size exception is accepted.
- **R15 — no live change.** This work does not activate a profile, extract a real
  adapter, regenerate `/yshifu`, alter an open session, or enable autonomous writes.
  The operator remains the only merge authority.

## Design

### Canonical notation and primitives

Objects are exact; unlisted fields fail. `T?` is omitted-or-present, never `null`.
`set<T>(key,min..max)` is sorted and unique by `key`. `present<T>` is exactly
`{state:"present",value:T}` or `{state:"absent"}`.

Core `ID` matches `^[a-z0-9][a-z0-9._:-]{0,127}$`. `Int` is
`0..2147483647`. `SHA256` is 64 lowercase hex. `Version` is an exact ID.
`ShortText` is 1–1,024 decoded UTF-8 bytes and is never authority. `RawBytes` is an
uninterpreted byte string used only inside the non-persisted transport frame. `Time`
is a real UTC second-level `YYYY-MM-DDTHH:MM:SSZ`. `MediaType` is a lowercase
`type/subtype` token at most 127 characters; `PatchMediaType` is exactly
`text/x-diff`. `GitOID` is 40 lowercase hex for
SHA-1 or 64 for SHA-256. `git-key` is the lexical tuple
`(repository_id,hash_algorithm,commit_id,location kind/value,object_type,object_id,mode)`.
`selector-tuple` is `(kind,input_id-or-scope_sha256-or-empty)`. Both are compared
directly by jq; no nested SHA computation is required.
`ReverseDNS` has at least two lowercase DNS labels; each label is 1–63 alphanumeric
or interior-hyphen characters with no edge hyphen.

Document kinds are the five in R1. `AdapterRole` is `producer`, `verifier`,
`reviewer`, `publisher`, `forge`, `ci`, `execution`, or `identity`. `ActorRole`
adds `operator`, `manager`, `orchestrator`, and `observer`; those additions cannot
be profile bindings or operation performers. Operator attribution is not approval.

The wrapper checks byte size, then runs:

```text
jq -s -S -c 'if length == 1 then .[0] else error("root-count") end'
```

It compares emitted bytes plus one line feed with input before shape checks.

Actual facts use exactly:

```text
{state:"recorded",value:T,source_ref:content_ref}
{state:"computed",value:T,source_ref:content_ref}
{state:"unavailable",reason_id:ID}
{state:"not-applicable"}
```

This union is named `Fact<T>`.

### Shared refs

| Shape | Exact fields |
|---|---|
| `document_ref(K?)` | `{schema_version:1,kind:DocumentKind,id:ID,sha256:SHA256}`; `kind=K` when constrained |
| `git_revision_ref` | `{repository_id:ID,hash_algorithm:"sha1"|"sha256",commit_id:GitOID}`; full 40/64-char ID matches algorithm |
| `git_location` | `{kind:"root"}` or `{kind:"path",value:RepoPath}` |
| `git_object_ref` | `{revision:git_revision_ref,location:git_location,object_type:"blob"|"tree",object_id:GitOID,mode:"100644"|"100755"|"040000"}`; root requires tree; OID length/mode match algorithm/type |
| `content_ref` | `{content_id:ID,media_type:MediaType,sha256:SHA256}`; ID is not URL/path; core never dereferences |
| `artifact_ref` | `{type:"git-object",value:git_object_ref}` or `{type:"content",value:content_ref}` |
| `input_ref` | `{type:"artifact",value:artifact_ref}` or `{type:"document",value:document_ref}` |
| `evidence_ref` | `{stage_result_ref:document_ref(stage_result),evidence_id:ID}` |
| `scope_subject` | `{type:"artifact",value:artifact_ref}` or `{type:"document",value:document_ref}` |
| `scope_ref(P?)` | `{purpose:ScopePurpose,decision_record_ref:content_ref,subject_ref:scope_subject,scope_sha256:SHA256}`; purpose=P when constrained |
| `actor_ref` | `{role:ActorRole,implementation_id:ID,implementation_version:Version,adapter_instance_id:ID,principal_id:ID,execution_boundary_id:ID,authority_ref?:scope_ref(authority)}` |
| `environment_ref` | `{environment_id:ID,fingerprint_sha256:SHA256}` |
| `tool_ref` | `{tool_id:ID,tool_version:Version,package_ref:git_object_ref,config_ref:present<git_object_ref>}` |
| `git_patch_ref` | `content_ref` with `media_type=PatchMediaType` |
| `change_ref` | `{repository_id:ID,base:present<git_revision_ref>,head:git_revision_ref,delta_ref:git_patch_ref}`; revisions match repository |
| `source_value_ref` | `{source:git_object_ref,value_format:"raw-bytes"|"canonical-json",value_sha256:SHA256}`; `canonical-json` requires `source.object_type="blob"` |

`RepoPath` is a non-empty repo-relative POSIX path with no empty, `.`, `..`,
backslash, NUL, or control segment. Root tree is `git_location:{kind:"root"}`, never
an empty path. Symlink/gitlink modes are not representable; physical checks belong
to the resolver.

Scope purposes are `selection`, `repository-context`, `qualification`, `grant`,
`policy`, `authority`, `gate-requirement`, `gate-decision`, `config-contract`,
`output-contract`, `allowed-delta`, `verification-plan`, `review-policy`,
`finish-condition`, and `verification-instructions`. Scope refs carry identity only.
Core never interprets their bytes as authority or lets them change an operation or
permission. Only the exact operation instruction refs use the launch seam below.

`delivered_scope(P)` is exactly `{ref:scope_ref(P),input_id:ID}`. Its subject must be
`{type:"artifact",value:{type:"content",value:content_ref}}`. In a request, its
`input_id` selects exactly one named input whose value equals that complete subject.
The decision-record ref remains acceptance provenance; it is never the instruction
payload.

### Manifest, profile, and resolved profile

Capabilities are exactly `core.harness.produce.v1`, `core.verify.run.v1`, and
`core.review.change.v1`. Permissions are exactly the five defined below.

`adapter_manifest.body` is:

```text
{adapter_version:Version,package_ref:git_object_ref,
 offered_roles:set<AdapterRole>(value,1..8),
 offered_execution_kinds:set<"model"|"deterministic">(value,1..2),
 offered_capabilities:set<CapabilityID>(value,0..3),
 offered_permissions:set<PermissionID>(value,0..5),
 offered_tools:set<tool_ref>(tool_id,0..32),
 config_contract_ref?:scope_ref(config-contract)}
```

`profile_binding` is:

```text
{binding_id:ID,role:AdapterRole,manifest_ref:document_ref(adapter_manifest),
 execution_kind:"model"|"deterministic",adapter_instance_id:ID,principal_id:ID,
 execution_boundary_id:ID,authority_ref?:scope_ref(authority),
 package_ref:git_object_ref,config_ref?:git_object_ref,prompt_ref?:git_object_ref,
 skill_refs:set<git_object_ref>(git-key,0..32),
 requested_tools:set<tool_ref>(tool_id,0..32),model_request?:model_request,
 requested_capabilities:set<CapabilityID>(value,0..1),
 requested_permissions:set<PermissionID>(value,0..5)}
```

`model_request` is `{provider_id:ID,model_id:ID,effort_id:ID}`. Producer/reviewer may
be model-backed. Every model binding requires model request and prompt; every
deterministic binding forbids both. Verifier and all dormant roles are deterministic.
Producer, verifier, reviewer, and publisher bindings occur exactly once. Other roles
are optional and unique by role.

Producer requests only the producer capability; verifier only verifier; reviewer
only reviewer. Dormant roles request zero capabilities/permissions and cannot be
selected by a stage operation. This records compatibility/separation, not activation
or grant. The four protected bindings require authority refs; their binding,
instance, principal, execution-boundary, and authority scope digests are pairwise
different.

`profile.body` is `{profile_version:Version,
bindings:set<profile_binding>(binding_id,4..8)}` and contains no source, selection,
grant, qualification, gate, trust, or activation field.

`resolved_binding` is:

```text
{binding:profile_binding,adapter_implementation:{id:ID,version:Version},
 manifest_source:source_value_ref,package_source:source_value_ref,
 config_source:present<source_value_ref>,prompt_source:present<source_value_ref>,
 skill_sources:set<source_value_ref>(git-key,0..32),
 tool_sources:set<{tool_id:ID,package_source:source_value_ref,
                   config_source:present<source_value_ref>}>(tool_id,0..32)}
```

`resolved_profile.body` is:

```text
{profile_ref:document_ref(profile),profile_source:source_value_ref,
 selection_ref:scope_ref(selection),repository_context_ref:scope_ref(repository-context),
 bindings:set<resolved_binding>(binding.binding_id,4..8)}
```

Profile/manifest sources use `canonical-json` and their value digests equal the
full canonical document bytes, including the final line feed, in their refs. Each
resolved `binding` equals its profile binding, and its manifest ref selects exactly
one supplied manifest. Package/config/prompt/skill/tool source
objects and presence equal their corresponding binding or tool refs; skill/tool
source sets are one-to-one with those refs. A resolved implementation ID/version
equals its manifest document ID/adapter version. Across the resolved profile, one
exact source object has only one format/digest claim; a set cannot contain the same
`git-key` twice.

`validate-profile-set` recomputes supplied document refs and enforces exact manifest
set, binding-ID set, role/execution offer, package/config/tool relations, capability
subsets, permission unions, source relations, and pairwise protected-role
identity/boundary/authority separation. These are claim relations; the resolver owns
Git/repository/object/provenance truth.

### Three capabilities and five permissions

| Capability | Exact arguments | Exact permissions | Outcome / evidence |
|---|---|---|---|
| `core.harness.produce.v1` | `{artifact_kind:"plan"|"structured-artifact",output_contract:delivered_scope(output-contract)}` or `{artifact_kind:"git-patch",allowed_delta:delivered_scope(allowed-delta)}` | target.read + scratch.write + evidence.write; model.invoke iff model | change; deterministic only |
| `core.verify.run.v1` | `{candidate_input_id:ID,verification_plan:delivered_scope(verification-plan),network_mode:"deny"}`; candidate input is target Git tree | target.read + candidate.execute + evidence.write | check; deterministic required, behavioral/architecture optional |
| `core.review.change.v1` | `{change_ref:change_ref,review_policy:delivered_scope(review-policy)}` | target.read + evidence.write; model.invoke iff model | check; independent-review only |

Permission IDs and full meaning:

- `core.perm.target.read.v1`: read only exact target Git revisions/objects and exact
  change delta named by the request; no ref enumeration, cwd, host path, or other
  repository.
- `core.perm.scratch.write.v1`: write only output bytes below a caller-created
  disposable scratch root; no target, Git ref, host config, credential, or external
  write.
- `core.perm.candidate.execute.v1`: run only the fixed verifier implementation
  against the exact target-tree input and referenced verification plan, with network
  denied and no candidate-selected command, credential, inherited secret, host
  mount, or undeclared tool. Control foundation must enforce this before real use.
- `core.perm.evidence.write.v1`: append only proof content for the current attempt
  under scratch; no ordinary output artifact, Git, forge, policy, or prior-result
  mutation.
- `core.perm.model.invoke.v1`: perform only the brokered inference call for the exact
  resolved model/prompt/skill/tool binding. It grants no general network, tool, file,
  or write authority.

No v1 field can express shell/argv/env/eval, executable manifest, URL/API/query,
generic filesystem/network, credential/secret, Git-ref write, CR/comment/label/status,
force/delete, approval/merge/bypass, policy activation, deploy, or human
impersonation.

### Bounded instruction delivery

`operation_instructions(request)` is the three `delivered_scope` values containing
the request's finish condition and verification instructions plus one capability
value: producer output contract or allowed delta, verifier verification plan, or
reviewer review policy. Their input IDs are distinct and differ from the verifier's
candidate input ID. Policy, selection, repository context, qualification, grant,
gate, authority, config contract, and candidate-selected refs are excluded.

The non-persisted v1 transport frame is
`{version:1,request_ref:document_ref(stage_request),items:set<instruction_item>
(purpose,3..3)}`. An item is `{purpose:ScopePurpose,scope_ref:scope_ref,
input_id:ID,content_ref:content_ref,byte_length:Int,bytes:RawBytes}`. Its purpose,
complete scope ref, input ID, and content ref equal one derived `delivered_scope`, its
named input, and that scope's content-artifact subject. It never uses
`decision_record_ref` as payload. The frame is an invocation argument, not a sixth
core document, artifact, capability, permission, or authority record.

Before a real adapter starts, the caller-controlled launcher pushes exactly this
frame. It first checks each raw value is at most 1,048,576 bytes and the total is at
most 3,145,728 bytes. It then hashes the unchanged raw bytes and requires the exact
content ID, media type, SHA-256, byte length, scope ref, input ID, request ref, and
purpose above. Hashing happens before decoding; no newline, Unicode, escape, or
whitespace normalization is allowed. Instruction media type is exactly `text/plain`
or `application/json`. Text is UTF-8 without BOM or NUL. JSON uses the same
single-root canonical byte form and size/depth/member/string/integer limits as
R4/R5, but is not a core envelope. Compression, multipart, missing, extra, duplicate,
oversized, cross-request, or mismatched items stop before adapter execution.

The launcher passes the verified in-memory buffers once. It passes no content-store
handle, path, URL, lookup/list operation, credential, or reusable read capability,
and never re-fetches after checking. Reading these already-delivered call arguments
is not an external-read permission. Their contents may only narrow the selected
capability inside the request's fixed target, arguments, permissions, and evidence
rules. They cannot add authority, tools, network, another input, or executable
shell/argv/env meaning; a conflict with typed fields fails closed. Verifier
instruction buffers never enter the candidate sandbox.

The pure validator checks the request's three exact purposes plus their subject,
input, media-type, and distinct-ID relations. It never accepts the transport frame or
raw bytes. The later launcher/control-foundation boundary enforces the frame before
real use and tests missing, extra, duplicate, oversized, wrong-digest,
cross-purpose/request, re-fetch, candidate-leak, and attempted-lookup cases. Digest
equality proves byte identity only, not acceptance, safety, or execution authority.

### Stage request

`named_input` is `{input_id:ID,value:input_ref}`. `risk_claim` is
`{tier:{namespace:"core",name:"routine"|"high"|"bootstrap"}|
{namespace:ReverseDNS,name:ID},reason_ids:set<ID>(value,1..256),
policy_ref:scope_ref(policy),required_gate_refs:set<scope_ref(gate-requirement)>
(scope_sha256,0..256)}`. Non-core tiers are inert claims to core.

`operation` is `{role:AdapterRole,binding_id:ID,capability_id:CapabilityID,
permissions:set<PermissionID>(value,1..5),arguments:CapabilityArgs}` where args are
selected only by the capability table.

`stage_request.body` is:

```text
{initiative_id:ID,workflow_id:ID,stage_id:ID,task_class_id:ID,requested_by:actor_ref,
 target_repository_id:ID,target_revision:present<git_revision_ref>,
 source:present<artifact_ref>,base:present<git_revision_ref>,
 inputs:set<named_input>(input_id,0..256),
 prior_evidence_refs:set<evidence_ref>((stage_result_ref.sha256,evidence_id),0..256),
 risk:risk_claim,resolved_profile_ref:document_ref(resolved_profile),
 selection_ref:scope_ref(selection),repository_context_ref:scope_ref(repository-context),
 qualification_ref?:scope_ref(qualification),grant_ref?:scope_ref(grant),
 gate_decision_refs:set<scope_ref(gate-decision)>(scope_sha256,0..256),
 environment_ref:environment_ref,operation:operation,
 finish_condition:delivered_scope(finish-condition),
 verification_instruction:delivered_scope(verification-instructions),
 required_evidence_kinds:set<"deterministic"|"behavioral"|"architecture"|
                             "independent-review">(value,1..3),requested_at:Time}
```

Request resolved-profile, selection, and repository-context refs equal the supplied
resolved profile. The binding is non-dormant, owns the capability, and requests the
exact effective permissions; this is compatibility, not activation or grant.
Every Git ref in target revision, base, source, inputs, or reviewer change uses
`target_repository_id`; resolved-profile sources are not target inputs. Verifier
candidate ID selects exactly one input whose value is a Git tree. Reviewer change
head equals the present target revision and change base equals request base. An
absent target revision is allowed only for bootstrap producer work. Required
evidence kinds equal the capability rule: producer and reviewer use their one named
kind; verifier includes deterministic and may also request behavioral and
architecture.

### Stage result and evidence

`outcome` is `{family:"change",value:"changed"|"no-change"|"inconclusive"}` or
`{family:"check",value:"passed"|"failed"|"inconclusive"}`. `reason` is
`{reason_id:ID,summary?:ShortText}`. `output` is
`{output_id:ID,ref:content_ref}`; every output is
scratch content, never a target Git object/revision or write receipt.

`actual_binding` is:

```text
{binding_id:ID,role:AdapterRole,adapter_implementation:{id:ID,version:Version},
 manifest_ref:document_ref(adapter_manifest),package_ref:git_object_ref,
 config_ref:present<git_object_ref>,execution_kind:"model"|"deterministic",
 adapter_instance_id:ID,principal_id:ID,execution_boundary_id:ID,
 authority_ref?:scope_ref(authority)}
```

`observed_capability` is `{kind:"registered",id:CapabilityID}` or
`{kind:"unclassified",id:ID}`. Unclassified is valid only for failed, cancelled, or
completed-inconclusive execution, and its ID is not one of the three registered
capability IDs.

`execution_metadata` is:

```text
{kind:"model"|"deterministic",provider:Fact<ID>,model:Fact<ID>,snapshot:Fact<ID>,
 effort:Fact<ID>,prompt:Fact<git_object_ref>,
 skills:Fact<set<git_object_ref>(git-key,0..32)>,
 tools:Fact<set<tool_ref>(tool_id,0..32)>}
```

Deterministic execution requires provider/model/snapshot/effort/prompt/skills to be
`not-applicable`. Model execution requires each to be recorded/computed/unavailable.
For every execution, tools are recorded, computed, or unavailable—never
not-applicable.

`execution` is `{performer:actor_ref,actual_binding:actual_binding,
environment:environment_ref,used_capability:observed_capability,
metadata:execution_metadata}`.

`evidence` is exactly `{evidence_id:ID,kind:"deterministic"|"behavioral"|
"architecture"|"independent-review",verdict:"passed"|"failed"|"inconclusive",
proof_ref:content_ref}`.

`TerminalStatus` is exactly `completed`, `skipped`, `stale`, `blocked`, `failed`,
or `cancelled`.

`stale_observation` is exactly one of:

```text
{selector:{kind:"target"},observed:present<git_revision_ref>}
{selector:{kind:"source"},observed:present<artifact_ref>}
{selector:{kind:"base"},observed:present<git_revision_ref>}
{selector:{kind:"resolved-profile"},observed:present<document_ref(resolved_profile)>}
{selector:{kind:"qualification"},observed:present<scope_ref(qualification)>}
{selector:{kind:"environment"},observed:present<environment_ref>}
{selector:{kind:"input",input_id:ID},observed:present<input_ref>}
{selector:{kind:"gate-decision",scope_sha256:SHA256},
 observed:present<scope_ref(gate-decision)>}
```

Expected is derived from the selected request field/set member and must differ from
observed in presence or canonical value. Target, source, and base each select their
sole request slot. A present target/base or Git-backed source observation uses the
target repository; a present base keeps the expected hash algorithm when both are
present. A present resolved-profile observation keeps the expected kind/ID; a present
environment keeps the expected environment ID. Input ID selects the exact request
input. Qualification is the request's sole optional qualification. A gate selector
names one exact requested decision by its scope digest. Equal values, wrong
repositories/types, or duplicate selectors fail. No other identity rule is inferred.

`stage_result.body` is:

```text
{request_ref:document_ref(stage_request),resolved_profile_ref:document_ref(resolved_profile),
 attempt_id:ID,attempt_number:Int,reported_by:actor_ref,status:TerminalStatus,
 outcome?:outcome,reason?:reason,
 stale_observations?:set<stale_observation>(selector-tuple,1..256),
 outputs:set<output>(output_id,0..256),delta_ref?:git_patch_ref,
 diagnostics:set<content_ref>(content_id,0..256),execution?:execution,
 evidence:set<evidence>(evidence_id,0..256),started_at?:Time,finished_at?:Time,
 recorded_at:Time}
```

Result `request_ref` equals the recomputed supplied request. Result/profile/request
resolved-profile refs all equal the supplied resolved profile.

| Status | Exact presence and truth rules |
|---|---|
| `completed` | execution, outcome, started/finished required; diagnostics empty and stale absent; exactly one evidence item per requested kind; reason required iff outcome is inconclusive |
| `skipped` | reason required; outputs, diagnostics, evidence empty; every other optional result field absent |
| `stale` | reason plus non-empty differing stale observations; outputs, diagnostics, evidence empty; execution, outcome, delta, and started/finished absent |
| `blocked` | reason required; diagnostics may be empty or non-empty; outputs/evidence empty; execution, outcome, delta, stale, and started/finished absent |
| `failed` | reason and non-empty diagnostics; outputs empty and delta/stale absent; execution optional under the attempt rules below |
| `cancelled` | reason required; diagnostics may be empty or non-empty; outputs empty and delta/stale absent; execution optional under the attempt rules below |

If failed/cancelled has no execution, outcome and started/finished are absent and
evidence is empty. If it has execution, outcome is the requested capability family's
`inconclusive`, started/finished are present, and evidence is non-empty, uses each
kind at most once from the request-allowed set, and every verdict is failed or
inconclusive. Such evidence cannot satisfy the current or a later attempt. Attempt
number is at least 1. Time order is
`requested <= started <= finished <= recorded` with execution and
`requested <= recorded` without it. Orchestrator owns sequence/history.

For completed producer results, any non-passing evidence yields
`change/inconclusive` with no output/delta. Otherwise one output yields
`change/changed`; for `git-patch`, `output.ref` is a `git_patch_ref` and `delta_ref`
is present and equals it. Delta is absent for the other artifact kinds. Empty
output/delta yields
`change/no-change`.
For completed verifier/reviewer results, output/delta are empty: any failed evidence
yields `check/failed`; otherwise any inconclusive evidence yields
`check/inconclusive`; otherwise the result is `check/passed`. Completed-inconclusive
always has a reason.

For completed non-inconclusive execution, actual binding equals the corresponding
projection of the selected resolved binding. Performer is an adapter actor with
those same role/implementation/instance/principal/boundary/authority fields,
environment equals the request, and capability is the requested registered ID.
Recorded/computed provider, model, effort, prompt,
and skills equal the selected model binding; deterministic fields follow the
not-applicable rule. Recorded/computed tools are a subset of requested/offered tools;
an unavailable requested fact makes the result inconclusive. Snapshot has no
requested counterpart and may be unavailable. Failed, cancelled, or
completed-inconclusive execution may differ and preserves observed facts. Any other
difference forbids completed non-inconclusive. Metadata kind matches actual binding.

Evidence IDs and kinds are each unique. Evidence context is the enclosing result.
Producer permits deterministic only;
verifier permits deterministic/behavioral/architecture with deterministic required;
reviewer permits independent-review only. Passing review requires observed reviewer
plus registered `core.review.change.v1`. Wrong performer/capability may carry only
non-passing request-allowed evidence. Prior evidence enters only through
`prior_evidence_refs` and cannot satisfy current evidence.

### Pure validator and delivery

`scripts/core-contract.sh` exposes exactly:

```text
validate-document DOCUMENT
validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...
validate-stage-run REQUEST RESOLVED_PROFILE RESULT
```

No command accepts a repository path, physical root, executable, environment map,
URL, or credential. Success is exit 0 with empty stdout. Failure is nonzero and
starts stderr with `E_USAGE`, `E_RUNTIME`, `E_PARSE`, `E_CANONICAL`, `E_LIMIT`,
`E_SHAPE`, `E_REF`, or `E_RELATION`; input bytes and local paths are not echoed.

Tests build one valid five-document bundle and run at least 60 table-driven
mutations covering canonical roots/limits, exact shapes/enums, root-tree and unsafe
paths, canonical-JSON tree rejection, manifest/profile/source relations, the three
capabilities and five permission bounds, instruction purpose/subject/input closure,
dormant/protected roles, request/result/status/time/output and patch-media rules,
actual-fact incidents, model/tool availability, evidence replay/passing-role rules,
source/base and other stale selectors, generic escapes, and all three commands. They
do not read Git, launch a process, or use a network.

Implementation budget:

| `contracts.jq` area | Lines |
|---|---:|
| canonical/limit/exact-object helpers | 35 |
| primitive/ref/document shapes | 65 |
| capability/permission/profile relations | 45 |
| request/result/status/evidence relations | 60 |
| **jq subtotal** | **205** |

| Other area | Lines |
|---|---:|
| shell wrapper | 30 |
| table-driven tests and tiny fixtures | 135 |
| README, restore manifest, CI wiring | 30 |
| **Total** | **400** |

The plan rejects code golf, long generated lines, copied registries, or a second
parser. If ordinary formatting exceeds 400 lines, return to G2.

### Downstream handoffs and intent questions

1. **Smallest records/refs:** five documents plus the shared refs above. Evidence is
   nested; policy/test/telemetry bodies stay outside core.
2. **V1 capability/permission set:** three capabilities and five permissions.
   Dormant roles preserve identity/separation but cannot execute.
3. **Validator boundary:** canonical shape, lexical refs, offer/request/provenance,
   role separation, and request/result/status/evidence relations. No Git truth,
   authentication, execution, policy truth, or external effect.
4. **Resolver seam:** consume canonical profile/manifests plus caller-owned exact
   sources, selection, repository context, and physical repo map; emit canonical
   resolved profile/source claims. Resolver alone checks Git truth.
5. **Adapter-test seam:** accepted inventory and observations are runner-owned exact
   artifacts supplied as verifier input/proof. Adapter-facing traffic uses only the
   five core docs; runner independently executes, revalidates every core document,
   recomputes assertions/Git facts, and ignores adapter self-reported verdicts. Its
   test-only format is not core schema or authority.

The accepted adapter-test intent still promises a producer/forge 2×2 matrix. This
minimal core has no executable forge capability, so that G2 must wait for a separate
accepted forge contract or return to its own artifact gate under [#159](https://github.com/yihanzhu/ystack/issues/159).
Producer-only proof cannot be called the accepted 2×2.

The operator's recorded [#172 scope-down ruling](https://github.com/yihanzhu/ystack/pull/172#issuecomment-5458286504)
also defers the intent's fixed publisher write. V1 preserves the protected publisher
binding but does not satisfy or activate that write. [#173](https://github.com/yihanzhu/ystack/issues/173)
tracks its one typed operation and permission, plus the other deferred role contracts,
before any publisher can run.

## Out of scope

- Core test-inventory/result kinds, fake runner, fixture/process execution, 2×2,
  timeout/cleanup, and external-target smoke.
- Forge, CI, execution, identity, or publisher operations; GitHub/GitLab/native
  transports; CR/comment/label/status; topic CAS; any external write.
- Git reads, physical repo mapping, object/mode/symlink/replacement checks,
  config/tool provenance truth, authentication, credentials, grants, policy/gate
  evaluation, qualification, sandbox/network enforcement, and kill switch.
- Retry/reconciliation/backpressure, deployment/rollback, production incidents,
  telemetry/trace/usage/cost, packaging/install/migration, skill bridges, non-Git
  stores, or live profile activation.
- Continuing #154, closing parent #153, or claiming these records prove portability,
  authorization, isolation, or correct execution.

## Areas of concern

1. **Dormant roles are not runnable adapters.** Identity fields preserve separation
   only. Adding a capability/permission needs a new major.
2. **Refs and actual facts remain claims.** Core validity is not Git truth, identity,
   evidence authenticity, qualification, or authority.
3. **Runtime controls remain mandatory.** Permission definitions state the allowed
   envelope; control-foundation/adapters must enforce sandbox, credential, network,
   and human-gate boundaries before real use.
4. **Forge 2×2 is unresolved by design.** The existing adapter-test intent must wait
   or be separately rescoped; producer-only proof cannot be called its accepted 2×2.
5. **No implementation exception is accepted.** Strict parsing and the 400-line
   bound cannot be met with a workaround; return to the artifact gate.
6. **CI is a constitution path.** Operator-driven work may edit it; unattended work
   must use `proposals/` and wait for application.
7. **This is user-directed high-risk design.** G2 accepts only this spec, not a plan,
   implementation, proactive work, or activation.
8. **Nothing changes live.** `/yshifu`, manager persona, adapters, and sessions stay
   unchanged. Human merge remains the only merge path.
