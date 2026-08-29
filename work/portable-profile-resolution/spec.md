---
intent-blob: 2405fd2df4276b43a818c8d712dd45c2c36f11ba
drafted: 2026-08-29
---

# Spec: portable profile resolution

Resolve one caller-selected profile from exact local Git objects. The resolver
checks physical Git facts and emits the existing portable-core `resolved_profile`
document. It does not decide whether the caller, selection, repository mapping,
profile, adapter, or authority claim is trusted.

This design consumes portable-core schema v1 exactly as accepted in
`work/portable-core-contracts/spec.md` blob
`f5b218626dec8484518295e901e427e3ff8f3daf`. It does not add a
`contract_version` field, a sixth core document, or another copy of the core
schema. Implementation waits for `portable-core-contracts` G3 and pins its exact
merge commit before any resolver code is written.

## Requirements

- **R1 — one exact input graph and one existing output kind.** One invocation
  receives a caller-owned resolution request plus a separate physical repository
  map. The request names one exact committed profile object, one to eight exact
  committed manifest objects, one selection ref, and one repository-context ref.
  Success emits exactly one canonical core-v1 `resolved_profile`. Physical roots,
  repository-map bytes, ambient credential/secret-store values, and opaque source
  payload bytes never enter that document. Core IDs, repository-relative Git paths,
  profile bindings, and caller scope refs enter it by design and must not contain
  secrets.
- **R2 — the accepted core remains the only contract authority.** The resolver
  invokes the accepted `scripts/core-contract.sh` from its own checked-out ystack
  revision. It uses `validate-document` for the extracted profile and manifests,
  then `validate-profile-set` for the complete output graph. Resolver code may
  use a narrow transport guard for locator strings before a Git call and assemble
  an output. Passing that guard is never core validity. Resolver code cannot copy
  or reinterpret core document shapes, registries, capability/permission rules,
  offer/request relations, or protected-role separation.
- **R3 — dependency identity is explicit.** This G2 pins core schema major 1 and
  the accepted core G2 blob above. It does not claim that the validator exists yet.
  The implementation-ready plan waits for core G3, records its exact merge commit,
  and treats any later dependency movement as new external context requiring fresh
  proof. G2 accepts design only; it does not accept a plan, code, or activation.
- **R4 — selection stays outside candidate data.** The caller supplies exact
  profile and manifest source locators, `selection_ref`, and
  `repository_context_ref` in the invocation frame. A profile or manifest cannot
  choose or replace any of them. The resolver carries both scope refs unchanged.
  It validates their core shape through the final output but does not authenticate
  their decision records or turn either ref into authority.
- **R5 — repository mapping is exact and private.** The caller separately supplies
  one logical repository ID to one physical local repository root. Every logical
  repository used by the selected source graph has exactly one map entry; no extra,
  missing, duplicate-ID, or duplicate-physical-repository entry is allowed. The
  association remains an unauthenticated caller claim. Roots and derived Git paths
  are used only inside the resolver and are never written to stdout, canonical
  records, or diagnostics.
- **R6 — every selected Git claim is proven physically.** For the profile,
  manifests, binding packages/configs/prompts/skills, and requested tool
  packages/configs, the resolver proves the mapped repository's storage hash
  algorithm, full commit object, root tree, literal path walk, final object ID,
  object type, file mode, and raw object payload. It accepts only full lowercase
  SHA-1 or SHA-256 IDs of the correct length. It never accepts a branch, tag,
  abbreviated ID, revision expression, pathspec, working-tree file, index entry,
  or mutable ref.
- **R7 — Git reads fail closed.** Every Git command uses one private wrapper with
  replacement objects and lazy fetching disabled. The wrapper clears ambient Git,
  config, object-store, credential, pager, prompt, and network-related environment
  state; uses only fixed read-only plumbing against mapped repos; and never invokes
  a hook, remote, filter, checkout, worktree materialization, or ref update. A mapped
  repo with replacement refs, grafts, alternates, a promisor/partial-clone dependency,
  an unsupported object format, or an object that is not already local is rejected.
  Verified bytes may be copied only into disposable private object views for path
  inspection; the wrapper never writes a mapped repository.
- **R8 — paths and symlinks cannot redirect a read.** Physical roots are absolute,
  bounded, and free of symlink components. The resolver identifies the canonical
  common Git directory and object store and uses those identities for one-to-one
  map checks. A Git path follows the accepted core `RepoPath` grammar. The resolver
  walks one tree segment at a time by exact byte equality, without giving a caller
  string to Git as a pathspec. Every intermediate component must be a tree. A
  symlink, gitlink, wrong case, missing component, wrong mode, or wrong type fails.
