---
intent-blob: f77fc1fdd8f7af228e7f211740901b265fc545ae
risk: high
drafted: 2026-08-29
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
- **R13 — one contract package, several private owners.** V1 is one versioned
  package with the semantic identity `core.contracts.v1`. Shared types and policy
  tables, profile rules, request rules, result-fact rules, and result-truth rules
  each have one private owner. A later owner may import an earlier one; it may not
  copy a document kind, role, capability, permission, evidence, outcome, shape, or
  acceptance rule into a second home. Product modules never resolve physical
  repositories, launch a candidate process, depend on test fixtures, or evaluate
  policy.
- **R14 — seven ordered child initiatives.** Delivery uses exactly
  `portable-core-schema`, `portable-core-ingress`,
  `portable-core-profile-graph`, `portable-core-stage-request`,
  `portable-core-result-facts`, `portable-core-result-truth`, and
  `portable-core-assembly`. Every child has its own intake, intent, spec with
  `risk: high`, high-risk plan, implementation PR, real CI proof, independent
  review, and human merge. Every child artifact and plan PR tracks its child intake.
  Each child implementation closes that intake. With respect to parent #155, the
  first six implementations use `Tracks #155`; assembly also uses `Closes #155`.
- **R15 — no live change.** This work does not activate a profile, extract a real
  adapter, regenerate `/yshifu`, alter an open session, or enable autonomous writes.
  The operator remains the only merge authority.
- **R16 — partial packages stay private.** The first six children add only private
  package members, test drivers, fixtures, and their exact CI proof. They do not add
  or document a public validator command, install path, profile selection, or live
  caller. Only `portable-core-assembly` may add the public shell command, root
  dispatcher, full-package user documentation, final restore instructions, and
  three public command forms. Every child immediately lists its own restore-critical
  files in `ci/required-files.txt`; assembly owns only the final package/user view.
