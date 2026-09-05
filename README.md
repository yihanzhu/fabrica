# ystack

A small autonomous coding team. **yshifu** (the manager) runs the shop in a Claude Code
session: you approve the direction, user-directed intake, and every merge; yshifu spawns
a Claude coder subagent to build and runs a Codex reviewer to review.

Claude Code + Codex + GitHub are the **current default profile**, not product
requirements. The portable target architecture and rollout live in
[`ROADMAP.md`](ROADMAP.md).

This repo is the **control plane** — it defines *how the team works*. Target product
code normally lives in separate repos; ystack is intentionally its own target when
the team is improving the control plane itself.

**ystack** — Yihan's stack for the AI-native SDLC: an autonomous coding team, gated by human judgment.

**Get started →** [QUICKSTART.md](QUICKSTART.md) · **Direction →** [ROADMAP.md](ROADMAP.md)

## Inactive portable profile resolver

`resolver/v1/` contains the first repo-only profile resolver. It reads exact local
Git objects, assembles the existing portable-core `resolved_profile`, and asks
`scripts/core-contract.sh` to validate the complete profile set. It does not select
or activate a profile, authenticate a repository map, execute selected content, or
access a remote or credential.

The `v1` directory names the resolver's request and repository-map transport. Those
invocation documents remain version 1 while emitted core documents use schema 2.

The shell runtime is deliberately mode 0644. A trusted parent must start it with a
direct fixed-path `execve`, an empty environment allowlist, fixed dependencies, and
the test-proven resource limits. `scripts/test/portable-profile-resolution.test.sh`
is the only shipped launcher today; it is proof, not a production activation path.
The private native snapshot helper is the exception recorded in
`work/portable-profile-resolution/spec.md`. Remove it only when every supported
runtime has an equivalent accepted descriptor-relative no-follow API.

## Inactive portable core v2 fake-forge contract

`core/v2/` contains an inactive, repo-only contract for deterministic candidate
materialization by a fake forge adapter. The operation can read an exact target,
write only a caller-disposable candidate repository and scratch space, and append
deterministic evidence. It grants no network, credential, publish, push, merge, or
remote branch-write capability and is not qualified for a real forge.

The stable `scripts/core-contract.sh` wrapper and inactive resolver select this v2
generation together. This is a repo-only compatibility switch. It does not install
the resolver, select a live profile, or qualify a real forge.

The v2 registry also carries the selected evidence-identity correction. It requires
every passed evidence item to come from the exact selected execution; incident
mismatches remain valid only when all evidence is non-passing. The stable wrapper,
inactive resolver, Control closure, and scanner select it together. The prior
generation remains immutable and restorable.

## Inactive fake adapter contract matrix

`adapter-tests/v1/` runs a fixed 2×2 producer/forge matrix against one unrelated
local Git fixture. Its accepted inventory and four distinct fake entrypoints are
digest-pinned. The runner revalidates each resolved profile with portable core v2,
validates every producer and forge stage request/result, then checks payload links,
package, target, candidate, receipt, and Git identities itself.

The result is observation only. It grants no authority, qualification, approval,
publish, merge, or branch-write capability. The fakes run with a cleared environment,
fixed limits, and disposable directories, but this test does not provide or claim
mechanical network or host-filesystem isolation. Real-adapter sandbox qualification
and an external-target smoke remain required.

## Inactive control policy-set validator

`control/v1/` defines the canonical shape and order for six Control foundation
policies: credentials, duty separation, immutable evidence, kill switch, risk
gates, and sandbox. Its validator checks the set shape and relations. It does not
contain or evaluate those policies.

The package stays inactive and fail-closed. It grants no authority, activates no
profile, reads no credential, launches no adapter, and performs no external write.
Later bounded units own each policy body and its enforcement.

## Inactive Control foundation roll-up

`control/v1/control-policy-set.json` pins the six shipped policy and decision files
in the required order. It also pins their shared core contract generation and
package. The focused test recomputes all twelve file digests and the core package
closure rather than trusting the refs in the set.

This is a static, repo-only identity bundle. It adds no aggregator runtime and
makes no enforcement, qualification, approval, authority, activation, or external
effect claim. The set stays inactive and fails closed.

## Inactive duty-separation evaluator

`control/v1/evaluate-duty.sh` checks one public core v2 stage tuple against the
shipped duty-separation ceiling. It binds that policy to the validated policy set
by exact content identity. Its shipped decision binds the policy, evaluator driver,
evaluator program, policy-set validator driver/program, and complete selected
public-core package closure. Only private mirrored validator/core packages execute.
It keeps publisher dormant and compares producer, forge, verifier, reviewer,
requester, performer, and reporter identities.

The canonical result is observation only: `satisfied`, `violated`, or
`inconclusive`. The evaluator grants no authority, activates nothing, reads no
credential, runs no candidate, and performs no network or external write. Sandbox,
credential, risk, kill-switch, evidence, and publisher enforcement remain later
Control foundation units.

## Inactive risk-gates evaluator

`control/v1/evaluate-risk-gates.sh` checks one public core v2 stage tuple, its
regenerated duty-separation result, and one caller-supplied decision claim against
the shipped risk-gates policy. It binds the policy-set, policy, decision,
evaluator, duty-separation, and selected public-core identities before producing a
canonical observation. Malformed, stale, ambiguous, rejected, downgraded, and
unsupported claims are `violated`.