- **R9 — one snapshot owns each observed value.** The resolver reads every commit,
  traversed tree, and selected source payload once into a private, bounded snapshot.
  It recomputes the repository-native object ID from the exact type and payload and
  requires it to match the claimed OID. Verified commit/tree snapshots enter the
  disposable private object view for that canonical physical repository and storage
  algorithm; path enumeration reads only that view. All
  SHA-256 value digests, extracted documents, relation inputs, and final provenance
  come from the same snapshots. It never validates one mapped-repo read and hashes
  or traverses a second one. A cache keyed by canonical physical repository,
  storage algorithm, object type, and full OID reuses an already verified snapshot.
- **R10 — source-value provenance is deterministic.** Profile and manifest sources
  use `value_format:"canonical-json"`; their SHA-256 covers the complete canonical
  document bytes including the single final line feed. Every other selected source
  uses `value_format:"raw-bytes"`; its SHA-256 covers the exact Git object payload.
  The same core `git-key` can have only one format and digest claim. Manifest source
  identity is unambiguous even when several bindings share one manifest.
- **R11 — data remains inert.** The resolver accepts the object types and modes that
  core v1 accepts and requires every physical object to equal its claim. An executable
  bit does not make the resolver execute content. It reads every profile, manifest,
  config, prompt, package, skill, and tool source only as a Git object payload. It
  never sources, parses as shell, evaluates, expands, loads as a code/module/runtime
  import, materializes into a working tree, or executes one. Copying verified object
  bytes into a private Git object view grants no execution meaning. It never expands
  a package/tool name through `PATH`, substitutes an environment variable,
  dereferences a URL, loads a remote schema, reads a secret store, or treats a
  secret-looking value as a credential.
- **R12 — compatibility is checked, not granted.** The output copies the accepted
  profile binding, derives adapter implementation identity from the selected
  manifest, and records exact sources. The core validator alone checks exact
  manifest selection, offers versus requests, full package/tool/config equality,
  model/deterministic rules, dormant roles, capability and permission subsets, and
  protected-role separation. Passing resolution means only that the claims are
  structurally compatible and physically present; it never means trusted,
  authenticated, granted, qualified, approved, selected for live use, or active.
- **R13 — deterministic and idempotent output.** The same logical invocation and
  same Git object bytes produce byte-identical output across repository-map order,
  manifest-source order, current directory, physical clone path, and cleared ambient
  environment. Bindings and source sets use the accepted core sort keys. The
  resolver derives the document ID from the canonical resolved body, so caller or
  candidate text cannot choose it. A rerun performs no external write and creates no
  durable state outside its returned document.
- **R14 — work is bounded before use.** Wrong command or arity fails before opening
  an input. The resolver snapshots and validates the request, then rejects zero or
  more than eight manifest locators before opening the repository map or any Git
  source. Each invocation file and extracted canonical document is at most
  1,048,576 bytes. One selected raw
  object payload is at most 16,777,216 bytes and all snapshots together are at most
  67,108,864 bytes. The map has at most 1,024 entries and an absolute root is at
  most 4,096 UTF-8 bytes. Core JSON depth/member/string/integer limits apply to
  extracted core documents. All temporary data lives under one mode-0700 directory
  created with `umask 077` and is removed on every exit.
- **R15 — failures are closed and sanitized.** Success is exit 0 and exactly one
  canonical `resolved_profile` on stdout. Failure is nonzero, stdout is empty, and
  stderr starts with one allowlisted resolver or unchanged core error token. Raw
  Git stderr is suppressed. No error includes a physical path, environment value,
  config/prompt bytes, object payload, or any rejected caller string.
  Error precedence is fixed in Design so one defect has one stable first class.
- **R16 — proof covers truth, substitution, and non-effects.** Hermetic tests create
  local SHA-1 and SHA-256 repositories and cover single- and multi-repository graphs,
  bare/main/linked-worktree mappings, input ordering, two physical clones, every
  source category, exact boundaries, malformed core relations, unsafe Git state,
  path confusion, symlink/gitlink cases, replacement objects, alternates, partial
  clones, ambient injection, inert hostile content, output/error leakage, and no
  network/process/ref/working-tree effect. Tests call the real core validator and do
  not reuse resolver assembly code as their oracle.
- **R17 — one inactive implementation concern.** The later implementation is one
  reviewable PR containing the resolver front door, its private assembly helper,
  independent fixtures/tests, restore-critical manifest entries, plain-language
  docs, and CI proof. The plan estimates normal-format size before code. If it needs
  a review-size exception or materially broader concern, it returns to the artifact
  gate. No current profile, manager, template, installer, adapter, or `/yshifu`
  path calls the resolver.