- **R17 — code loading is fixed.** The assembly wrapper resolves its own physical
  repository root and loads one literal root program plus one literal private module
  directory. It passes jq 1.6 exactly one `-L` directory, which disables jq's builtin
  module search list. Product jq files may use only exact statements of the form
  `import "NAME" as NAME;`, where `NAME` is one of the five accepted module names.
  `include`, import metadata (including `search`), JSON imports, and names containing
  `/`, `.`, `..`, `~`, `$ORIGIN`, or backslash are forbidden. Caller arguments, cwd,
  `HOME`, module-search environment, config, document content, URLs, and ambient jq
  modules cannot select a jq module or shell library. The resolved repository root
  and every package-path directory component are real directories reached without a
  symlink. `scripts/core-contract.sh`, `scripts/lib/core-ingress.sh`,
  `core/v1/contracts.jq`, and every fixed module are regular non-symlink files inside
  that same physical repository. Any mismatch stops as `E_RUNTIME`. These
  restrictions close both search mechanisms documented by the
  [jq 1.6 module rules](https://jqlang.org/manual/v1.6/#modules): the default list
  selected by `-L` and the optional `search` import metadata. Host executables found
  through `PATH` are an operator-controlled runtime dependency, not part of this
  module-search guarantee; CI separately pins the exact jq 1.6 release asset.
- **R18 — every document receives its complete self-check.** Every command applies
  the same ordered per-document pipeline to every supplied document: parsed limits,
  shape, ref syntax, and all self-contained relations owned by that document's
  module. A command may then add only its named cross-document checks. No command may
  choose a smaller version of a document's self-check.
- **R19 — assembly routes; it does not redefine rules.** The root dispatcher owns
  command routing, fixed error order, and composition only. It contains no profile,
  request, result, capability, permission, evidence, or outcome rule. A defect in a
  private owner returns to that child's artifact gate; assembly never patches it by
  copying the rule.
- **R20 — proof is complete by rule, route, and two frozen ledgers.** Every owned
  rule has a stable `<owner>.<name>` rule ID listed in its child spec, direct valid
  and invalid cases, every required command-to-rule route, and a forced-route test.
  Tests keep expected verdicts as literal data and never use product policy as their
  oracle. The parent plan freezes two inventories from PR #183 head
  `ab4a7082f02e67b5748c5c54b9214f37d222f53f`:
  31 discrete review-finding rows from comments 5463604326, 5463851247,
  5464015820, and 5464192510, plus the 279 assertion results emitted in execution
  order by `scripts/test/core-contract.test.sh` at that head. Finding IDs are
  `review-rN-fNN`; assertion IDs are `legacy-test-001` through `legacy-test-279`
  with their original output label. Repeated findings remain separate rows but may
  point to the same new owner/rule. Every finding maps to one owner and closing
  rule/test or a reasoned superseding rule. Every assertion maps to one owner;
  `ported` and `replaced-by` name exact new rule/test IDs, while
  `invalid-old-positive` gives a reason. The required denominators are 31/31 and
  279/279; neither count proves semantic completeness by itself.
- **R21 — PR #183 is evidence, not implementation.** No child branches from, merges,
  or wholesale cherry-picks PR #183. Code and tests may move only after receiving one
  owner and fresh proof on the child's accepted base. The old commit history and four
  review rounds are defect evidence, not acceptance evidence. The #180 bridge ended
  when G1 changed the intent blob and how the work is split and delivered; it
  authorizes no child, branch, PR, or resume.
- **R22 — cross-child pins fail closed.** Each child spec records its direct upstream
  accepted spec blobs. Each downstream high-risk plan waits for and records all
  required upstream G3 tuples. A tuple is exactly
  `{merge_commit, exports:[{path,mode,type,oid}]}` using that child's closed product
  export list in Design. Before downstream G2 review, compare only the direct spec
  blobs with current main. Before downstream plan review, code, CI review, and final
  review, compare those blobs again and also require each G3 merge commit to be an
  ancestor of current main and every export tuple to equal the current-main Git
  entry. Any move or mismatch marks the downstream work stale and returns it through
  its own G2 and high-risk plan gates; code already written is preserved, but its
  review evidence is stale. Assembly performs the G3 check for all six upstream
  children. Shared CI, restore manifest, activation-guard, test-harness, fixture,
  and documentation paths are not product exports; every downstream exact-head/base
  review instead reruns and binds their current versions.
- **R23 — private state is enforced until assembly.** The schema child establishes a
  deterministic activation guard. Every first-six child runs it in CI and proves
  there is no public command/root dispatcher, install/export/profile wiring, user
  documentation claiming a complete package, or non-test caller of private modules
  or ingress. Only fixed private test drivers are allowed. Assembly G3 deliberately
  replaces that expectation with a guard that permits the one public wrapper/root
  while still proving no live profile, manager, template, or install path calls it.

## Design

### Package owners and child order

`core.contracts.v1` names the semantic contract package. It is not a trust claim,
Git identity, grant, or authority. Exact source provenance remains a caller-owned
Git tree claim outside this validator.

The accepted dependency graph is:

```text
portable-core-schema
  ├─> portable-core-ingress
  └─> portable-core-profile-graph
        └─> portable-core-stage-request
              ├─> portable-core-result-facts
              └─> portable-core-result-truth
portable-core-result-facts ────────────┘

all six private children ──> portable-core-assembly
```

The diagram shows scheduling order, not every source import. The table below is
the exact direct-dependency list and its full upstream G3 closure. Children on the
same level may proceed in parallel after their common prerequisites merge.

Each child spec frontmatter adds `upstream-spec-blobs`, an exact direct-dependency
map of `slug → git-blob` (`{}` when none). Each child plan adds `upstream-g3`, a
full-closure map of `slug → {merge_commit,exports:[{path,mode,type,oid}]}`. G2 review
compares the first map with the current-main child spec files. Plan review, code, CI
review, and final review also compare the second map under R22. No issue comment or
branch state substitutes for those exact identities.

| Child | One private responsibility | Direct dependencies | All required upstream G3 | Expected net new lines: product + owned proof |
|---|---|---|---|---:|
| `portable-core-schema` | parsed depth/member/string/integer limits; primitives; shared refs; envelopes; document-kind registry; one declarative role/capability/permission/evidence policy table | none | none | 360–460 |
| `portable-core-ingress` | raw-byte limit and bounded snapshot, jq 1.6 canonical bytes, hashes, private temp I/O, sanitized errors | schema | schema | 230–320 |
| `portable-core-profile-graph` | manifest/profile/resolved-profile exact body shapes, self relations, and supplied-document graph relations | schema | schema | 360–480 |
| `portable-core-stage-request` | request exact body shape, capability arguments, permissions, target/input/instruction/evidence closure, request-to-binding relation | schema, profile graph | schema, profile graph | 300–400 |
| `portable-core-result-facts` | actual-binding/execution/fact shapes plus comparison with the request-owned expected execution projection | schema, profile graph, stage request | schema, profile graph, stage request | 280–380 |
| `portable-core-result-truth` | stage-result exact body shape, six-status presence, stale observations, evidence closure, outcome reduction, outputs/delta/time | schema, profile graph, stage request, result facts | schema, profile graph, stage request, result facts | 380–500 |
| `portable-core-assembly` | fixed dispatcher, public wrapper, command routing, full-package proof, aggregate CI, user docs, and final restore view | all six | all six | 300–420 |
| **Package total** | | | | **about 2,210–2,960** |

These are normally formatted net-new-line ranges relative to each child's accepted
base, including product code and owned proof. They are planning inputs only. Every
child G2/plan independently records `review_size: standard|accepted-exception`; it
does not inherit an exception from this parent. The ranges are not permission to add
a second responsibility, compress code, copy policy, or reduce negative tests. A
child that cannot stay independently reviewable returns to its own artifact gate
before code.

The schema policy table is the only source for literal role/capability/permission/
evidence sets and mappings. Profile, request, and result owners do not redefine those
constants; they alone own the rules that apply the shared constants to their exact
document shapes and cross-document relations.

This spec fixes the private package layout:

```text
core/v1/modules/schema.jq
core/v1/modules/profile_graph.jq
core/v1/modules/stage_request.jq
core/v1/modules/result_facts.jq
core/v1/modules/result_truth.jq
scripts/lib/core-ingress.sh
```

Allowed jq imports are exact:

| Importer | Allowed module names |
|---|---|
| `schema.jq` | none |
| `profile_graph.jq` | `schema` |
| `stage_request.jq` | `schema`, `profile_graph` |
| `result_facts.jq` | `schema`, `profile_graph`, `stage_request` |
| `result_truth.jq` | `schema`, `profile_graph`, `stage_request`, `result_facts` |
| assembly `contracts.jq` | all five, once each |

CI statically rejects every other import/include/module directive or metadata form
and behaviorally proves fake search roots cannot change the loaded program.

Product export ownership is also closed and disjoint:

| Child | Immutable product exports used by downstream pins |
|---|---|
| `portable-core-schema` | `core/v1/modules/schema.jq` |
| `portable-core-ingress` | `scripts/lib/core-ingress.sh` |
| `portable-core-profile-graph` | `core/v1/modules/profile_graph.jq` |
| `portable-core-stage-request` | `core/v1/modules/stage_request.jq` |
| `portable-core-result-facts` | `core/v1/modules/result_facts.jq` |
| `portable-core-result-truth` | `core/v1/modules/result_truth.jq` |
| `portable-core-assembly` | `core/v1/contracts.jq`, `scripts/core-contract.sh` |

No other path may appear in an `upstream-g3` export tuple. A later child never edits
an earlier child's product export. A needed change returns through that earlier
child's artifact and plan gates, then refreshes every affected downstream pin.
Shared proof and aggregate paths may change only within accepted child scope and are
revalidated on the current head/base; they never masquerade as another child's
immutable product export.

The assembly child alone adds:

```text
core/v1/contracts.jq
scripts/core-contract.sh
```

`contracts.jq` uses literal, namespaced imports. `core-contract.sh` resolves its
own physical repository root, sources only the fixed ingress library, and runs jq
with the literal module root `core/v1/modules`. The public command accepts no code,
module, schema, search-path, or test-hook argument.

### Parent plan, child intake, and the failed attempt

Merging this G2 amendment accepts the package design and `risk: high`; it does not
approve a child intake, plan, or code. A new parent high-risk plan-only PR then pins
this spec and records the seven exact child issue drafts, dependency order, review
ranges, PR #183 migration ledger ownership, and PR #183 disposition. That parent
plan creates no `ready` state and authorizes no new
`ystack/impl/portable-core-contracts` work.

After the parent plan merges, each child issue receives its own exact-title/body
user-directed acceptance record and complete intent → spec-with-risk → high-risk
plan → implementation chain. Child artifact and plan PRs track their child issue
and may also track #155. Each child implementation closes its own issue. With
respect to parent #155, the first six implementation PRs use `Tracks #155`; the
assembly implementation uses `Closes #155`.

PR #183 remains frozen in its exact paused state after the final review round while
G2 and the parent plan are under review: head
`ab4a7082f02e67b5748c5c54b9214f37d222f53f`, reviewed base
`14988a8a5392e888ff1aaee4c48afa5024bee003`, `round-3 + needs-human`, clean
worktree, and open PR. Any unexplained move stops the amendment process. After G2 and
the parent plan merge and all seven child issue numbers exist, the operator records
the replacement links and closes #183 as superseded before any child code starts.
It is never merged. Its exact head remains a read-only source snapshot until
assembly G3, but no old CI, review, branch, plan, bridge, or commit is reused as
acceptance evidence.

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

`RepoPath` is a non-empty repo-relative POSIX path with no empty, `.`, `..`, or
backslash segment and no Unicode control code U+0000–U+001F or U+007F–U+009F. Root
tree is `git_location:{kind:"root"}`, never an empty path. Symlink/gitlink modes are
not representable; physical checks belong to the resolver.

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
deterministic binding forbids both and requires an empty `skill_refs` set. Verifier
and all dormant roles are deterministic. Producer, verifier, reviewer, and publisher
bindings occur exactly once. Other roles are optional and unique by role.

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
one supplied manifest. For each profile binding `b`, let `m` be that manifest and
`rb` the one resolved binding with the same binding ID. Validation enforces:

```text
rb.binding == b
b.package_ref == m.body.package_ref
rb.package_source.source == b.package_ref
b.requested_tools is a subset of m.body.offered_tools by full tool_ref equality
IDs(rb.tool_sources) == IDs(b.requested_tools)
each resolved tool package/config source and presence equals its requested tool
b.config_ref present => m.body.config_contract_ref present
rb.config_source presence/source == b.config_ref presence/object
```

Prompt and skill source presence/object sets likewise equal their binding refs, so a
deterministic binding has no resolved skill sources. A resolved implementation
ID/version equals its manifest document ID/adapter version. Across the resolved
profile, one exact source object has only one format/digest claim; a set cannot
contain the same `git-key` twice. Missing/extra tools, a matching tool ID with any
different version/package/config, or config without a manifest contract fails.

`portable-core-profile-graph` gives these rules two named checks:

- `resolved_profile_self_ok` needs no supplied profile or manifest. It checks the
  embedded binding's capability/permission closure, protected-role separation,
  profile-source digest claim, each manifest-source digest against its embedded
  `manifest_ref.sha256`, each `adapter_implementation.id` against that manifest ref
  ID, package/config/prompt/skill/tool source projections, and one claim per exact
  source object. Every command that receives a resolved profile runs this full check.
- `profile_set_graph_ok` owns only relations that need the separately supplied
  profile or manifests: profile-to-resolved equality, exact supplied manifest set
  and digests, offered roles/execution/capabilities/permissions/tools, adapter
  implementation version, package equality, and config-contract presence.

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
candidate ID selects exactly one Git-tree input, and that tree's full revision equals
the present target revision. Reviewer change head equals the present target revision
and change base equals request base. An absent target revision is allowed only for
bootstrap producer work. Required evidence kinds equal the capability rule: producer
and reviewer use their one named kind; verifier includes deterministic and may also
request behavioral and architecture.

### Stage result and evidence

`portable-core-result-facts` owns the shapes and comparisons for actual binding,
performer, environment, observed capability, model/tool facts, and whether execution
matches the selected request/binding or preserves an incident mismatch.
`portable-core-stage-request` owns one expected-execution projection from the
request and resolved binding; result facts imports that projection instead of
copying request selection rules. Result facts never chooses status or outcome.
`portable-core-result-truth` alone owns status presence, evidence closure, stale
observations, outcome precedence, outputs/delta, and time. This keeps execution
comparison from silently overriding the outcome state machine.

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

Before completed outcome reduction, evidence kinds equal the request exactly, one
item per requested kind. Producer permits only deterministic evidence. Verifier
permits deterministic plus only the requested behavioral/architecture kinds.
Reviewer permits only independent-review. `fact_gap` means a requested
provider/model/effort/prompt/skill fact is unavailable, or the selected binding
requests one or more tools and tools are unavailable. Snapshot is excluded because
it has no requested counterpart.

| Role | Failed evidence | Inconclusive evidence or `fact_gap` | Outputs | Required outcome |
|---|---:|---:|---:|---|
| producer | one or more | yes or no | must be 0 | `change/inconclusive`; reason required, delta absent |
| producer | none | yes | must be 0 | `change/inconclusive`; reason required, delta absent |
| producer | none | no | 0 | `change/no-change`; reason and delta absent |
| producer | none | no | 1 | `change/changed`; git-patch requires equal patch output/delta, other artifact kinds forbid delta |
| producer | none | no | more than 1 | invalid |
| verifier/reviewer | one or more | yes or no | 0 | `check/failed`; failed has precedence, reason absent |
| verifier/reviewer | none | yes | 0 | `check/inconclusive`; reason required |
| verifier/reviewer | none | no | 0 | `check/passed`; reason absent |
| verifier/reviewer | none or one or more | yes or no | nonzero | invalid |

The required reduction order is explicit: checks use failed evidence first, then
inconclusive evidence or `fact_gap`, then passed. Changes use any non-passing
evidence or `fact_gap` before changed/no-change by output count. No compound
condition may produce an outcome different from the table.

For completed non-inconclusive execution, actual binding equals the corresponding
projection of the selected resolved binding. Performer is an adapter actor with
those same role/implementation/instance/principal/boundary/authority fields,
environment equals the request, and capability is the requested registered ID.
Recorded/computed provider, model, effort, prompt,
and skills equal the selected model binding; deterministic fields follow the
not-applicable rule. Recorded/computed tools are a subset of requested/offered tools;
an unavailable requested fact is a `fact_gap`: it blocks passed/changed/no-change
but never overrides failed check evidence in the table above. Snapshot has no
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

### Public validator, routing, and error boundary

The assembly child exposes exactly:

```text
validate-document DOCUMENT
validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...
validate-stage-run REQUEST RESOLVED_PROFILE RESULT
```

No command accepts a repository path, physical root, executable, environment map,
URL, credential, module path, schema path, or test switch. Success is exit 0 with
empty stdout. Failure is nonzero and starts stderr with `E_USAGE`, `E_RUNTIME`,
`E_PARSE`, `E_CANONICAL`, `E_LIMIT`, `E_SHAPE`, `E_REF`, or `E_RELATION`; input
bytes, caller paths, private temp paths, and raw tool diagnostics are not echoed.

The public order is fixed:

```text
usage → runtime → raw-byte limit → parse → canonical
      → parsed structural limits → shape → ref → relation
```

Command/arity checks run before jq, SHA, package-member, or input access. An input
with more than 1,048,576 bytes returns `E_LIMIT` before parsing, even if its bytes are
also invalid JSON. An input within that byte bound reaches parsing; parsed
depth/member/string/integer limits return `E_LIMIT` only after canonical-byte proof.
The dispatcher runs one semantic layer across every supplied document before it
enters the next layer. Only after every document passes its complete self-check does
a command run its cross-document graph.

`portable-core-ingress` owns one private error boundary for every raw-byte and temp
operation. Forced-failure proof covers at least:

- unreadable input and the byte-limit read;
- canonicalizer and byte-comparison failure;
- SHA command failure or empty digest;
- `mktemp` failure;
- every later private-temp create, truncate, append, and redirect failure;
- driver input and validator-output write failure;
- non-1.6 jq;
- validator nonzero exit, extra output, or unknown token.

Each failure emits only its allowed token. Stderr contains no caller path, temp path,
stub message, or fixture bytes.

### Command-to-rule matrix

`D(K)` is `validate-document` for kind `K`; `P` is `validate-profile-set`; `S` is
`validate-stage-run`.

| Owner | Rule group | D | P | S |
|---|---|---|---|---|
| assembly | command form, fixed member/import guard, command routing, and public error order | applicable | applicable | applicable |
| ingress | raw-byte limit/snapshot, canonical bytes, hash, and sanitized I/O | each input | each input | each input |
| schema | parsed structural limits, envelope, primitives, shared refs, and fixed registry/policy constants | supplied document | every supplied document | every supplied document |
| profile graph | manifest self | `D(adapter_manifest)` | every manifest | — |
| profile graph | profile self and protected-role closure | `D(profile)` | profile | — |
| profile graph | resolved-profile self and source projections | `D(resolved_profile)` | resolved profile | resolved profile |
| profile graph | profile/resolved/manifest external graph | — | yes | — |
| stage request | request body, capability/permission/input/instruction/evidence self closure | `D(stage_request)` | — | request |
| stage request | request-to-resolved binding/ref relation | — | — | yes |
| result facts | actual-binding/execution/fact shapes | `D(stage_result)` when present | — | result when present |
| result facts | actual-versus-request/resolved execution assessment | — | — | yes |
| result truth | result body, status presence, stale-selector/output/evidence local shape, and started/finished/recorded local order | `D(stage_result)` | — | result |
| result truth | request/resolved refs, stale expected/difference/repository checks, requested-at time floor, exact evidence set, outcome, and execution-truth relation | — | — | yes |

No row mixes owners. Each child spec expands its groups into rows for every stable
rule ID. Every required cell has one accepted fixture, one rule-targeted rejection,
and deterministic proof that the command calls that owner. The proof mechanism is
private test infrastructure and is never selectable through the public wrapper.
Route proof shows the owner is called; ordinary valid/invalid cases show the owner's
rule. Neither substitutes for the other.

### Module and full-package proof

Fixtures contain data only. They never import product registries or predicates and
never ask product code to build a valid value or choose the expected result. Expected
error, route, evidence, and outcome values are literal test data derived from this
spec. Tests use pinned jq 1.6 only to emit canonical bytes and an external SHA-256
tool only to compute digests. A mutation that changes a referenced document rebuilds
downstream refs independently so it reaches the intended rule.

Each private child supplies:

- direct valid and invalid cases for every owned rule ID;
- exact-boundary and one-over cases for every owned bound;
- a closing rule/test for every assigned `review-rN-fNN` finding row;
- a closing test ID or reason for every assigned `legacy-test-NNN` assertion row;
- a data-only fixture extension;
- the current private-activation guard and restore manifest entry for every new
  package/test file;
- exact-head jq 1.6 CI and an `owned rules: N/N` report with zero failures;
- independent review that does not require re-certifying a different owner.

The schema child establishes the pinned jq 1.6 private-package CI step. Each later
child explicitly adds its own test command to that step; no wildcard discovery or
ambient executable is allowed. Constitution-path updates remain operator-owned or
arrive as `proposals/` for operator application. The first six keep the private
activation guard green; assembly replaces it only with the accepted public-package
guard described in R23.

The assembly child additionally proves:

- successful `validate-document` for all five kinds;
- profile-set success plus 1/8/9 manifest boundaries, missing manifests, and extras;
- stage-run success for producer, verifier, and reviewer;
- all six terminal statuses and every row of the completed outcome table, including
  failed-plus-inconclusive and failed-plus-`fact_gap`;
- every command-to-rule cell and forced route;
- raw-byte and sanitized-error behavior through the public shell wrapper;
- combined-defect rows proving oversized invalid JSON returns raw `E_LIMIT`, while
  within-limit invalid JSON returns `E_PARSE`, plus later-layer order pairs;
- the exact import allowlist/grammar, no `search` metadata, fake cwd, fake
  `HOME/.jq`, and ambient same-name modules cannot change loaded code; every expected
  directory fails if missing, not a directory, or a symlink; wrapper, ingress, root
  program, and module files fail if missing, nonregular, or symlinks;
- all 31 review-finding rows and all 279 legacy-assertion rows are accounted for; and
- pinned jq 1.6 CI on the exact reviewed head.

The final report uses semantic counters, not one undifferentiated assertion total:

```text
owned rules: N/N
command-to-rule cells: N/N
forced routes: N/N
review findings accounted for: 31/31
legacy assertions accounted for: 279/279
full-package cases: N/N
failures: 0
```

The 31 review rows and 279 assertion rows are migration evidence, not an oracle or
semantic acceptance target. Repeated findings remain visible even when several map
to the same new rule. Code golf, generated long lines, copied registries, a second
parser, system-jq drift, fewer negative cases, or product logic used as the test
oracle never justify a smaller child.

### Downstream handoffs and intent questions

1. **Dependency order and one clear home:** the seven children and owner table above
   are exact. Raw-byte ingress is separate from request `named_input` closure. Result
   facts compare observed execution; result truth alone chooses status/outcome.
2. **Package identity and loading:** `core.contracts.v1` is one semantic package.
   Assembly loads only its literal root and private module directory with jq 1.6
   `-L`; external Git refs carry exact source claims when needed.
3. **Child slugs and final wait:** every independently merged part uses the exact
   child slug above. Assembly waits for all six upstream accepted specs and G3
   commits before its own code and is the only child that exposes public commands.
4. **PR #183 reuse:** its final head is a read-only source snapshot. The migration
   ledger assigns each moved rule/test one owner and new proof. Old round fixes remain
   evidence; hard-to-read predicates, temp I/O, and result precedence are rewritten,
   not copied.
5. **Proof matrices:** owned-rule cases, command-to-rule routes, completed outcome
   rows, forced failures, and full-package cases are all complete independently.
   Counting assertions or passing an earlier failure class cannot stand in for a
   missing cell.
6. **Review ranges:** the child table replaces the old 800–1,100 one-PR estimate.
   Result facts and result truth are separate because PR #183 repeatedly mixed
   execution equality with outcome precedence. A range is a planning signal; a
   second responsibility returns to that child's artifact gate.

The resolver seam remains unchanged: it consumes canonical profile/manifests plus
caller-owned exact sources, selection, repository context, and physical repo map;
it emits canonical resolved-profile/source claims and alone checks Git truth.

The adapter-test seam also remains unchanged. Accepted inventory and observations
are runner-owned exact artifacts supplied as verifier input/proof. Adapter-facing
traffic uses only the five core docs; the runner independently executes, revalidates
every core document, recomputes assertions/Git facts, and ignores adapter
self-reported verdicts. Its test-only format is not core schema or authority.

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

- Changing any v1 document, field, enum, capability, permission, canonical-byte,
  digest, error-class, or claims-not-authority meaning.
- Adding a public command, dynamic module path, partial-package activation, or live
  caller before `portable-core-assembly` G3.
- Creating or approving the seven child issues/plans/code in this G2 PR. The parent
  plan and each child gate own those later decisions.
- Resuming, merging, rebasing, resetting, force-pushing, or otherwise changing PR
  #183. Its later close-as-superseded decision follows the accepted parent plan.
- Core test-inventory/result kinds, fake runner, fixture/process execution, 2×2,
  timeout/cleanup, and external-target smoke.
- Forge, CI, execution, identity, or publisher operations; GitHub/GitLab/native
  transports; CR/comment/label/status; topic CAS; any external write.
- Git reads, physical repo mapping, caller-supplied Git object/mode/symlink/
  replacement truth checks, config/tool provenance truth, authentication,
  credentials, grants, policy/gate evaluation, qualification, sandbox/network
  enforcement, and kill switch.
- Retry/reconciliation/backpressure, deployment/rollback, production incidents,
  telemetry/trace/usage/cost, packaging/install/migration, skill bridges, non-Git
  stores, or live profile activation.
- Amending `portable-profile-resolution` or another downstream artifact here. Any
  downstream spec that pins the old core spec/G3 returns through its own artifact
  and plan gates before implementation.
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
5. **Smaller children do not weaken proof.** The seven ranges are evidence-based
   planning signals. Strict parsing, complete relations, readable code, adversarial
   tests, exact CI, and independent review remain hard gates. A child outside its
   range explains the evidence; a second responsibility returns to its artifact gate.
6. **CI is a constitution path.** Operator-driven work may edit it; unattended work
   must use `proposals/` and wait for application.
7. **This is user-directed high-risk design.** The package defines security controls,
   broad architecture, workflow dependencies, and operator-owned CI. G2 accepts this
   `risk: high` classification and this spec only; it does not approve the parent
   plan, any child intake, code, or activation.
8. **Nothing changes live.** `/yshifu`, manager persona, adapters, and sessions stay
   unchanged. Human merge remains the only merge path.
9. **Children do not inherit intake approval.** Each exact child issue needs its own
   current-title/body acceptance record and full artifact chain. Parent G2/plan,
   dependency links, or quoted scope prove provenance but never create `ready`.
10. **Old evidence is stale by design.** The #180 bridge ended with the G1 intent
    change. PR #183 reviews and CI remain useful failure evidence, not acceptance.
    `portable-profile-resolution/spec.md` still pins the old core spec/G3 and must be
    amended before its own implementation can proceed.
11. **The host toolchain is operator-controlled.** The public wrapper does not claim
    to defend against a malicious `jq`, SHA tool, `mktemp`, or other executable on
    `PATH`; caller documents and command arguments cannot set that environment. CI
    pins jq 1.6 by release-asset digest. Later control-foundation/qualification work
    owns executable provenance for other environments.