The decision input is only an immutable, identity-bound claim. No qualified
decision-provenance adapter exists yet, so even an internally matching accept
claim is `inconclusive` with `decision.provenance-unqualified`; this evaluator has
no `satisfied` result. It grants no approval, authority, qualification, or
permission, activates nothing, and performs no candidate, credential, network,
publish, deploy, or external-write action.

## Inactive kill-switch evaluator

`control/v1/evaluate-kill-switch.sh` checks a caller-supplied stop-state snapshot
for one attempt across global, repository, workflow, stage, and attempt scopes. It
binds the policy-set, policy, decision, evaluator, duty-separation result, and
selected public-core identities before producing a canonical observation. Any
matching stop wins; stale, replayed, conflicting, or malformed state fails closed.

The evaluator is observation only. A fully cleared snapshot may be `satisfied`,
but that grants no authority or permission and does not cancel or run anything.
The package stays inactive, reads no credential, activates no profile, and performs
no candidate, network, publish, deploy, signal, or external-write action.

## Inactive sandbox-policy evaluator

`control/v1/evaluate-sandbox.sh` checks one execution-environment claim against
the shipped sandbox ceiling. It binds the policy set, policy, decision, evaluator,
duty-separation result, and selected public-core identities before producing a
canonical observation. The ceiling requires a cleared, allowlisted environment;
fixed roots, resources, tools, and limits; no host access; denied network; and no
credential, secret, target-write, or external-write exposure.

The result is declaration-only: `satisfied`, `violated`, or `inconclusive`. Even a
`satisfied` claim does not prove that a real sandbox enforced those properties and
grants no authority, qualification, or permission. The package stays inactive,
runs no candidate or adapter, reads no credential, activates no profile, and
performs no network, publish, deploy, or external-write action.

## Inactive credential-policy evaluator

`control/v1/evaluate-credential-policy.sh` checks one credential-boundary claim
against the shipped credential ceiling. It binds the policy set, policy, decision,
duty-separation result, evaluator, and selected public-core identities before
producing a canonical observation. The ceiling permits only brokered,
single-stage model inference for producer or reviewer roles, with no credential
material exposed to the execution boundary. Candidate write or execution
permissions are incompatible with credential access.

The result is `violated` or `inconclusive`; an unqualified input claim can never
produce `satisfied`. The package stays inactive, reads no credential material or
credential-like environment value, grants no authority or qualification, activates
no profile, and performs no candidate, adapter, network, publish, deploy, or
external-write action.

## Inactive evidence-integrity evaluator

`control/v1/evaluate-evidence-integrity.sh` compares caller-supplied evidence
references with one exact public-core stage tuple. It binds the policy set,
policy, decision, evaluator, and selected core package before returning a
canonical `satisfied` or `violated` identity observation. Evidence and prior
references must keep their canonical order and unique logical identities; one
prior result digest cannot describe multiple result documents.

The launcher is an explicit trusted shell boundary; it does not claim to
self-attest bytes that Bash already loaded. The decision separately binds the
exact marked evaluation payload. The launcher extracts those fragments from a
private no-follow snapshot, verifies their content identity, and gives only the
verified bytes to the worker. Scratch producers return full final descriptor
identities over an inherited, unlinked channel; consumers bind every read to
those identities. Public-core validation uses its accounted mode
with a fixed budget, an anchored receipt descriptor, and a worker-owned root.

The evaluator never reads proof bytes. Matching references do not prove a claim
or qualify a workflow, and equal proof digests may belong to different logical
references. The package stays inactive, stores nothing, grants no authority, and
performs no candidate, credential, network, adapter, publish, deploy, or external
write.

## Inactive canonical state scanner

`orchestrator/v1/scan-state.sh` reads one bounded canonical snapshot that binds an
explicit Git repository and commit and carries canonical stage request, resolved
profile, attempt, and result records. Run it with the same repository and commit
identities:

```text
orchestrator/v1/scan-state.sh scan REPOSITORY_ID COMMIT_ID SNAPSHOT.json
```

It emits a deterministic canonical observation that classifies each stage as
terminal, stale, blocked, retryable, stranded, or pending, with a recovery action
and reason. Those fields are messages for later recovery work, not commands. The
scanner is inactive and observation only: it does not deliver events, schedule,
dispatch, retry, reconcile, write state, use a credential or network, activate a
profile, or touch a target.

## Inactive reconciliation planner

`orchestrator/v1/reconciliation-plan.jq` is a pure jq 1.6 planning filter. It
accepts one canonical scanner observation, one canonical delivery ledger, their
caller-supplied exact references, and a bounded concurrency limit. It returns a
canonical inactive plan. A delivery key binds the stage key, request digest,
planned operation, and attempt number.

Pending and failed deliveries reappear with that same key until acknowledged.
Acknowledged deliveries are suppressed. New work uses only slots left after
pending deliveries, with redeliveries first and stable stage-key order; work that
does not fit is listed as deferred. Scanner recovery actions and reasons remain
data in the plan. The filter does not dispatch, schedule, execute recovery, write
state, use a credential or network, activate a profile, publish, or touch a target.