## Design

### Accepted dependency and ownership boundary

The accepted core spec blob
`f5b218626dec8484518295e901e427e3ff8f3daf` owns:

- the five canonical document kinds and exact envelope;
- shared `document_ref`, `git_revision_ref`, `git_object_ref`, `scope_ref`,
  `source_value_ref`, `tool_ref`, and `present<T>` shapes;
- `adapter_manifest`, `profile`, `resolved_profile`, and resolved-binding shapes;
- capability, permission, role, model, prompt, skill, and tool relations;
- canonical JSON, core resource limits, document digests, and core error classes.

This child owns only:

- the private resolution-request and repository-map transport;
- safe physical repository and Git-object reads;
- exact source snapshots and value SHA-256 computation;
- mechanical assembly of an existing `resolved_profile` for core validation;
- resolver-specific errors and physical-Git fixtures.

The implementation resolves `scripts/core-contract.sh` from its own repository
root. The caller cannot replace the validator, schema path, jq source, Git wrapper,
or assembly helper. The implementation-ready plan pins the core G3 merge commit and
names the exact compatibility proof run against it.

### Public command and invocation-only inputs

The public entry clears the environment before a shell interpreter starts. On the
initial supported hosts, its executable shim uses fixed absolute `/usr/bin/env`
split-string and empty-environment options to start fixed `/bin/sh`. An equivalent
non-shell launcher is allowed only when the plan proves the same pre-interpreter
boundary. A normal `/bin/sh` or `#!/usr/bin/env bash` shebang is not enough:
inherited `SHELLOPTS` and `PS4` can trace or execute text before the script's first
command, and `BASH_ENV` or `PATH` can select startup code. The shim passes only an
allowlisted runtime environment and the original opaque argv. Its shell body
performs no candidate-sensitive read before the trusted resolver runtime starts.
The front door exposes one command:

```text
scripts/profile-resolve.sh resolve RESOLUTION_REQUEST REPOSITORY_MAP
```

There is no command that accepts a profile document copied from a working tree, an
output path, an executable, a URL, a credential, or an environment map. Success
writes the canonical result to stdout; the caller decides whether and where to
persist those bytes.

The implementation plan names the exact pre-interpreter shim and how each supported
host binds absolute shell, Git, jq, hash-tool, and core-validator paths before
untrusted data is read. The binding is operator-owned in this manual v1 and later
belongs to trusted packaging or control foundation. It cannot come from the profile,
manifest, repository map, request, cwd, ambient `PATH`, or a personal path committed
to the repo. CI proves the initial `/usr/bin/env` split/empty-environment behavior.
A host without an accepted launcher/runtime binding is unsupported and cannot invoke
the resolver; an already-clean trusted launcher reports `E_RUNTIME` before opening
the request when a bound dependency is missing.

`RESOLUTION_REQUEST` is a strict invocation-only JSON value. Its private
`source_locator` is deliberately smaller than `git_object_ref`:

```text
source_locator =
{repository_id:ID,hash_algorithm:"sha1"|"sha256",commit_id:GitOID,
 path:RepoPath,object_id:GitOID}
```

It names the only facts needed to find an exact committed profile/manifest blob.
The resolver derives the actual object type and mode from the commit tree and later
places a full `git_object_ref` in the tentative output. Before the first Git call, a
transport guard checks exact keys, bounded strings, the two hash names, full
lowercase OID lengths, and safe path segments. These checks prevent option/path
injection. They do not validate a core ref, and no success result is returned until
the derived ref passes core validation.

The request is:

```text
{version:1,
 profile_source:source_locator,
 manifest_sources:array<source_locator>(unique locator tuple,0..256),
 selection_ref:scope_ref(selection),
 repository_context_ref:scope_ref(repository-context)}
```

The transport bound lets the resolver return one stable count error; only `1..8`
proceeds. The locators include full storage-format object and commit
OIDs. Their array order is not meaningful. The frame contains no resolved-profile
ID, grant, qualification, gate, activation flag, physical path, command,
environment, object type/mode claim, or fallback value.

`REPOSITORY_MAP` is a separate invocation-only JSON value:

```text
{version:1,
 repositories:array<{repository_id:ID,root:AbsolutePath}>
              (unique repository_id,1..1024)}
```

