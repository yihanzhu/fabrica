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
  use a narrow transport guard for locator strings and one mechanical manifest-
  source index needed to make output construction possible, plus one fixed core-v1
  field projection that collects the selected Git closure for physical checking.
  Core independently rechecks the exact manifest set and output shapes. Passing an
  early check/projection is never core validity. Resolver code cannot copy or
  reinterpret registries, capability/permission rules, offer/request relations, or
  protected-role separation.
- **R3 — dependency identity is explicit.** This G2 pins core schema major 1 and
  the accepted core G2 blob above. It does not claim that the validator exists yet.
  The implementation-ready plan waits for core G3, records its exact merge commit,
  and treats any later dependency movement as new external context requiring fresh
  proof. G2 accepts design only; it does not accept a plan, code, or activation.
- **R4 — selection stays outside candidate data.** The caller supplies exact
  profile and manifest source locators, `selection_ref`, and
  `repository_context_ref` in the invocation frame. A profile or manifest cannot
  choose or replace any of them. The resolver carries both scope refs unchanged.
  Final core validation owns their shape when that stage is reached; earlier fixed
  transport/map/object precedence may fail first. The resolver does not authenticate
  their decision records or turn either ref into authority.
- **R5 — repository mapping is exact and private.** The caller separately supplies
  one logical repository ID to one physical local repository root. An initial check
  requires mappings for the profile and every supplied manifest locator so their
  documents can be read; unused physical roots are not opened, canonicalized, or
  probed. After the mechanical manifest-source index succeeds, the map ID set must
  equal every repository ID in every `git_object_ref` that will appear anywhere in
  the emitted resolved profile, including nested scope subjects. A missing selected
  ID fails before an unused extra ID. No final extra, missing, duplicate-ID, or
  duplicate-physical-repository entry is allowed. The association remains an
  unauthenticated caller claim. Roots and derived Git paths are used only inside the
  resolver and are never written to stdout, canonical records, or diagnostics.
- **R6 — every selected Git claim is proven physically.** For the profile,
  manifests, binding packages/configs/prompts/skills, and requested tool
  packages/configs, the resolver proves the mapped repository's storage hash
  algorithm, full commit object, root tree, literal path walk, final object ID,
  object type, file mode, and raw object payload. The same physical check covers
  every Git-object variant nested in selection, repository-context, authority, or
  other scope refs copied to output; the scope decision itself remains unauthenticated.
  It accepts only full lowercase
  SHA-1 or SHA-256 IDs of the correct length. It never accepts a branch, tag,
  abbreviated ID, revision expression, pathspec, working-tree file, index entry,
  or mutable ref.
- **R7 — trusted launch and Git reads fail closed.** A trusted parent that is already
  outside candidate control invokes the resolver runtime with the operating system's
  direct `execve` equivalent, an absolute runtime path, fixed argv, and an explicit
  environment allowlist. No dynamically linked cleaner such as `env` starts first.
  The child therefore loads with no `LD_*`, `DYLD_*`, shell-startup, Git, credential,
  trace, or ambient `PATH` state. Every Git command then uses one private wrapper with
  replacement objects and lazy fetching disabled, scratch-owned Git config/refs,
  and no hook, remote, filter, checkout, worktree materialization, or ref update. Its
  Git processes receive no mapped path, Git directory, config, ref namespace, or
  object directory. A descriptor-stable native helper first copies one bounded,
  no-follow object-store snapshot into scratch; Git reads only that private copy.
  Unsafe or non-local state is rejected and mapped repositories stay read-only.
- **R8 — paths and symlinks cannot redirect a read.** Physical roots are absolute,
  bounded, and free of symlink components. The resolver identifies the canonical
  common Git directory and object store and uses those identities for one-to-one
  map checks. A Git path follows the accepted core `RepoPath` grammar. The resolver
  walks one tree segment at a time by exact byte equality, without giving a caller
  string to Git as a pathspec. Every intermediate component must be a tree. A
  symlink, gitlink, wrong case, missing component, wrong mode, or wrong type fails.
- **R9 — one snapshot owns each observed value.** The resolver reads every commit,
  traversed tree, and selected source payload once from a descriptor-stable private
  copy of the mapped object store into a private, bounded value snapshot.
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
  manifest, and records exact sources. The resolver establishes only the total,
  unique manifest-source join needed to construct the output. The core validator
  remains the contract authority: it rechecks the exact manifest set, offers versus
  requests, full package/tool/config equality, model/deterministic rules, dormant
  roles, capability and permission subsets, and protected-role separation. Passing
  resolution means only that the claims are structurally compatible and physically
  present; it never means trusted, authenticated, granted, qualified, approved,
  selected for live use, or active.
- **R13 — deterministic and idempotent output.** The same logical invocation and
  same Git object bytes produce byte-identical output across repository-map order,
  manifest-source order, current directory, physical clone path, and cleared ambient
  environment. Bindings and source sets use the accepted core sort keys. The
  resolver derives the document ID from the canonical resolved body, so caller or
  candidate text cannot choose it. A rerun performs no external write and creates no
  durable state outside its returned document.
- **R14 — work is bounded before use.** Wrong command or arity fails before opening
  an input. After the request's bounded snapshot, parse, canonical-byte check, and
  confirmation that `manifest_sources` is an array, its length is checked before
  locator shape, uniqueness, or content. Zero or more than eight fails as
  `E_INPUT manifest-count` before the repository map or any Git source is opened.
  Each invocation file and extracted canonical document is at most 1,048,576 bytes.
  Admin snapshots are capped at 33,554,432 bytes; the descriptor-stable private
  object-store copy at 268,435,456 bytes with a 67,108,864-byte per-file cap; and
  selected value snapshots at 67,108,864 bytes with a 16,777,216-byte per-value cap.
  All scratch bytes together stay at or below 536,870,912. Git subprocesses and the
  whole invocation also have fixed time, address-space, process, and descriptor
  limits from Design. The map has at most 1,024 entries and an absolute root at most
  4,096 UTF-8 bytes. Core JSON depth/member/string/integer limits apply to extracted
  core documents. All temporary data lives under one mode-0700 directory created
  with `umask 077` and is removed on every exit.