## Inactive GitHub forge normalizer payload

`adapters/github-forge/v1/normalize.jq` validates one untrusted GitHub
change-request snapshot against caller-supplied repository, request, head, base,
app, time, instruction, and config bindings. It returns a canonical generic
observation for open, blocked, closed, merged, stale, incomplete, or unknown
state. Provider metadata stays opaque data.

This PR lands only the immutable normalizer payload. A later assembly PR can add
its manifest and default-set wiring after this payload has a durable commit on
main. The payload is offline and unqualified. It does not call GitHub or a CLI, use a
credential, change a repository or request, grant authority or qualification, or
activate a profile.

## Inactive Codex native reviewer normalizer payload

`adapters/codex-native-reviewer/v1/normalize.jq` validates one untrusted
native-review snapshot against caller-supplied repository, change request,
review, head, base, GitHub app, time, instruction, policy, and execution-boundary
bindings. It returns a canonical generic observation for clean, findings,
dismissed, timeout, failed, stale, incomplete, or non-terminal state. Provider
severity and metadata stay opaque data, and unavailable hidden execution facts
remain explicit.

This stage lands only the immutable normalizer payload. A later assembly PR can
add its manifest and default-set wiring after this payload has a durable commit
on main. The payload is offline, read-only, and unqualified. It does not invoke a
model or CLI, use a credential or network, post a review, grant authority or
qualification, or activate a profile.

## Inactive GitHub Actions CI normalizer payload

`adapters/github-actions-ci/v1/normalize.jq` validates one untrusted GitHub
Actions workflow and check snapshot against caller-supplied repository, suite,
workflow, run, attempt, job, check, app, head, base, time, instruction, config, and
execution-boundary bindings. It returns a canonical generic observation for
queued, running, passed, failed, cancelled, timed out, action-required, stale,
or inconclusive state. Provider names, text, and details stay opaque data.

This PR lands only the immutable normalizer payload. A later assembly PR can add
its manifest and default-set wiring after this payload has a durable commit on
main. The payload is offline and unqualified. It does not call GitHub or a CLI,
use a credential, rerun or cancel work, dispatch a workflow, change a repository,
grant authority or qualification, or activate a profile.

## Inactive local Git candidate materializer

`adapters/local-git-materializer/v1/` implements the existing portable-core v2
`core.forge.materialize-candidate.v2` capability without a Git forge. It reads one
exact, sanitized bare source repository and one contract-bound patch. It imports
reachable objects into a caller-disposable bare repository, applies the patch to a
scratch-only index, and returns a canonical receipt and validated stage result.
Reachable source history is limited to 65,536 objects and 256 MiB of uncompressed
object data; the streamed pack is capped at the same byte limit.
The complete source filesystem inventory is capped at 65,536 entries and 8 MiB,
and repository config is snapshotted at 1 MiB before parsing.
Each tree scan is limited to 65,536 entries, 1,024 tree objects, 64 path
components, and a 16 MiB encoded listing. Each commit or tree is size-checked
before a non-recursive tree step, and each step validates UTF-8 before its bounded
built-in path walk.
Before mutating the index, patch paths must already fit the contract and their
cumulative source blob sizes plus patch bytes must fit a 256 MiB candidate budget.

The fixed `materialize` command accepts only caller-named physical source,
candidate, and scratch boundaries, with every path independently absolute. It
also receives the execution boundary's compiled `ystack-object-closure-v1` helper,
whose source is private to this adapter package, and an explicit pinned jq 1.6
executable. It ignores the caller's executable search path.
It rejects worktrees, alternates, shallow or
partial repositories, replace or graft state, active hooks and filters, remote
configuration, unsafe paths, binary or copy/rename patches, empty subtrees,
symlinks, and submodules. It never
inherits host Git templates, checks out a worktree, or runs a transport command.
An empty producer patch returns the explicit `no-change` result. Tests cover both
SHA-1 and SHA-256 object formats with disposable local fixtures.

This PR lands only the inactive package payload. A later assembly PR may add a
manifest whose package reference points to this payload's durable commit on main.
GitHub and later GitLab change-request normalizers remain separate observation
inputs; they do not claim this materialization capability. The package is not
qualified, selected, installed, or activated. It reads no credential, contacts no
provider or real target during construction, and cannot push, publish, merge, or
grant authority.

## Inactive Claude Code producer normalizer payload

`adapters/claude-code-producer/v1/normalize.jq` validates one untrusted producer
snapshot against a caller-supplied core request, resolved profile, manifest,
target, package, config, prompt, skills, tools, model, effort, and execution
boundary. It returns a canonical observation for changed, unchanged, stale,
failed, timed out, degraded, or inconclusive work. Provider text stays data.
Before constructing the trust context, the caller must canonicalize the snapshot,
verify its SHA-256, and supply that verified content-and-digest pair. The
normalizer requires the untrusted snapshot to equal the pair, binds the expected
attempt ID and number, and requires `text/x-diff` output for a changed git patch.

This payload ships no adapter manifest. Its focused test owns a synthetic
manifest only to prove the caller-manifest and binding checks stay closed. A
later assembly PR can bind the durable main payload into the default profile.
The payload is inactive and unqualified. It does not call Claude Code, invoke a
model, use a credential or network, write a target, publish, or activate a
profile.