`AbsolutePath` is an absolute host path of at most 4,096 UTF-8 bytes. After its one
leading slash, it has no NUL, control character, empty component, `.` component, or
`..` component. It is not a core type and never leaves the process. A root may name
only a bare repository top level, a normal worktree top level, or a linked-worktree
top level; a repository subdirectory is invalid. The resolver derives the canonical
common Git directory and object store, rejects symlinked components, and treats
those derived identities as the physical repository for duplicate checks. Two
logical IDs cannot map to the same common Git directory/object store.

Both files must be exactly one jq-1.6 canonical JSON value plus one final line feed.
The resolver snapshots at most 1,048,577 bytes before parsing, rejects an extra byte,
and applies strict exact-key/count/type checks to this private transport. It snapshots
and validates the request first. Zero or more than eight locators return `E_INPUT
manifest-count` before the map or a Git source is opened. The remaining transport
checks protect the Git call boundary; they do not declare a core ref valid. The
complete constructed graph still must pass the accepted core validator.

### Selected source graph

The selected graph contains only sources that appear in the emitted
`resolved_profile`:

1. the one profile source;
2. exactly one source for each distinct manifest document referenced by a selected
   profile binding;
3. each selected binding's package, optional config, optional prompt, and skill
   refs;
4. each requested tool's package and optional config refs.

Unrequested tools offered by a manifest are manifest claims, not selected sources.
They are checked lexically and relationally by core but are not physically resolved
or added to the repository-map set in this invocation. A later profile that requests
one must resolve it then.

Every recomputed manifest `document_ref` maps to exactly one supplied manifest
source. More than one physical source for the same manifest ref is ambiguous and
fails. Several bindings may reuse that one source. Missing or unreferenced supplied
manifests fail through the final exact-set relation.

After the profile and manifests pass `validate-document`, the resolver derives the
set of repository IDs from the graph above. That set must equal the repository-map
ID set. This exactness check happens before any package/config/prompt/skill/tool
object is read.

### Repository and Git boundary

One private wrapper owns every Git call. The clean bootstrap supplies a fixed
absolute Git executable as a trusted resolver dependency. The wrapper feature-probes
the required read-only operations, then runs them with `LC_ALL=C`, no pager or
prompt, a private `HOME`, replacement objects disabled, and lazy fetching disabled.
It passes an environment allowlist; it does not try to blacklist only known `GIT_*`
or `GIT_TRACE*` names. Against a mapped repo, the only allowed operation families
are repository/object-format inspection, exact ref-state inspection, raw
`cat-file`, and `hash-object --stdin --no-filters` without `-w` or `--path`. Under
the mode-0700 scratch root, it creates one bare object database for each canonical
physical repository and storage algorithm. It imports a verified commit or tree
with fixed `hash-object -w -t commit|tree --stdin --no-filters`; the wrapper chooses
the type from the current fixed stage or an already verified tree entry, never from
a candidate option, and requires the returned OID to equal the verified OID. It runs
one-level `ls-tree -z` only in the matching private view. It creates no scratch
object ref. It forbids
`cat-file --filters`, `--textconv`, and `--follow-symlinks`. Arguments are built by
the wrapper; candidate data cannot choose a subcommand, option, executable,
environment assignment, filter, or trace destination. Every call also uses fixed
`--no-pager`, `--no-replace-objects`, `--no-lazy-fetch`,
`--no-optional-locks`, and `--literal-pathspecs` global options.

For each physical repository, the wrapper:

1. accepts a bare repo, normal worktree, or linked worktree only when Git resolves a
   local canonical common directory and object store;
2. rejects duplicate physical identity, symlinked root/Git/object-store components,
   a missing local object database, or a working-tree path that is not tied to that
   repository;
3. reads the storage object format and accepts only `sha1` or `sha256`; a repository
   declaring a compatibility object format is rejected in v1;
4. rejects any `refs/replace/*`, non-empty graft file, object alternate, promisor
   remote, or partial-clone extension;
5. clears `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`,
   `GIT_ALTERNATE_OBJECT_DIRECTORIES`, namespaces, replacement, config-injection,
   askpass, SSH, proxy, and credential environment before every call;
6. never asks Git to resolve a name other than a full already-validated OID and
   never invokes a command that can contact a remote or update Git state.

The wrapper captures the common-directory/object-store identity and unsafe-state
checks before source reads and checks them again before success. Persistent drift
fails. Every accepted content claim still comes from an OID-verified snapshot, even
if pack layout or ordinary refs change.

### Exact commit and path resolution

For each `git_object_ref`, the resolver follows this order:

1. The mapped repository's storage algorithm must equal
   `revision.hash_algorithm`; every commit and object ID length must match it.
2. `revision.commit_id` must already exist locally as a commit object. A tag object,
   branch name, short ID, peeled expression, or missing promised object is invalid.