- **R15 — failures are closed and sanitized.** After the trusted-launch precondition,
  success is exit 0 and exactly one canonical `resolved_profile` on stdout. Failure
  is nonzero, stdout is empty, and
  stderr starts with one allowlisted resolver or unchanged core error token. Raw
  Git stderr is suppressed. No error includes a physical path, environment value,
  config/prompt bytes, object payload, or any rejected caller string.
  Error precedence is fixed in Design so one defect has one stable first class.
- **R16 — proof covers truth, substitution, and non-effects.** Hermetic tests create
  local SHA-1 and SHA-256 repositories and cover single- and multi-repository graphs,
  bare/main/linked-worktree mappings, input ordering, two physical clones, every
  source category, exact boundaries, malformed core relations, unsafe Git state,
  path confusion, symlink/gitlink cases, replacement objects, alternates, partial
  clones, loader/shell/Git ambient injection, inert hostile content, output/error
  leakage, and no network/process/ref/working-tree effect. A test-owned trusted parent
  uses direct `execve` with an explicit clean environment. Tests call the real core
  validator and do not reuse resolver assembly code as their oracle.
- **R17 — one inactive implementation concern.** The later implementation is one
  reviewable PR containing the resolver runtime entry, its private assembly helper,
  independent fixtures/tests, restore-critical manifest entries, plain-language
  docs, and CI proof. The plan estimates normal-format size before code. If it needs
  a review-size exception or materially broader concern, it returns to the artifact
  gate. No current profile, manager, template, installer, adapter, or `/yshifu`
  path calls the resolver.
- **R18 — mapped Git configuration is never process configuration.** Before object
  plumbing, a no-follow OS reader snapshots only the bounded repository-layout and
  config files needed to locate and characterize the object store. Private config
  parsing disables includes and rejects every `include`/`includeIf` key without
  opening its target. A bounded no-follow inventory rejects nonregular/symlinked
  repository metadata and object-store entries before copying. No Git command uses
  a mapped cwd, Git directory, or object directory. The helper copies regular object-
  store files through already-open directory descriptors into the private scratch
  store under fixed per-file, aggregate, entry, and name limits. Mapped local/worktree
  config, refs, grafts, index, working tree, and pathnames never enter Git. Every
  `cat-file`, `hash-object`, and `ls-tree` operation uses only the private snapshot.

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
- the mechanical manifest-ref to supplied-source index required before assembly;
- safe physical repository and Git-object reads;
- exact source snapshots and value SHA-256 computation;
- mechanical assembly of an existing `resolved_profile` for core validation;
- resolver-specific errors and physical-Git fixtures.

The implementation resolves `scripts/core-contract.sh` from its own repository
root. The caller cannot replace the validator, schema path, jq source, Git wrapper,
or assembly helper. The implementation-ready plan pins the core G3 merge commit and
names the exact compatibility proof run against it.

### Trusted launch contract and invocation-only inputs

The security boundary begins in a trusted parent process that was already running
before any request, map, profile, candidate, cwd, or hostile ambient environment
entered this boundary. A helper newly started from that hostile environment is not
the trusted parent. The parent calls fixed-path `execve`, or a separately qualified
fixed-path host API with the same semantics, to start the bound shell/runtime. It
never uses `execvp`, a PATH-searching spawn variant, `system`, `popen`, a shebang as
the cleaner, `/usr/bin/env`, or another dynamically linked process that clears its
environment only after its own loader starts.

The parent builds `envp` from an empty set. It may add only fixed locale values,
launcher-created mode-0700 home/temp paths, and one launcher-owned read-only tool
path containing pre-bound dependencies when the core runtime requires lookup. It
passes a fixed trusted cwd and explicit file-descriptor allowlist. It passes no
`LD_*`, `DYLD_*`, shell-startup, exported-function, Git/config/credential/trace, or
caller-supplied environment entry. The parent binds the absolute shell, runtime,
Git, jq, hash-tool, core-validator, and input paths. Candidate/profile/map data
cannot choose an executable, option, cwd, descriptor, or environment value.

The kernel therefore presents the clean environment to the first child dynamic
loader. The resolver runtime is payload, not the cleaner. On the shell implementation
path, the parent `execve`s the fixed shell and supplies the non-executable runtime
file as a fixed argv item before the command operands.

The runtime command shape is:

```text
profile-resolve-runtime resolve RESOLUTION_REQUEST REPOSITORY_MAP
```

There is no command that accepts a profile document copied from a working tree, an
output path, an executable, a URL, a credential, or an environment map. Success
writes the canonical result to stdout; the caller decides whether and where to
persist those bytes.

The implementation plan pins one closed test tuple: operating system, architecture,
launch API, test-parent identity, shell/runtime/dependency identities, argv, cwd,
descriptor allowlist, and exact environment allowlist. The binding is operator-owned
in this manual v1 and later belongs to control foundation or trusted packaging. A
production trusted parent is not implemented or activated in this child. Direct
ambient invocation of the resolver runtime is unsupported, carries no clean-
environment claim, and is outside the security/error contract. After a trusted
parent clean-launches the runtime, the runtime's dependency preflight returns
`E_RUNTIME` before opening the request when a bound dependency is missing; it never
falls back to a shebang, ambient path, or unbound tool.