## Inactive local Git materializer protocol

`adapters/local-git-materializer/v1/protocol.jq` defines the pure input, receipt,
and stage-result boundary for the existing portable-core v2
`core.forge.materialize-candidate.v2` capability. It validates a complete profile,
resolved profile, manifest set, exact stage request, materialization contract, and
patch payload links before projecting a canonical path-free receipt and core-valid
result. The caller first canonicalizes and hashes both payloads, supplies those
verified content-and-digest pairs in the trust context, and keeps raw payloads
separate; changed bytes are rejected before any projection.

Successful result projection likewise requires the raw materialization receipt and
its caller-verified content-and-digest pair. The protocol rechecks the receipt's
request, attempt, source, candidate, path count, and changed/no-change relation
before its digest may back passing evidence.

This stage contains no materialization executable. Its fixture builder is test-only
and creates synthetic JSON under a caller-owned test directory; it is not a product
execution seam. The protocol cannot read a repository, write a candidate, invoke a
hook or filter, use a credential or network, contact a provider, or perform an
external effect.

A later runtime PR can consume this exact protocol and test fixture without copying
them. That PR must separately prove the physical Git and scratch boundaries before
any manifest or profile may bind the package. Nothing here is qualified, selected,
installed, or activated.

## Inactive dormant publisher normalizer payload

`adapters/dormant-publisher/v1/normalize.jq` validates one bounded publisher
decision claim against caller-supplied attempt, idempotency, repository,
change-request, head, base, tree, allowed-path, CI, review, decision-record, time,
and execution-boundary bindings. Before calling it, the caller canonicalizes and
hashes the claim, then supplies that verified content-and-digest pair. The
normalizer requires the input to equal the pair and returns only a canonical
dormant, stale, or inconclusive observation. A permit claim remains unqualified
data; it never becomes approval or authority.

This stage intentionally ships no adapter manifest. A later assembly PR can bind
the durable main payload as the default profile's deterministic publisher with no
capabilities, permissions, or tools. The payload is not the temporary construction
publisher gate and cannot call it. It uses no credential or network, performs no
merge or external write, and activates no profile.

## Inactive deterministic verifier normalizer payload

`adapters/deterministic-verifier/v1/normalize.jq` validates an already-supplied
portable-core v2 verifier request, resolved profile, adapter contract, and stage
result. It reuses the core's request, profile, and result relations, then returns
one canonical observation. It does not interpret provider or CI status as verifier
evidence. GitHub Actions remains a separate CI observation boundary. The caller
first canonicalizes and hashes the snapshot and stage result, supplies those
verified content-and-digest pairs, and fixes the expected attempt ID and number.
The normalizer rejects any mismatch before emitting their references.

This payload is offline and unqualified. It does not execute a candidate or tool,
read proof bytes, enforce a sandbox, use a credential or network, write evidence,
grant authority or qualification, or activate a profile. A later assembly PR may
add its manifest and inactive default-set binding only after the payload has a
durable commit on main. A runnable verifier still requires a separately qualified
sandbox launcher and fixed verification implementation.

## Inactive eval and trace framework

`evals/v1/run-evals.sh` runs one offline eval pass over a caller-supplied seed set
and returns one canonical run result:

```text
evals/v1/run-evals.sh run SEED-SET.json OBSERVED_AT
```

`evals/v1/eval-catalog.json` names the nine regression families the roadmap
requires before any autonomous write (stale and moved artifacts; repeated,
cancelled, and missed events; approval invalidation; actor and re-run identity;
malicious instructions; protected-path, credential, network, and publisher
boundaries; empty, fake, timed-out, and degraded reviews; reviewer severity; and
adapter contract compliance). Each family declares which grader kinds may judge
it, its trial policy, and the core evidence kinds it produces. Three families are
seeded; the other six are declared and wait for their own seeds.

The seeded cases in `evals/v1/seed-set.json` replay canonical core-v2 stage runs
through the real portable core (`scripts/core-contract.sh validate-stage-run`).
The core is the only judge: the framework records whether the core accepted or
rejected each run and with which token, then grades that observation against the
case's expectation. A wrong expectation is graded `failed`. A family that only a
model or a human can grade is graded `inconclusive`, never guessed.

The repeated, cancelled, and missed events family is seeded from
`evals/v1/seed-set-events.json`. Its cases replay canonical orchestrator state
snapshots through the real inactive state scanner (`orchestrator/v1/scan-state.sh`),
staged inside the same private runtime: a missed attempt deadline must classify as
stranded, a cancelled stage must stay terminal even when the target moves, a
failed stage must be retryable until its retry limit and blocked after it, and a
snapshot that repeats a stage or mixes a live attempt with a terminal result must
be refused. The scanner is the only judge; the framework records its
classification or refusal token and grades that against the case's expectation.

The same family is also seeded from `evals/v1/seed-set-plans.json`, which replays
observation-plus-ledger bundles through the real inactive reconciliation planner
(`orchestrator/v1/reconciliation-plan.jq`): a repeated delivery of the same key is a
redelivery, not a second effect; an acknowledged delivery is suppressed; a retry is
planned as the next attempt and refused past the retry limit; a stranded attempt is
recovered; deliveries beyond the in-flight limit are deferred with redeliveries
first; duplicate classifications or ledger entries are refused. Only what the plan
would deliver, defer, suppress, or hand to an operator is graded. A seed set may
only feed families the catalog says draw on its source.