3. The resolver snapshots the raw commit payload, recomputes its native Git OID with
   fixed `hash-object --stdin --no-filters -t commit`, and requires exact equality.
   It imports that verified snapshot into a private object database of the same hash
   format.
4. It reads the commit's exact root-tree OID from that snapshot, reads that tree once
   from the mapped repo, recomputes its native OID, and imports the verified tree
   snapshot into the private object database.
5. A `root` location must equal that root tree with type `tree` and mode `040000`.
   For a `path`, the resolver splits the accepted `RepoPath` itself. It enumerates
   one level of the verified private tree with NUL-delimited output and matches one
   literal segment byte-for-byte. It never passes the full path to Git.
6. Every intermediate entry must be mode `040000`, type `tree`, and locally present.
   Its raw payload is read once from the mapped repo, native-OID verified, and imported
   before the next private `ls-tree`. Mode `120000`, mode `160000`, or a non-tree
   intermediate fails without reading a filesystem target.
7. The final entry's OID, type, and mode must exactly equal the claim. The resolver
   snapshots its raw payload once and recomputes its native Git OID. A final tree is
   also imported before any enumeration. Wrong case, wrong mode, wrong type, missing
   object, corrupt payload, or OID mismatch fails.

The path walk verifies the selected object and every component used to reach it. A
selected tree's descendant contents are not recursively materialized or approved.
The tree OID binds that closure; any later launcher that materializes or executes it
must apply its own accepted sandbox and package checks.

### Snapshot, digest, and source rules

Every distinct selected `git-key` has one private snapshot and one source-value
claim. Snapshot size is checked before the payload is used. Native-OID recomputation
checks Git object identity; `value_sha256` gives one hash format for audit across
SHA-1 and SHA-256 repositories.

| Source use | Required source | `value_format` | `value_sha256` bytes |
|---|---|---|---|
| profile | object derived from request locator; blob with actual core mode | `canonical-json` | complete validated profile document, including final LF |
| manifest | object derived from its unique locator; blob with actual core mode | `canonical-json` | complete validated manifest document, including final LF |
| binding package | exact binding `package_ref` | `raw-bytes` | exact selected Git object payload |
| binding config | exact present binding `config_ref` | `raw-bytes` | exact selected Git object payload |
| binding prompt | exact present binding `prompt_ref` | `raw-bytes` | exact selected Git object payload |
| binding skill | each exact binding `skill_ref` | `raw-bytes` | exact selected Git object payload |
| requested tool package | exact requested package ref | `raw-bytes` | exact selected Git object payload |
| requested tool config | exact present requested config ref | `raw-bytes` | exact selected Git object payload |

For a tree, raw bytes mean the root tree object's binary payload, not pretty
`ls-tree` text and not a filesystem archive. The exact recursive content remains
bound by the Git tree OIDs. The resolver never changes line endings, Unicode,
permissions, archive order, or tree representation before hashing.

Profile/manifest canonical bytes are validated before their fields are used. Their
core `document_ref.sha256`, source `value_sha256`, and the SHA-256 of the same
snapshot are equal. Other payloads are opaque even when they happen to contain JSON,
shell, YAML, a URL, an environment placeholder, or a secret-looking string.

### Mechanical assembly and core validation

The private assembly helper receives only validated profile/manifest documents,
their recomputed document refs, verified source-value refs, and the two caller scope
refs. It performs deterministic joins and copies; it does not contain an offer,
capability, permission, role-separation, or trust predicate.

For each profile binding it:

- selects the one supplied manifest whose recomputed `document_ref` equals the
  binding's `manifest_ref`;
- copies the binding without alteration;
- derives `adapter_implementation.id` from the manifest document ID and version
  from `manifest.body.adapter_version`;
- attaches the verified manifest and binding/package/config/prompt/skill/tool
  source-value refs with the exact presence and sort keys accepted by core.

It creates the existing resolved body with the recomputed profile ref, profile
source, unchanged selection and repository-context refs, and bindings sorted by
`binding.binding_id`. It canonicalizes that body alone, including one final line
feed, computes its SHA-256, and sets the envelope ID to
`resolved-profile:<body-sha256>`. This has no self-reference because the ID is not
inside the body. The full envelope is then canonicalized normally.

Before returning any bytes, the resolver calls:

```text
scripts/core-contract.sh validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...
```

Manifest arguments are sorted by `(kind,id,sha256)`. Success from core
must be exit 0 with empty stdout and stderr. The resolver passes through a known core
failure token unchanged. An unknown token, extra output, missing dependency, or
unexpected exit becomes `E_RUNTIME`. Only after core succeeds and the physical repo
state recheck passes does the resolver write the already-validated canonical
resolved-profile snapshot to stdout.