The G3 plan and build proof bind the test-owned parent's implementation/version or
digest, the resolver's ystack commit, absolute runtime dependencies, supported host,
argv, and exact environment allowlist only to verify this implementation. That proof
grants no production authority. None enters the canonical `resolved_profile`, becomes
a core `authority_ref`, or authenticates the caller. This child emits no launch-
evidence record and cannot tell whether output is paired with one. Future activation
or control-foundation work must bind the exact resolved-profile ref to separate,
accepted launch evidence before use; no output from this child is live-qualified.

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
 manifest_sources:array<source_locator>,
 selection_ref:scope_ref(selection),
 repository_context_ref:scope_ref(repository-context)}
```

The raw request-size limit bounds the array. After parse and canonical-byte checks,
the resolver checks only that the root is an object and `manifest_sources` is an
array, then immediately checks its length. Every zero or greater-than-eight array
returns `E_INPUT manifest-count`, even when an entry is duplicated or malformed.
Only a `1..8` array proceeds to full top-level shape, locator-shape, and uniqueness
checks. The locators include full storage-format object and commit
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
The resolver snapshots at most 1,048,577 bytes before parsing and rejects an extra
byte. It applies the minimal root/array guard and count first, then strict exact-key,
type, locator, and uniqueness checks. It snapshots and validates the request before
opening the map. The transport checks protect the Git call boundary; they do not
declare a core ref valid. The complete constructed graph still must pass the accepted
core validator.

### Selected source graph and Git closure

The selected source-value graph contains only sources that appear in the emitted
`resolved_profile`:

1. the one profile source;
2. exactly one source for each distinct manifest document referenced by a selected
   profile binding;
3. each selected binding's package, optional config, optional prompt, and skill
   refs;
4. each requested tool's package and optional config refs.

Unrequested tools offered by a manifest are manifest claims, not selected sources.
They are checked lexically and relationally by core but are not physically resolved
as source values. A later profile that requests one must resolve it then.

The selected Git closure is broader than the source-value graph. After the manifest
index closes, the resolver collects every candidate `git_object_ref` at the fixed
core-v1 output field paths below. This includes all source-value `source`
refs; binding package/config/prompt/skill and requested-tool refs; and Git-object
artifact variants nested in selection, repository-context, binding-authority, or
other copied scope subjects. It walks the closed field paths mechanically and
does not interpret the scope purpose, decision record, or authority. Content and
document refs add no repository ID. Unrequested manifest offers that are not copied
to the resolved profile remain outside this closure.

The projection is closed. It contains `profile_source.source`; the Git-object
artifact variant of `selection_ref.subject_ref` and
`repository_context_ref.subject_ref`; and, for every resolved binding:

- the binding's Git-object authority subject when present, package, optional config,
  optional prompt, skills, requested-tool packages, and present requested-tool
  configs;
- `manifest_source.source`, `package_source.source`, present config/prompt sources,
  skill sources, tool package sources, and present tool config sources.

It contains no `profile_ref`, `manifest_ref`, content/document ref, scope decision-
record ref/digest, adapter/model/identity ID, unrequested offered tool, or arbitrary
string named `repository_id`. The implementation projects only these fixed field
paths, then requires the projection from the completed output to equal the planned
pre-assembly closure exactly. Independent tests build their expected projection
without calling resolver code.

Every closure member contributes its `revision.repository_id` to the final map set
and receives the same exact commit/path/type/mode/OID physical check. A nested scope
Git object gains no source-value record or trust by being checked; the existing scope
ref is copied unchanged.

For caller-supplied selection and repository-context scopes, the pre-core projector
checks only the exact `subject_ref.type=artifact`, nested artifact
`type=git-object`, and transport-safe Git-object fields needed for a safe call. A
candidate at that path which passes this guard enters the closure even when another
part of its enclosing scope is malformed; physical checking is not scope acceptance,
and final core still rejects the malformed scope if reached. A value that does not
match the discriminants/guard does not drive Git. Map-set precedence may reject a
map supplied only for such an ignored malformed value before final core. This total
rule is a transport-safety projection, not a duplicate core scope validator.

The resolver first requires mappings for the profile locator and every supplied
manifest locator, but it does not yet reject unused map entries. It reads each
document, calls `validate-document`, and recomputes its `document_ref`.

It then builds one private manifest-source index:

- `expected` is the distinct `manifest_ref` set copied from the validated profile
  bindings;
- `supplied` is a multimap from each full recomputed
  `(schema_version,kind,id,sha256)` manifest document ref to its verified document
  and source; different locators that produce the same full ref remain separate
  entries until ambiguity is checked;
- one supplied ref with more than one source is
  `E_RELATION manifest-source-ambiguous`;
- an expected ref with no supplied source is `E_RELATION manifest-source-missing`;
- a supplied ref outside the expected set is `E_RELATION manifest-source-extra`.

Checks run in that order over sorted refs. Several bindings may reuse the same one
source. This is a resolver-owned construction precondition, not manifest
compatibility or authority. It exists because no `resolved_profile` can be assembled
when the join is missing or ambiguous. The final `validate-profile-set` call still
independently checks the exact supplied manifest set and every core relation.

Only after this index succeeds does the resolver derive the repository-ID set from
the complete selected Git closure above. That set must exactly equal the map ID set. A selected ID
without a map is `E_REPOSITORY map-missing`; only when none is missing does an unused
map ID return `E_REPOSITORY map-extra`. This check happens before any selected
package/config/prompt/skill/tool object is read. An extra manifest with its own valid
mapping therefore reaches `manifest-source-extra` instead of being hidden by
`map-extra`.

### Mapped repository administration is data

No Git command runs with a mapped root as cwd or with a mapped Git directory as
`--git-dir`. Before any Git command can see a mapped object store, a trusted snapshot
primitive handles repository administration files as bounded data. It walks from
pre-opened directory descriptors, uses `openat`-style no-follow/nonblocking/close-on-
exec flags for every component and leaf, then `fstat`s type/identity before one
bounded read. A shell `lstat` followed by `open` is not equivalent.

For each mapping it is allowed to open, the reader:

1. identifies only a bare repository top level, a normal top level with a `.git`
   directory, or a linked-worktree top level with a regular bounded `.git` gitfile;
2. resolves a regular bounded `commondir` file when present, then canonicalizes the
   worktree Git directory, common directory, and common `objects` directory without
   following a symlink; a linked worktree must also have an exact regular bounded
   `gitdir` backlink that resolves to the mapped worktree root's `.git` gitfile, not
   merely to the root directory. A directory alias, device, socket, FIFO, or
   repository subdirectory fails;
3. snapshots the common `config` as a regular non-symlink file of at most 1,048,576
   bytes. It also snapshots and parses any existing active Git directory
   `config.worktree` under the same rules so a dormant include cannot hide; when the
   common config enables worktree config, an absent file is an empty worktree config,
   and present non-include values become active only after both snapshots are safe;
4. parses only those private snapshots with fixed `git config --file SNAPSHOT
   --no-includes -z --list` in a clean, no-repository context, with system/global/
   command config injection disabled; any normalized `include.path` or
   `includeIf.*.path` key is rejected without opening its target;
5. derives only the repository-format facts needed here: storage object format,
   worktree-config state, compatibility format, partial-clone extension, and
   promisor flags. It requires one valid repository-format version; an absent object-
   format extension means `sha1`, and the only accepted explicit value is `sha256`.
   V1 permits only the handled object-format and worktree-config extensions, and
   rejects a compatibility format, partial/promisor state, every other
   `extensions.*` key, and an alternate ref-storage backend. It never executes or
   otherwise interprets other config values. Repository-format/object-format and
   extension facts come only from the common config; any such key in worktree config
   is invalid instead of an override. Any partial-clone/promisor key or marker in
   either source is conservatively rejected before last-wins precedence can hide it;
6. rejects mapped replacement/graft state without invoking Git: any entry below
   `refs/replace`, any bounded regular `packed-refs` line naming `refs/replace/`, or
   any `info/grafts` entry;
7. rejects any `objects/info/alternates`, `objects/info/http-alternates`, or
   `objects/pack/*.promisor` entry by no-follow inspection before the mapped object
   directory is exposed to Git;
8. descriptor-walks the complete mapped `objects` tree before copying it: every
   component is a non-symlink directory or regular file on the object-root device,
   and the bounded entry inventory contains no FIFO, device, socket, mount crossing,
   or unknown path type. It classifies exact hash-format loose-object names and
   lexically valid paired `pack-<hash>.pack`/`.idx` files. An unpaired/duplicate pack
   member fails. Only those loose objects and pack/index pairs are copied; MIDX,
   commit-graph, bitmap, reverse-index, keep, cruft-mtime, and other regular metadata
   are accepted only through a closed name/type allowlist, inventoried, and not
   exposed to private Git. An unknown/transient entry fails closed.
9. through already-open descriptors, byte-copies the closed object set into a new
   mode-0700 private reader store, using no hardlink, reflink, mapped pathname, or
   alternate. Directories stay open throughout recursion and their identity/mtime/
   ctime are checked before and after. Each leaf is opened no-follow/nonblocking,
   `fstat`-checked, charged before allocation, copied with bounded `pread`, checked
   for exact EOF and unchanged dev/inode/type/size/mtime/ctime, then hashed. The copy
   creates destination paths only from the strict ASCII object-name grammar, with
   new exclusive mode-0600 files reduced to 0400 after completion. Pack and matching
   index FDs are both opened before either copy; both post-copy stable tuples are
   checked before closing. The copy publishes from staging only after the full
   inventory succeeds.

The helper treats the admin copies, inventories, and raw object-store staging tree
as one private transaction and publishes it with fixed `renameat` only on success.
All mapped descriptors close before Git starts, and the resolver never reopens a
mapped pathname or performs a final mapped-state check. A source version established
before a leaf/directory is opened may be copied; a change overlapping its copy fails
the stable tuple checks; a change after private publish is irrelevant. A cross-file
mixed epoch is allowed only as untrusted private bytes: inconsistent pack/index data
fails inside scratch, while every successful selected object still passes full
OID/type/size verification.

The helper recognizes both v1 hash-width name grammars because common config is
parsed only from the published private admin copy. After parsing selects the storage
algorithm, the runtime requires the receipt to contain no copied loose/pack name of
the other width, then creates matching reader/verified Git views. A mixed-width store
is `E_REPOSITORY object-format`; no Git starts first.

The profile/all-supplied-manifest locator phase opens only their mapped physical
roots. Unused roots are still represented in the parsed map but are not opened,
canonicalized, or probed. After the manifest-source index, the resolver opens only
roots in the exact selected graph; every other map ID has already failed
`map-extra`. Common-directory/object-store identities provide the one-to-one physical
map check.

The bounded `.git`, `commondir`, common/active-worktree config, linked-worktree
backlink, replacement-state, and object-store copies are the only mapped bytes read.
Mapped paths, local/worktree includes, aliases, hooks, filters, credential helpers,
fsmonitor commands, refs, grafts, index, and working tree never enter a Git process.
Concurrent mapped mutation may make a bounded copy or later OID/relation check fail,
but Git still sees only stable private regular files.

### Scratch Git reader and verified object view

One private wrapper owns every Git command. The trusted parent supplies the fixed
absolute Git executable. Commands run with `LC_ALL=C`, no pager/prompt/optional
locks/lazy fetch, a private `HOME`, system/global/command config injection disabled,
and an environment allowlist rather than a `GIT_*` blacklist.

The allowlist fixes `GIT_CONFIG_NOSYSTEM=1`, points system/global config at launcher-
created empty regular files as defense in depth, fixes `GIT_CONFIG_COUNT=0`,
`GIT_OPTIONAL_LOCKS=0`, and `GIT_TERMINAL_PROMPT=0`, and omits `GIT_CONFIG`,
`GIT_CONFIG_PARAMETERS`, and every other ambient Git variable.
`GIT_CONFIG_NOSYSTEM=1` is mandatory because a platform Git may still load its own
developer-tool config when only the system path is redirected. `GIT_CONFIG` affects
the `git config` command but does not isolate ordinary Git commands; those are safe
because their Git/common directory and ref namespace are scratch-owned, not mapped.

For each canonical physical repository and storage algorithm, the wrapper creates
two mode-0700 bare scratch Git directories with empty templates, private configs,
empty ref/graft namespaces, and private object directories: one reader snapshot and
one verified view. Their closed configs contain only the required repository-format/
object-format facts plus `core.multiPackIndex=false`, `core.commitGraph=false`, and
`core.useReplaceRefs=false`; no candidate or mapped config value is copied.

The no-follow helper populates only the reader snapshot's object directory before
Git starts. Raw `cat-file --batch` with one wrapper-written full OID runs only there.
The wrapper reads Git's actual OID/type/size header, enforces the payload limit, then
snapshots exactly that many raw bytes; it never requests type conversion or tag
peeling. It recomputes the native OID in the empty verified view with fixed
`hash-object -t TYPE --stdin --no-filters`, then imports a verified commit/tree there
with fixed `hash-object -w -t commit|tree --stdin --no-filters`. The returned OID
must equal the verified OID. One-level `ls-tree -z` runs only in the verified view.
No mapped object-directory environment binding or scratch object ref ever exists.

All Git arguments are wrapper-built. The wrapper forbids `cat-file --filters`,
`--textconv`, `--follow-symlinks`, `hash-object --path`, candidate-selected types,
and any command that can contact a remote or update mapped state. Fixed global
options include `--no-pager`, `--no-replace-objects`, `--no-lazy-fetch`,
`--no-optional-locks`, and `--literal-pathspecs`. Every accepted content claim comes
from an OID-verified snapshot even if pack layout or ordinary mapped refs change.

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
   from the stable private reader snapshot, recomputes its native OID, and imports
   the verified tree snapshot into the private database.
5. A `root` location must equal that root tree with type `tree` and mode `040000`.
   For a `path`, the resolver splits the accepted `RepoPath` itself. It enumerates
   one level of the verified private tree with NUL-delimited output and matches one
   literal segment byte-for-byte. It never passes the full path to Git.
6. Every intermediate entry must be mode `040000`, type `tree`, and locally present.
   Its raw payload is read once through the scratch reader, native-OID verified, and
   imported before the next private `ls-tree`. Mode `120000`, mode `160000`, or a
   non-tree intermediate fails without reading a filesystem target.
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

The private assembly helper receives only the validated profile, the already-closed
manifest-ref to single supplied-record index, verified source-value refs, and the two
caller scope refs. It performs deterministic lookups and copies; it does not contain
an offer, capability, permission, role-separation, or trust predicate. A binding
lookup that fails after the index passed is `E_RUNTIME unexpected`, not a second
manifest relation result.

For each profile binding it:

- looks up the one indexed manifest whose recomputed `document_ref` equals the
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
snapshot/inventory checks remain valid does the resolver write the already-validated
canonical resolved-profile snapshot to stdout.

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
- The trusted parent omits ambient credentials, and the runtime never opens a secret
  store. A literal
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
| each `.git`/`commondir`/backlink path record | 4,096 bytes |
| each common/worktree config snapshot | 1,048,576 bytes |
| each `packed-refs` snapshot | 16,777,216 bytes |
| all admin snapshots/names in one invocation | 33,554,432 bytes / 8,192 names |
| mapped object-store inventory | 262,144 entries / 16,777,216 name bytes |
| each copied object-store file | 67,108,864 bytes |
| all copied object-store files | 268,435,456 bytes |
| each selected object payload | 16,777,216 bytes |
| all selected value snapshots | 67,108,864 bytes |
| all scratch bytes, including invocation/output/verified-view overhead | 536,870,912 bytes |
| one Git subprocess | 15 CPU seconds / 30 wall seconds / 536,870,912 address-space bytes / 67,108,864 output-file bytes / 64 descriptors / one Git child at a time |
| complete invocation | 300 wall seconds |
| each extracted core document | accepted core limits |

After request raw-size, parse, and canonical-byte checks, the resolver confirms only
that the root is an object and `manifest_sources` is an array, then checks length.
Zero or more than eight returns `E_INPUT manifest-count` before locator shape,
uniqueness, repository map, or Git source access. An invocation file or object uses a
one-extra-byte probe and returns
`E_LIMIT` before parsing or hashing the over-limit value. The running total is
checked before each new snapshot. A selected graph that needs more than 1,024
physical repositories, 33,554,432 admin bytes, 8,192 enumerated admin names, or
262,144 object-store entries/16,777,216 object-name bytes, 268,435,456 copied object-
store bytes, 67,108,864 selected value bytes, or 536,870,912 total scratch bytes
cannot be resolved in v1. An over-limit admin or copied object-store file fails
before Git sees that private store. An over-limit selected payload fails after its
bounded batch header and before body allocation or hashing.
The global scratch counter is stricter than the category counters: every written
byte is charged each time it is materialized, including reader copies, value
snapshots, verified-view objects, canonical inputs/outputs, and diagnostics.
Charging never rolls back after deletion. Before a copy, the helper charges the
`fstat` size in per-file, category, then global order; before a Git payload, the
wrapper charges the batch header size in the same order. Before `hash-object -w`, it
charges a host-tuple-pinned conservative encoded upper bound covering the Git object
header and worst-case compressor/file overhead, then checks the actual private file
size without refunding the reservation. Reusing one cached snapshot does not charge
again, but writing the same bytes into another file/buffer does. The invocation
reserves 256 global bytes at start for one fixed terminal diagnostic, so reporting a
limit cannot itself exceed the limit.

The trusted parent applies hard CPU/address-space/output-file/descriptor limits
before it execs the runtime; the runtime and every child inherit them and cannot
raise them. The runtime wrapper owns a fixed 30-second Git watchdog, kills and reaps
on expiry, and permits only one Git child at a time. The parent/runtime apply the
300-second invocation deadline. Candidate data and ambient state cannot raise or
disable any limit.

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
- `E_LIMIT` — a resolver transport, admin snapshot/name, object-store copy,
  selected-value, scratch, process, descriptor, or time limit above is exceeded;
- `E_RELATION manifest-source-ambiguous|manifest-source-missing|manifest-source-extra`
  — the resolver's only relation reasons; individually core-valid profile/manifests
  cannot form the total one-to-one source index required for assembly;
- `E_REPOSITORY` — mapping-set, canonical-root, common-directory/object-store,
  admin-file, config-include/config-format, storage-format, alternate/promisor/
  partial-clone, or repository state is invalid; fixed set reasons are
  `locator-map-missing`, `map-missing`, then `map-extra` in their stage order;
- `E_OBJECT` — an exact commit, tree walk, object type/mode/OID, local presence,
  symlink/gitlink, payload, or native-hash check fails.

The first failure class is chosen in this order:

1. command and arity, without opening an input;
2. clean-launched runtime/core feature preflight, without opening an input;
3. request raw-size, parse, and canonical bytes;
4. minimal request-root/manifest-array guard, then manifest count;
5. remaining request shape, locator guards, and locator uniqueness;
6. map raw-size, parse, canonical, private shape, and root-string safety;
7. locator-map coverage plus no-follow layout/config/object-store checks needed for
   the profile and all supplied manifests;
8. profile/manifest reads and their individual core document validation;
9. manifest-source index: ambiguous, then missing, then extra;
10. exact selected-graph repository-ID map set: missing, then extra;
11. no-follow layout/config/object-store checks for newly selected roots, then all
    remaining selected Git object checks;
12. mechanical assembly and final core profile-set validation;
13. final private snapshot/inventory check and output.

Within core validation, the accepted order remains limits, shape, ref, then
relation. The resolver may originate `E_RELATION` only for the three fixed
`manifest-source-*` pre-assembly failures above. It passes a core `E_RELATION`
unchanged and never appends a resolver reason or relabels it as physical Git truth.
For an unexpected tool/dependency failure it emits only `E_RUNTIME unexpected`.
Other failures may add one fixed, allowlisted reason ID after the token. Dynamic
paths, refs, Git output, JSON values, or payload fragments are never diagnostics.

### Implementation components and order

The later plan keeps one runtime-facing entry and one private product boundary:

- `resolver/v1/profile-resolve-runtime.sh` — mode-0644 inactive runtime payload,
  passed to the fixed shell only by the trusted-parent contract; it has no public
  shebang, ambient-cleaning claim, or install path;
- `resolver/v1/nofollow-snapshot.c` — small trusted product helper for descriptor-
  relative no-follow/nonblocking regular-file/directory snapshots; the plan pins its
  compiler, supported host tuple, build command, artifact digest, and runtime path;
- test-owned launcher/trap sources under `scripts/test/` — a small direct-`execve`
  parent plus platform-specific loader/audit marker libraries that prove hostile
  loader variables work in a control child and are absent from the resolver child;
- one private resolver runtime under `scripts/lib/` — snapshots, safe Git wrapper,
  source verification, core-validator calls, and sanitized exit contract;
- `resolver/v1/profile-resolution.jq` — private transport parsing, deterministic
  joins, source projection, and assembly only; no copied core acceptance predicates;
- readable test fixture builders under `scripts/test/` that create independent
  profile/manifest data and Git repositories;
- one hermetic resolver test entry point under `scripts/test/`;
- the matching `ci/required-files.txt`, README, restore, and CI updates selected by
  the accepted plan.

### Named temporary exception: native no-follow snapshot helper

This G2 names one implementation exception before code. The normal repository path
is shell plus jq. Shell alone cannot atomically walk descriptor-relative paths, open
with no-follow/nonblocking flags, `fstat` the opened object, and perform a bounded
read. A check-then-open shell sequence would reintroduce the symlink/FIFO race this
resolver exists to close.

The root-cause boundary is the one private
`resolver/v1/nofollow-snapshot.c` helper. It exposes only the fixed descriptor-walk,
type/identity check, bounded snapshot, bounded regular-file copy into private
scratch, and inventory operations required by one `snapshot-repository` action. It
is not a reusable filesystem API, arbitrary copy command, Git launcher, supervisor,
package surface, installed tool, or second copy under tests. The resolver runtime is
its only product caller.

Its only inputs are one transport-guarded mapping root, one launcher-owned empty
scratch slot, and runtime-owned remaining admin/object/name/global budget values from
the invocation ledger. It cannot accept an arbitrary source-relative path, hash
algorithm, executable, or candidate-controlled limit. It stages one repository
snapshot, returns only a sanitized private receipt with physical identities,
per-hash-width counts, charged bytes, and fixed reason IDs, and never returns a mapped
or derived path. The runtime debits that receipt before another repository call;
the helper precharges against the supplied remainder before every destination create
or read. Failure removes the unpublished staging tree before Git can start.

This exception is temporary. Remove it when every supported resolver runtime offers
an accepted, reconstructable descriptor API with equivalent `openat` no-follow/
nonblocking/`fstat` semantics, or when the resolver moves to an already accepted
runtime that provides them. Either change returns to the artifact gate and reruns
all path, FIFO, device, mount, object-store, leakage, and host-tuple tests before the
helper disappears. A second native product helper or another consumer also returns
to the artifact gate instead of copying or widening this boundary.

The plan pins this spec blob as the exception record, the exact compiler/toolchain
and host tuple, helper source/artifact digests, removal condition, restore steps, and
CI regression command. The exception waives no core validation, sandbox, credential,
review, CI, constitution, or human-merge rule.

Work proceeds in this order:

1. Wait for core G3, pin its merge commit, and prove its three public commands on the
   implementation branch before editing resolver code.
2. Land the test-owned direct-`execve` parent, inactive runtime entry, fixed runtime
   binding, and loader/shell ambient traps before the runtime reads an input.
3. Land the private transport limits and sanitized command/error boundary.
4. Land the one named no-follow helper, mapped administration/object-store data
   checks, scratch Git wrapper, and two-phase repository-map checks.
5. Land the manifest-source index, snapshot/value-digest projection, and mechanical
   output assembly.
6. Invoke the real core validator and add positive cross-hash/multi-repo cases.
7. Add the full adversarial matrix, docs, restore manifest, and CI proof.
8. Run independent Bugs, Security, and Compliance review on the exact final head.

No partial commit is wired into a live profile or installed command.

### Verification matrix

Positive fixtures prove:

- a test-owned trusted parent starts the runtime by direct `execve` with fixed argv
  and an environment built from an empty set;
- one SHA-1 repo, one SHA-256 repo, and one invocation that selects both formats;
- commit/tree imports whose returned OIDs equal their verified OIDs and whose trees
  can be enumerated in the matching private views;
- one-repo and multi-repo selected graphs;
- bare, ordinary, and linked-worktree roots that resolve to unique common object
  stores; the linked private `gitdir` backlink resolves exactly to that root's
  `.git` gitfile;
- one manifest shared by bindings and the exact 1/8 manifest boundaries;
- package blobs/trees, optional config/prompt, skill sets, and requested tool
  package/config sources;
- selection, repository-context, and binding-authority scope subjects whose
  Git-object variants live in a third mapped repository, while content/document
  subject variants add no repository mapping;
- model and deterministic bindings while the real core checks their relations;
- identical output after request/map permutations, changed cwd/environment, and
  resolution from a second physical clone with the same objects;
- repeated runs leave mapped refs, index, working tree, config, and object store
  unchanged; their only Git writes are cleaned private object views.

Repository-administration fixtures prove bare, normal, and linked-worktree layout
classification without `git -C` or mapped `--git-dir`. Loose and packed SHA-1/SHA-256
objects are copied through stable descriptors and remain readable only from the
matching private reader snapshot. Harmless but executable-looking mapped config keys—alias,
filter, textconv, hook, fsmonitor, credential helper, and replace settings—remain
inert because mapped config is never process config.

Negative transport and map fixtures cover empty/multi-root JSON, BOM, invalid UTF-8,
duplicate keys, and noncanonical bytes. Zero, nine, and 257 manifest entries return
`manifest-count` before map/source access; malformed or duplicate entries in a
nine-item array do not mask that earlier result. A non-array is `request-shape`; an
eight-item array with a malformed locator reaches `locator-shape`, and eight valid
duplicate locators reach `locator-duplicate`. Count rows name a nonexistent map/source
canary to prove neither is opened. Map cases cover missing locator coverage, final
missing/extra/duplicate logical mappings, missing-plus-extra ordering, two IDs for
one common object store, relative roots, repository subdirectories, unsafe
components, and symlinked roots/Git paths. A mapped extra manifest in its own repo
reaches `manifest-source-extra` before final `map-extra`. Per-object and total
oversize boundaries also fail without partial output. A physical-root canary must not
enter a successful output. Rejected request/map canaries must not enter an error.
Canonical IDs, repository-relative paths, bindings, and scope refs are expected in
successful output and tested as such.

Nested-scope closure rows remove the third-repository map, add an unrelated map, or
move the claimed scope-subject object/type/mode. They must produce `map-missing`,
`map-extra`, or the physical object error before success. The resolver copies the
scope ref unchanged and never treats physical existence as an accepted decision or
authority. Unrequested manifest offers remain outside the closure.
An outer-malformed caller scope with an exact guarded Git subject still enters the
closure and reaches physical proof before final core rejects the scope. A malformed
discriminant/Git candidate does not drive Git; a map supplied only for that ignored
candidate may hit `map-extra` first. These rows pin the pre-core precedence instead
of assuming every malformed scope reaches core.

Negative Git fixtures cover wrong storage algorithm/OID length, abbreviated IDs,
branch/tag/revision syntax, missing/wrong commit type, corrupt or missing objects,
wrong root tree, wrong path case, literal names such as `--help`, `-C`, and
`:(glob)*`, wrong final OID/type/mode, intermediate blob, symlink, gitlink,
replacement refs, grafts,
alternates, promisor/partial-clone state, compatibility object format, lazy-fetch
attempts, and concurrent mapped-object changes during descriptor copying. A network
trap proves no command contacts a remote. Loose/pack/directory swap tests after the
helper opens its descriptors must either fail the bounded copy/OID checks or produce
the same private bytes; Git never opens the swapped mapped pathname. A path-walk
trap changes the mapped store after copying and proves enumeration uses only the
private verified view. Race fixtures use a test-only barrier in the same helper
source, not probabilistic sleeps or a second copy implementation.

Repository-administration failures cover symlink/FIFO/device/oversize `.git`,
`commondir`, backlink, common config, active `config.worktree`, and `packed-refs`;
broken linked-worktree backlinks; unknown/compatibility extensions; partial/promisor
state; replace refs; grafts; alternates/http-alternates; and promisor pack markers.
Common plus active/inactive worktree config fixtures contain absolute, relative, and
conditional includes that point to regular canaries and blocking FIFOs. Private
`--file --no-includes` parsing must report `config-include` without opening either
target. Mapped config commands,
aliases, filters, hooks, and credential helpers must never affect scratch `cat-file`
output; replace/graft/alternate fixtures fail before object copying. A before/after
mapped object-store inventory plus a failing final validator proves the mapped store
never changes and all `hash-object -w` effects stay inside the verified private view.
File-access evidence after the helper exits contains only runtime and private-scratch
paths, never a mapped root or object pathname.
Selected loose-object paths and pack `.idx`/`.pack`/MIDX/commit-graph paths are
separately replaced by symlink, FIFO, device, socket, and cross-device fixtures;
each must fail during the bounded inventory without a Git open or hang.
Malicious MIDX PNAM values containing `..` or an absolute path point at an external
FIFO canary; fixed `core.multiPackIndex=false` must keep the MIDX and canary unopened.
File-access evidence must also show that neither mapped MIDX nor commit-graph files
are opened in reader mode.

Resource rows cover exact-limit and one-over admin totals, entry/name counts,
per-file and aggregate private object-store copies, selected payload totals, global
scratch bytes, Git address space/descriptors, per-process CPU/wall time, and total
invocation time. Oversize regular/sparse pack and index fixtures fail before Git;
test-owned CPU/sleep/memory/descriptor/file-size workers must hit the fixed `E_LIMIT`
path. Real delta-depth and malformed-pack fixtures may close as `E_OBJECT` or
`E_LIMIT`, but they cannot hang, leak, emit partial stdout, or leave private children/
scratch data behind.
Multi-repository rows spend almost all object/global budget in the first helper
receipt, then make the second repository exact-limit or one-over. The one-over call
must fail inside the helper before source read/destination creation or Git start,
proving the runtime-owned remaining ledger controls every helper invocation.

Negative graph fixtures cover a noncanonical or non-blob profile/manifest object.
The resolver source-index tests assert the three fixed ambiguous, missing, and extra
manifest-source reasons before assembly. Separate rows prove that the real core—not
the source index or assembly helper—rejects wrong package/config/tool relations,
offer/request mismatch, duplicate source claims, config without its manifest
contract, dormant capability use, model/deterministic drift, and protected-role
identity/boundary/authority collisions.

Inert-content fixtures put shell syntax, environment placeholders, URLs, prompt
instructions, `allowed-tools`, and secret-like strings inside package/config/prompt/
skill payloads. Resolution may hash those bytes, but process/network traps prove it
never executes, expands, sources, fetches, loads them as runtime imports, or echoes
them. Loader/startup traps cover `LD_PRELOAD`, `LD_AUDIT`, the supported host's other
`LD_*`/`DYLD_*` controls, `PATH`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASH_FUNC_*`,
`PS4`, `GIT_TRACE*`, `GIT_CONFIG`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`,
`GIT_CONFIG_COUNT/KEY_n/VALUE_n`, `GIT_CONFIG_PARAMETERS`, `HOME`, and XDG config.
The already-running trusted test
parent constructs those hostile values only after its own clean start. A separate
control child receives them and must fire the loader/startup markers; the resolver
child receives the explicit allowlist and must leave every marker absent. Each
claimed supported `(OS, architecture, launch API)` tuple runs this proof and the full
resolver suite; one tuple's result grants no claim for another.

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
   logical-ID set over every Git-object ref projected from the resolved profile,
   including Git-object scope subjects, and canonical physical repository identities.
   Physical roots are neither hashed into IDs nor copied to output or errors.
   Equivalent clones produce identical canonical output.
3. **Git, path, hash, and symlink checks.** The resolver accepts SHA-1 and SHA-256
   storage repos, full commit/object IDs, literal one-component tree walking, exact
   type/mode/OID and raw-payload verification, mapped config parsed only as bounded
   no-include data, scratch-only Git config/refs, fail-closed replacement/lazy-fetch
   state, no alternates, and no symlink/gitlink traversal.
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
- Shipping or activating a production trusted parent, static launcher, broker, or
  control-foundation boundary. This child includes only a test-owned direct-`execve`
  parent to prove the resolver runtime contract.
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
   enumeration on verified tree bytes. Descriptor-relative copying prevents a mapped
   pathname swap from reaching Git; concurrent writes can only yield copied bytes
   that later fail pack/OID/relation checks or form the exact content-addressed
   closure requested. A privileged actor that can alter the resolver process or its
   mode-0700 private scratch after launch remains outside this child.
8. **Mapped config is never trusted process input.** The no-follow helper and scratch
   Git namespace are mandatory product boundaries, not test conveniences. A layout,
   extension, ref backend, include, or object-store entry outside the closed v1 set
   fails instead of falling back to ordinary Git repository discovery.
9. **Error privacy reduces inline diagnostics.** Stable reason IDs and adversarial
   tests are preferred over printing paths or Git messages. Operators diagnose a
   mapped repo outside this untrusted-data boundary.
10. **Launch trust is external evidence.** A clean child environment prevents ambient
   loader/shell injection, but the resolver does not authenticate its parent. Direct
   ambient runtime calls are unsupported. Later qualification must bind the trusted
   parent and environment separately from the canonical resolved profile.
11. **Implementation is security-sensitive.** Git parsing, local path handling, CI,
   and restore changes require an accepted high-risk plan, independent review, exact
   commit proof, green CI, and human merge. Constitution-path edits follow the active
   operator/`proposals/` rule; this G2 does not claim that gate has passed.
12. **Nothing changes live.** The current manager, `/yshifu`, profiles, adapters,
    target setup, credentials, and open sessions remain unchanged.