Every run result carries the exact catalog, seed set, program, driver, launcher,
and core-closure digests, plus one trace event per case in the shape the
Observability interface names (tool, adapter, gate, identity, latency, cost).
Latency and cost are recorded as absent in this unit; the framework performs no
model call, so there is nothing honest to charge. The framework is inactive and
observation only: it does not run a candidate or adapter, invoke a model, use a
credential or network, write outside its scratch, grant qualification, or
activate a profile.

## The current default team

You talk **only** to yshifu, in a Claude Code session. yshifu orchestrates the other roles
within that session — spawning the coder and running the reviewer — so there is no
separate human channel to the workers. Claude and Codex never talk directly;
**the PR is the message bus.**

| Agent | Vendor | How it runs | Writes? |
|-------|--------|-------------|---------|
| **yshifu** (manager) | Claude | You talk to it in a Claude Code chat (`manager/CLAUDE.md`) | issues only; never authors code/PRs; **never merges** (labels `merge-ready`, hands the PR to you) |
| **Coder** | Claude | A subagent yshifu spawns with the issue/PR context — two modes: build (`routines/coder.md`) then fix (`routines/coder-revision.md`) | yes (branches, PRs) |
| **Manager-reviewer** | Codex (OpenAI) | yshifu runs `scripts/manager-review.sh` at **direction/intake altitude** — debates a proactive issue vs. the north star → PROCEED/REFINE/DROP | **veto only / read-only** (never labels or merges) |
| **Code-reviewer** | Codex (OpenAI) | yshifu runs `scripts/codex-review.sh` at **code altitude, after coding** — against the PR diff | **comments only / read-only** |

Intent/spec/plan authors are temporary stage tasks that reuse the author responsibility;
they are not new durable roles, and yshifu does not author or accept their work. The
routine plan check is a temporary read-only instance of the reviewer responsibility: it
reads the exact pushed head and returns raw evidence with no writes. Yshifu reads the full
verdict and posts it verbatim with the exact tuple. Until a portable harness wires these
stages, yshifu coordinates them manually and keeps author and reviewer separate.

## The loop

The loop is **in-session**: yshifu drives every step from one Claude Code chat. There is
exactly one coder launch per cleared issue, one review path, and one revision path.

```
  one-liner → yshifu drafts an intake issue
                                       │
        intake gate:
          • user-directed → YOU approve the concrete intake draft
          • proactive → yshifu⇄Codex manager-debate CONSENSUS under a north star
              YOU already approved (no per-issue ask)
          (yshifu alone never self-approves; see manager-review.md)
                                       ↓
              G1 intent PR → independent review → YOU merge
                                       ↓
              G2 spec-with-risk PR → independent review → YOU merge
                  • high → plan-only PR → independent review + CI → YOU merge
                  • routine → push plan-first implementation head → a different
                      reviewer records the exact head/blobs on the intake issue
                                       ↓
              yshifu applies `ready` (all earlier gates passed)
                                       ↓
              yshifu takes a durable `claimed` pickup, clears `ready`, and spawns
              [Coder] subagent  → opens PR (label round-0)
                                       ↓
              yshifu runs scripts/codex-review.sh  → Codex posts comments only
                                       ↓
              yshifu spawns [Coder, fix mode]  adopt reasonable / push back
                                       │              (bump round-N)
                          ┌── round < 3 ┘
                          ↺  yshifu re-runs codex-review.sh
                          └── round = 3 (cap) → SCOPE DOWN + FOLLOW-UP (productive):
                                 land the converged core (one scoped-down change →
                                 clean review → `merge-ready` → YOU merge) + open a
                                 follow-up issue for the contested remainder; only a
                                 genuine standoff / safety-rail / north-star →
                                 label `needs-human` → pings YOU
                                       ↓
              CI green + Codex clean at that head/base → yshifu labels the PR `merge-ready`
                 and hands it to YOU → YOU merge (yshifu never merges; a status scan
                 or brief only reports). A moved head or base voids `merge-ready` — re-review first.
                 (high-risk / escalations / rail changes / north-star → named at handoff)
```

## Design decisions (the "why")

- **Responsibilities are stable; adapters are replaceable.** Add a role only for a
  distinct *job + trigger + tool surface* — not per discipline. The current profile
  maps those responsibilities to Claude and Codex.
- **Cross-vendor review is a preference, not a requirement.** The requirement is an
  independent reviewer identity, context, and permission boundary. A different vendor
  is the preferred default because it can reduce common blind spots.