### Config, skill, identity, and secret boundary

Core v1 has no config-body schema, secret value, secret-reference-name field,
identity attestation, or skill-format validator. This resolver does not invent one.

- A config or tool config is an exact opaque Git object. The resolver proves and
  hashes its bytes. The manifest's `config_contract_ref` is carried and related by
  core, but neither its decision record nor the config bytes are interpreted here.
- A prompt or skill is an exact opaque Git object. The resolver proves and hashes
  it but does not parse frontmatter, `allowed-tools`, commands, imports, or harness
  layout. Those bytes grant nothing.
- Principal, adapter-instance, execution-boundary, and authority refs remain core
  claims. Core checks exact protected-role separation. No local account, provider,
  credential, or external identity is looked up.
- The process clears ambient credentials and never opens a secret store. A literal
  secret committed inside an opaque object is a separate repository-policy defect;
  resolution neither exposes it nor falsely claims to detect it.

A later config contract, skill bridge, identity adapter, policy evaluator, and
control foundation must define and enforce content meaning before any resolved
binding can run.

### Limits and deterministic behavior

Limits apply before allocation or use:

| Item | Limit |
|---|---:|
| resolution request bytes | 1,048,576 |
| repository map bytes | 1,048,576 |
| manifest source refs | 1..8 |
| repository mappings | 1..1,024 |
| physical root string | 4,096 UTF-8 bytes |
| each selected object payload | 16,777,216 bytes |
| all object snapshots in one invocation | 67,108,864 bytes |
| each extracted core document | accepted core limits |

After the request's raw-size, parse, canonical, and private-shape checks, zero or
more than eight manifest locators returns `E_INPUT manifest-count` before the
repository map or a Git source is opened. An invocation file or object uses a
one-extra-byte probe and returns
`E_LIMIT` before parsing or hashing the over-limit value. The running total is
checked before each new snapshot. A selected graph that needs more than 1,024
physical repositories or 67,108,864 snapshot bytes cannot be resolved in v1.

Map entries, manifest sources, bindings, skills, and tools are normalized only by
their specified lexical sort keys. No locale, filesystem order, Git output order,
physical root, current directory, clock, random value, process ID, or environment
value enters the output. The resolver adds no timestamp. Tests must prove that
permuted inputs and equivalent clones return exactly the same bytes.

### Error contract and precedence

The resolver error allowlist is:

```text
E_USAGE
E_INPUT
E_RUNTIME
E_PARSE
E_CANONICAL
E_LIMIT
E_SHAPE
E_REF
E_RELATION
E_REPOSITORY
E_OBJECT
```

`E_PARSE`, `E_CANONICAL`, `E_LIMIT`, `E_SHAPE`, `E_REF`, and `E_RELATION` from the
real core validator keep their accepted meaning. The resolver adds:

- `E_INPUT` — the private request/map has wrong fields, types, counts, duplicate
  entries, or an unsafe physical-root string;
- `E_REPOSITORY` — mapping-set, canonical-root, common-directory/object-store,
  storage-format, replacement/graft/alternate/promisor/partial-clone, or repository
  state is invalid;
- `E_OBJECT` — an exact commit, tree walk, object type/mode/OID, local presence,
  symlink/gitlink, payload, or native-hash check fails.

The first failure class is chosen in this order:

1. command and arity, without opening an input;
2. trusted launcher/runtime/core feature preflight, without opening an input;
3. request raw-size, parse, canonical, private shape, locator guards, and manifest
   count, without opening the map or a Git source;
4. map raw-size, parse, canonical, private shape, and root-string safety;
5. initial repository mapping/root/state needed to read profile and manifests;
6. profile/manifest object reads and their individual core document validation;
7. exact manifest-source and repository-ID map sets;
8. remaining selected Git object checks;
9. mechanical assembly and final core profile-set validation;
10. final repository-state recheck and output.

Within core validation, the accepted order remains limits, shape, ref, then
relation. The resolver never relabels a core relation failure as physical Git truth.
For an unexpected tool/dependency failure it emits only `E_RUNTIME unexpected`.
Other failures may add one fixed, allowlisted reason ID after the token. Dynamic
paths, refs, Git output, JSON values, or payload fragments are never diagnostics.

### Implementation components and order

The later plan keeps one public and one private product boundary:

- `scripts/profile-resolve.sh` — pre-interpreter empty-environment shim and public
  command; its shell body starts only after ambient startup, trace, exported-function,
  and `PATH` state is gone;