- **Reviewer is read-only, comments only, never the author.** Non-negotiable.
- **Judgment lives at the direction (front gate at the north-star altitude), not the diff.**
  You approve the **north star** — each target repo's own committed
  [`.ystack/north-star.md`](templates/.ystack/north-star.md) (when the target *is* this
  control-plane repo, that file is the root [`NORTH_STAR.md`](NORTH_STAR.md) — ystack is its
  own target) — and yshifu pursues it
  autonomously — you stop reading diffs line by line (you still merge every PR, but on the
  strength of `merge-ready`), and for **proactive** work you stop approving each issue.
  Two paths clear intake. For a **user-directed** issue, your one-liner is the
  *request*: yshifu drafts the intake issue and **you approve that concrete draft**.
  For a **proactive** issue, **yshifu⇄Codex manager-debate consensus** clears intake
  without a per-issue ask, but only under an active north star you explicitly approved
  (see [`reviewer/manager-review.md`](reviewer/manager-review.md)). **yshifu acting
  alone never self-approves.** Neither intake path earns `ready` by itself.
  New normal work then follows one pipeline: operator-merged G1 `intent.md` →
  operator-merged G2 `spec.md` with accepted `risk: high|routine` → the applicable
  manual plan gate → `ready` → `claimed` pickup → implementation. High risk uses an independently
  reviewed, operator-merged plan-only PR before code. Routine work pushes `plan.md`
  as the first implementation-branch commit; a different reviewer records the exact
  remote head and blobs on the intake issue before code. For *proactive* work you are
  otherwise pulled back in only at the north-star altitude: **north-star achieved**,
  **goal drift / transition**, and `needs-human` escalations. You still merge every
  artifact, plan, and implementation PR.
- **CI is the hard gate** — ground truth. Autonomy rests on tests first, diverse
  reviewer second.
- **yshifu never merges — it labels, then hands you the PR.** Merging is the operator's,
  always. `main`'s branch ruleset requires a pull request plus **one approving review**, the
  Codex reviewer is **comments-only and never approves**, and **no agent has a bypass** — so
  there is no agent merge path at all. What yshifu does instead: when a PR's **current head**
  is CI-green **and** an authenticated review passed **that exact head and base**—re-queried
  immediately before labeling—yshifu applies
  **`merge-ready`** — a label that means only *"this head/base passed Codex review"* — and
  hands the PR to you, naming anything you should weigh. **You merge.** `merge-ready` is
  **void the moment the head or base moves**: GitHub keeps the label across those changes,
  so yshifu clears it, re-runs
  `codex-review.sh` on the new head, and re-applies it only on a fresh pass — a stale label is a
  false green. A later **status/Tracking scan and the brief only surface `merge-ready` PRs
  (read-only)** — they never merge either. High-risk PRs are handed over **with the risk named**
  even when CI-green and Codex-clean (auth, DB/schema migrations, shared/production repos,
  security-sensitive or other operator-judgment changes); `merge-ready` records a clean review,
  it never means "merge without looking." **Gate-creating bootstrap PRs get no `merge-ready` at
  all** — an "add PR CI" PR or a greenfield 0→1 scaffold *creates* the gate, so no real gate yet
  exists to certify it, and the new workflow can self-report green on its own PR; you approve and
  merge those by hand. You're also brought in for `needs-human`/round-cap escalations,
  safety-rail changes, and **north-star milestones / goal drift**. **`scripts/merge-pr.sh` stays
  in the repo for your own use** — it reads the reviewed head+base SHAs from the authenticated
  `codex-review.sh` marker and refuses if either moved, gates on the base branch's **required
  status checks** (falling back to ≥1 real passing CI check with none failing when none are
  defined — optional checks like preview deploys are informational), refuses a PR that still
  needs an **approving review** (`reviewDecision=REVIEW_REQUIRED`), stays **scoped to the target
  repo**, and merges with a **repo-permitted method** (squash if allowed) **pinned via
  `--match-head-commit`**. **yshifu never runs it, on any PR.**
- **One rounds counter (~3), and the cap is productive.** Comments resolved or disagreement
  burned both count; a single push-back doesn't escalate. At the ~3-round cap yshifu **scopes
  down + splits** rather than dead-ending: land the part the reviewer is satisfied with (one
  scoped-down final change → clean review → `merge-ready` → you merge the core) and **open a
  follow-up issue** for the contested remainder (logged, not lost). `needs-human` is **reserved** for when even the
  scoped-down core is contested, it's a genuine coder↔reviewer standoff, or it's a
  safety-rail / north-star decision — only then does the cap reach you. The cap **count** is
  unchanged; only how it resolves.
- **The current profile projects state into labels, not memory.** Each coder is a fresh
  subagent, so `round-0..3`, `needs-human`, and `merge-ready` currently survive in forge
  labels. The portable core moves canonical stage, retry, stale, and decision state into
  durable records; labels remain a UI projection rather than a second state machine.
- **Runs on the plan** in an ordinary Claude Code session (Claude coder subagents) plus
  Codex's built-in review via `scripts/codex-review.sh` — compliant ordinary use, metered.
  Prototype on personal repos; apply terms diligence before any work/shared repo.

> **Autonomous write is paused for re-planning.** The artifact spine is useful, but draft
> PR #146 bound the lane to one harness/forge and exposed missing credential, eval, and
> reconciliation controls. It must not merge. The portable core and control foundation in
> [`ROADMAP.md`](ROADMAP.md) come before any autonomous write is enabled.

## Model policy

**Spend by leverage, not by volume.** A run touches far more producer tokens (the
coder writing code) than gate tokens (a reviewer judging a diff), so naively giving
everything the same model either overspends on volume or underspends on judgment.
ystack instead routes by the *leverage* of the decision, not by how much text it
produces:

- **Gates decide → always max.** The code-review gate (`scripts/codex-review.sh`)
  and the manager-debate gate (`scripts/manager-review.sh`) run at maximum
  reasoning effort, always — there is no per-task/class routing that would lower
  them. A bad gate call (approving a broken PR, debating a proposal against the
  wrong bar) is expensive to unwind later, so gates never get a cheaper tier.
- **Producers type → fixed ceilings.** The coder subagent and "hands" work
  (mechanical, low-judgment steps) run at a fixed model ceiling, set once and never
  escalated at runtime — not even when a task looks hard. A task that seems to need
  a bigger model is a signal to **decompose the task or fix the spec upstream**,
  not to reach for more horsepower mid-run. Producer volume is what makes cost add
  up, so this is where the fixed ceiling lives.
- **Frontier thinks, never types.** The most capable models are reserved for
  judgment (gates), not generation (producers) — the opposite of routing by output
  volume.

**Config: `config/models.conf`.** Shell-sourceable (POSIX `KEY=value`, no bashisms)
shipped defaults, read by any script here via `. config/models.conf`:

| Key | Default | Meaning |
|-----|---------|---------|
| `YSTACK_CODER_MODEL` | `sonnet` | Claude coder subagent model. A floating alias tracks that alias's latest release; a full model ID pins an exact snapshot. Fixed ceiling by design — never escalated at runtime. |
| `YSTACK_HANDS_MODEL` | `haiku` | Model for mechanical "hands" work. Same never-escalated principle, cheaper ceiling. |
| `YSTACK_CODEX_MODEL` | *(empty)* | Codex model for the review/debate gates. Empty means inherit the operator's Codex CLI / `~/.codex/config.toml` default (whatever frontier codex that resolves to). Set only to pin a specific model — gates are never downgraded by task class. |
| `YSTACK_REVIEW_EFFORT` | `high` | Reasoning effort for the code-review gate. Always max. |
| `YSTACK_DEBATE_EFFORT` | `high` | Reasoning effort for the manager-debate gate. Always max. |

**Per-target override.** A target repo may commit its own `.ystack/models.conf`
(same format, same keys — copy it from
[`templates/.ystack/models.conf`](templates/.ystack/models.conf)) to override the
**producer/model keys only** (`YSTACK_CODER_MODEL`, `YSTACK_HANDS_MODEL`,
`YSTACK_CODEX_MODEL`) for that repo — **`YSTACK_REVIEW_EFFORT` /
`YSTACK_DEBATE_EFFORT` are never target-overridable**; a target can never lower or
otherwise change its own review/debate gate. This mirrors where the north star lives
(a target's own `.ystack/` directory — see
[`templates/.ystack/north-star.md`](templates/.ystack/north-star.md) and the
"Judgment lives at the direction" design decision above), so both kinds of
per-target committed state — the goal and the model policy — live in the same
place, owned by the target repo, not the ystack control-plane clone. The
review/debate gates (`scripts/codex-review.sh` / `scripts/manager-review.sh`) apply
it **after** the shipped defaults, so it only needs to set the keys it wants to
change, and it is a **static per-repo commitment** — set once and committed, never a
per-task rescue. Because it is target-committed content, the gates **parse it as
data** (`scripts/lib/models-conf.sh`) — never `source`/`.`/`eval` it — and
`codex-review.sh` reads it from the repo's gh-bound default branch (fetched fresh),
never the untrusted PR head under review. `scripts/doctor.sh` check (k) validates the
shipped defaults (`config/models.conf` present, sourceable, coder/hands values
non-empty) and check (l) warns if `CLAUDE_CODE_SUBAGENT_MODEL` is set in the
environment (it would silently override a per-spawn model argument).