- one private resolver runtime under `scripts/lib/` — snapshots, safe Git wrapper,
  source verification, core-validator calls, and sanitized exit contract;
- `resolver/v1/profile-resolution.jq` — private transport parsing, deterministic
  joins, source projection, and assembly only; no copied core acceptance predicates;
- readable test fixture builders under `scripts/test/` that create independent
  profile/manifest data and Git repositories;
- one hermetic resolver test entry point under `scripts/test/`;
- the matching `ci/required-files.txt`, README, restore, and CI updates selected by
  the accepted plan.

Work proceeds in this order:

1. Wait for core G3, pin its merge commit, and prove its three public commands on the
   implementation branch before editing resolver code.
2. Land the private transport limits and sanitized command/error boundary.
3. Land one safe Git wrapper plus repository-map and exact-object verification.
4. Land snapshot/value-digest projection and mechanical output assembly.
5. Invoke the real core validator and add positive cross-hash/multi-repo cases.
6. Add the full adversarial matrix, docs, restore manifest, and CI proof.
7. Run independent Bugs, Security, and Compliance review on the exact final head.

No partial commit is wired into a live profile or installed command.

### Verification matrix

Positive fixtures prove:

- one SHA-1 repo, one SHA-256 repo, and one invocation that selects both formats;
- commit/tree imports whose returned OIDs equal their verified OIDs and whose trees
  can be enumerated in the matching private views;
- one-repo and multi-repo selected graphs;
- bare, ordinary, and linked-worktree roots that resolve to unique common object
  stores;
- one manifest shared by bindings and the exact 1/8 manifest boundaries;
- package blobs/trees, optional config/prompt, skill sets, and requested tool
  package/config sources;
- model and deterministic bindings while the real core checks their relations;
- identical output after request/map permutations, changed cwd/environment, and
  resolution from a second physical clone with the same objects;
- repeated runs leave mapped refs, index, working tree, config, and object store
  unchanged; their only Git writes are cleaned private object views.

Negative transport and map fixtures cover empty/multi-root JSON, BOM, invalid UTF-8,
duplicate keys, noncanonical bytes, zero/nine manifest boundary before map/source access,
per-object and total oversize boundaries, missing/extra/duplicate mappings, two IDs
for one common object store, relative roots, repository subdirectories, unsafe
components, and symlinked roots/Git paths. A physical-root canary must not enter a
successful output. Rejected request/map canaries must not enter an error. Canonical
IDs, repository-relative paths, bindings, and scope refs are expected in successful
output and are tested as such.

Negative Git fixtures cover wrong storage algorithm/OID length, abbreviated IDs,
branch/tag/revision syntax, missing/wrong commit type, corrupt or missing objects,
wrong root tree, wrong path case, literal names such as `--help`, `-C`, and
`:(glob)*`, wrong final OID/type/mode, intermediate blob, symlink, gitlink,
replacement refs, grafts,
alternates, promisor/partial-clone state, compatibility object format, lazy-fetch
attempts, and persistent mapped-repository state drift before completion. A network
trap proves no command contacts a remote. A path-walk trap changes a mapped tree
after its snapshot and proves enumeration uses only the private verified view.

Negative graph fixtures cover a noncanonical or non-blob profile/manifest object,
missing/extra/ambiguous manifest sources, wrong manifest ref/package/config/tool,
offer/request mismatch, duplicate source claims, config without its manifest
contract, dormant capability use, model/deterministic drift, and protected-role
identity/boundary/authority collisions. The tests assert that core, not the assembly
helper, rejects the core relation rows.

Inert-content fixtures put shell syntax, environment placeholders, URLs, prompt
instructions, `allowed-tools`, and secret-like strings inside package/config/prompt/
skill payloads. Resolution may hash those bytes, but process/network traps prove it
never executes, expands, sources, fetches, loads them as runtime imports, or echoes
them. Startup traps
also cover hostile `PATH`, `BASH_ENV`, `SHELLOPTS`, exported shell functions,
`PS4`, `GIT_TRACE*`, `HOME`, and XDG/Git config; marker files prove none executes
before the shell body or later resolver runtime.

The plan names exact local commands after core G3 exists. Final proof includes the
real resolver suite, the accepted core suite, pinned ShellCheck 0.11.0 over every
shell file, existing regression suites, `git diff --check`, green CI on the exact
reviewed head, and a one-file-at-G2 scope check for this spec PR.

### Intent questions answered

1. **Caller inputs and returned provenance.** The caller supplies exact profile and
   manifest source locators plus separate selection and repository-context refs,
   and supplies the private physical map separately. The output returns the accepted
   resolved-profile fields: recomputed profile ref/source, both scope refs, exact
   binding copies, manifest/package/config/prompt/skill/tool sources, and derived
   adapter implementation IDs/versions. It adds no trust claim.
2. **Repository mapping without path leakage.** The invocation-only map is an exact
   logical-ID set over canonical physical repository identities. Physical roots are
   neither hashed into IDs nor copied to output or errors. Equivalent clones produce
   identical canonical output.
3. **Git, path, hash, and symlink checks.** The resolver accepts SHA-1 and SHA-256
   storage repos, full commit/object IDs, literal one-component tree walking, exact
   type/mode/OID and raw-payload verification, disabled/fail-closed replacement and
   lazy-fetch state, no alternates, and no symlink/gitlink traversal.
4. **Config, secret refs, skills, and identity.** Exact Git objects are verified and
   hashed as inert bytes. No config/skill/identity schema is invented; no secret
   value is read from an external store. Core checks only its accepted refs and role
   separation. Later contracts own content meaning and authentication.
5. **Compatibility, errors, idempotency, and adversarial proof.** The real core
   validator owns compatibility/separation, the resolver has a closed physical-Git
   error contract and fixed precedence, output is path/order/environment independent,
   and the matrix above covers both hash formats, multi-repo truth, hostile state,
   non-effects, and leakage.

## Out of scope

- Changing core schema v1, adding a document/capability/permission, or modifying the
  accepted core validator's semantics or public commands.
- Authenticating the caller, logical-to-physical repository association, selection,
  repository context, principals, authority, policy, grant, gate, or qualification.
- Selecting a live profile; running, materializing, installing, migrating, or
  packaging an adapter; invoking a model/tool; executing candidate code; or making a
  Git, forge, CI, credential, network, deployment, or other external write.
- Defining config/secret/identity/skill/package formats, parsing their content,
  validating a literal-secret policy, or recursively approving a selected tree for
  execution.
- Fake adapter execution, the producer/forge 2x2 matrix, inventory/result formats,
  real-adapter qualification, external-target smoke, telemetry, or evals.
- Remote repositories, remote object lookup, object alternates, partial clones,
  non-Git stores, non-SHA-1/SHA-256 object formats, or mutable revision selection.
- Continuing the rejected broad #154 spec, closing parent #153, or claiming this
  child completes portable-core roadmap item 1.

## Areas of concern

1. **Core G3 does not exist yet.** This spec may reach G2, but an implementation-ready
   plan and all code wait for and pin the accepted core implementation commit.
2. **Exact is not trusted.** Full Git objects, SHA-256 value digests, selection refs,
   and repository-context refs make claims reproducible. They do not authenticate the
   caller, mapping, decision, adapter, or authority.
3. **The physical map is sensitive local context.** It is intentionally absent from
   canonical records and diagnostics. That also means a resolved profile cannot prove
   which host path was used; later evidence records the execution environment and
   trusted mapping decision separately.
4. **Opaque config cannot prove secret hygiene.** The resolver avoids secret stores,
   execution, and output leakage, but it does not inspect committed config bytes for
   literal secrets. A later accepted config policy must own that rule.
5. **Tree proof is not sandbox proof.** A tree payload and OID bind recursive content,
   but this resolver neither materializes nor approves descendants. A later control
   foundation must re-check the exact tree while enforcing filesystem, network,
   credential, and execution bounds.
6. **SHA-1 remains the repository's native claim when selected.** Recomputing the Git
   OID and recording a raw-payload SHA-256 improves audit portability; it does not
   silently convert a SHA-1 repository or its commit graph to SHA-256.
7. **Git state can move around immutable objects.** Full OIDs and one-read snapshots
   prevent mutable-ref and double-read drift. The private object view keeps path
   enumeration on verified tree bytes. Repository-state rechecks catch persistent
   context drift, but they do not grant authority to that context. A caller that
   cannot prevent a hostile host from swapping repository/config files during the
   process must first supply an isolated repository snapshot; defending against a
   privileged ABA rewrite of the mapped host filesystem is outside this child.
8. **Error privacy reduces inline diagnostics.** Stable reason IDs and adversarial
   tests are preferred over printing paths or Git messages. Operators diagnose a
   mapped repo outside this untrusted-data boundary.
9. **Implementation is security-sensitive.** Git parsing, local path handling, CI,
   and restore changes require an accepted high-risk plan, independent review, exact
   commit proof, green CI, and human merge. Constitution-path edits follow the active
   operator/`proposals/` rule; this G2 does not claim that gate has passed.
10. **Nothing changes live.** The current manager, `/yshifu`, profiles, adapters,
    target setup, credentials, and open sessions remain unchanged.