**Wiring status: foundation + gates + coder spawn + hands all wired.** The review
and manager-debate **gates** (`scripts/codex-review.sh` / `scripts/manager-review.sh`)
already read `config/models.conf` (and a target's `.ystack/models.conf` override) to
resolve the Codex model + reasoning effort for every run. The **coder spawn** reads
this config too ([#111](../../issues/111)): yshifu's own instructions
(`manager/CLAUDE.md` / `templates/yshifu-command.md`) read `config/models.conf`, then a
target's committed `.ystack/models.conf` override if present, before every coder spawn
(round-0 or fix-mode), and pass the resolved `YSTACK_CODER_MODEL` as an explicit
`model` parameter — a fixed ceiling, never escalated at runtime, including on a bounced
review round (see the bounce protocol in `manager/CLAUDE.md`, which replaces any notion
of mid-round model escalation). The **hands-work ceiling** (`YSTACK_HANDS_MODEL`) is
now wired too ([#112](../../issues/112)): yshifu's instructions describe a delegation
policy — context-heavy reads and multi-step polling (watching CI to completion, PR-diff
summaries, review-thread collection, bulk `gh` queries) go to a `YSTACK_HANDS_MODEL`
subagent via the same config-resolution mechanism, passed as the spawn's `model`
parameter, while single quick writes (one comment, one label, one short handoff note) stay
inline; hands agents must return key raw lines plus a summary, never a bare conclusion,
so yshifu's decisions rest on evidence. This is a **prompt-level** wiring: it takes
effect once `scripts/install.sh` regenerates the live `/yshifu` command, not merely by
merging the doc change — `doctor.sh`'s static validation is unaffected.

## Portable contract validator

`scripts/core-contract.sh` is the stable, manual front door for the portable v2
contract package. It accepts canonical JSON through three fixed forms:

```text
scripts/core-contract.sh validate-document DOCUMENT
scripts/core-contract.sh validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...
scripts/core-contract.sh validate-stage-run REQUEST RESOLVED_PROFILE RESULT
```

It requires jq 1.6. Success is silent. Failure prints one `E_*` class without
printing document bytes or paths. Validation proves only that supplied records match
the portable structure and relationships. It does not prove provenance, trust, a
permission grant, or policy approval. Only the inactive resolver and tests call it
today. No manager, selected profile, target template, installer, or live `/yshifu`
path calls it.

A trusted inactive caller can account for the validator's own scratch writes by
adding `--accounted-validation SCRATCH_ROOT REMAINING_BYTES` before one of the
three forms above and opening file descriptor 3 for the receipt. The root must be
a caller-owned physical directory with mode 0700. The validator checks the exact
size before each file write, never writes past the supplied remainder, and returns
exactly `written-bytes:N` on descriptor 3. Its normal stdout, stderr, exit status,
and validation rules stay the same. This interface does not grant target, network,
credential, install, or profile-selection authority.

## Layout

```
QUICKSTART.md              The ~10-min golden path: stand the team up from scratch
ROADMAP.md                 Portable architecture, control objectives, and rollout order
CLAUDE.md                  Repo conventions + self-modification safety rails (vs manager/CLAUDE.md = yshifu's persona)
manager/CLAUDE.md          yshifu's persistent role (paste into Claude Code)
routines/coder.md          Coder baseline instructions yshifu passes to a spawned coder subagent
routines/coder-revision.md Coder fix-mode instructions (handle review feedback)
routines/brief.md          Brief instructions yshifu can run (resurfacing; not auto-scheduled)
reviewer/codex-review.md   Codex reviewer mechanism + in-session review loop
reviewer/manager-review.md Codex manager-reviewer mechanism (issue-as-bus): rounds + consensus / veto-only
scripts/install.sh         Generate the /yshifu command with a repo-derived path (idempotent)
scripts/codex-review.sh    Codex reviewer harness: post `codex exec review` to a PR, verbatim (stamps Reviewed-head: marker)
scripts/manager-review.sh  Codex manager-reviewer harness: debate a proposed issue vs. the north star, post the verdict to the issue verbatim
scripts/merge-pr.sh        Safe merge harness for the OPERATOR's own use (yshifu never runs it): SHA-pin to reviewed head + repo-scope + required-checks gate + review-required refuse, then merge (repo-permitted method)
scripts/setup-target-repo.sh  Bootstrap a target repo's loop labels (idempotent)
scripts/core-contract.sh    Manual public front door for the portable v2 contracts
evals/v1/                  Inactive eval/trace framework: catalog of the nine required regression families, seeded core, state-scanner, and planner replays, canonical run results
scripts/lib/north-star.sh  Resolver: returns the active target repo's committed .ystack/north-star.md (or root NORTH_STAR.md when ystack itself is the target)
scripts/doctor.sh          Read-only restore + readiness self-check (install, auth, restore-critical files, north star, model config, ...)
config/models.conf         Shipped model-tiering defaults (coder/hands ceilings, gate models/effort) — see "Model policy" below
templates/yshifu-command.md Template for the /yshifu command (path placeholder)
templates/target-CLAUDE.md Drop into each target repo (conventions + PR-size rule)
templates/.ystack/north-star.md  Template each target copies to .ystack/north-star.md as its own committed north star
templates/.ystack/models.conf  Template each target may copy to .ystack/models.conf to override specific model-tiering keys
templates/repo-setup.md    Labels + branch protection checklist
NORTH_STAR.md              This repo's own target north star + done-signal + log — the resolver returns it only when ystack itself is the target; other targets keep theirs in .ystack/north-star.md
RESTORE.md                 Disaster-recovery runbook: rebuild the team from this repo
```

## Rollout

- **Phase 1** — prove the in-session loop on one seeded target repo. Front gate held the
  judgment; merge was manual while the loop earned trust.
- **Phase 2** — live: the loop runs end to end in-session, and **you merge at the gate**.
  yshifu labels a PR **`merge-ready`** when its current head is CI-green and the reviewer
  passed that exact head/base, then hands the PR to you — naming the risk on high-risk work, and
  escalating `needs-human`/round-cap, safety-rail changes, and north-star milestones / goal
  drift. Both the **brief** and a **status / Tracking pass** are **read-only — they surface
  `merge-ready` PRs, they never merge**. No agent merges: `main` needs a pull request plus an
  approving review the comments-only reviewer cannot give, and no agent has a bypass.
- **Next** — migrate the current profile behind portable adapters, establish the
  control/eval/reconciliation foundation, then qualify and enable one bounded
  workflow scope at a time in each execution environment.
  [`ROADMAP.md`](ROADMAP.md) is authoritative. **The merge gate does not widen** —
  the operator merges in every phase.
