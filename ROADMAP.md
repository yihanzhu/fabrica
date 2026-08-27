# ystack roadmap — a portable AI-native SDLC

This document records the direction between the north star and individual
`work/<slug>/` initiatives. It preserves the architecture decisions that future
specs and plans must follow. It is not an implementation plan by itself.

The reference model is Anthropic's
[AI-Native SDLC Playbook](https://claude.com/blog/the-ai-native-sdlc-playbook),
supplemented by its
[AI-native SDLC security guidance](https://claude.com/blog/how-anthropic-secures-its-ai-native-software-development-lifecycle),
[NIST SSDF](https://csrc.nist.gov/pubs/sp/800/218/final), and
[DORA](https://dora.dev/guides/dora-metrics/). The playbook supplies useful
control objectives, not vendor requirements or a recipe to copy unchanged.

## Product boundary

ystack is a control plane for a governed software-delivery loop. Its core is:

- **harness-neutral** — Claude Code, Codex CLI, Gemini CLI, an Agent SDK, or a
  custom runner may fill an agent role;
- **model-neutral** — model names and vendors belong to a selected profile;
- **forge-neutral** — GitHub, GitLab, Bitbucket, or another Git forge may host
  the same change-request and approval contract;
- **CI-neutral** — GitHub Actions, GitLab CI, Bitbucket Pipelines, or another CI
  system may provide checks and execution;
- **Git-backed first** — committed Git artifacts are the initial durable source
  of truth. Supporting a non-Git version-control system is not a current goal.

The first shipped profile may prefer GitHub + GitHub Actions, Claude Code as a
producer, and Codex as a reviewer. Those are defaults, not requirements.

## Self-hosting and target separation

ystack is the product; a target repo is where that product runs. Target repos own
their north star, artifacts, project policy, selected profile, code, tests, and
delivery evidence. They do not inherit ystack's personal paths, credentials, or
operator approval.

The ystack control-plane repo is intentionally its own first target. Using ystack
to develop ystack is the bootstrap and dogfood path: it exposes missing gates and
keeps the backup complete. It is not sufficient proof of portability, because a
control plane can accidentally special-case itself.

The rollout therefore needs both:

- **self-host proof** — ystack improves its own control plane through the same
  artifacts and gates; and
- **external-target proof** — a fresh unrelated Git repo selects a profile and
  completes the same contracts without copying ystack-specific state.

Control-plane self-modification is always high risk. A self-hosted run cannot
rewrite or activate its own architecture, workflow, identity, eval, or safety
policy without the operator accepting the exact plan first. Source changes do
not silently change a running installation: release/sync and target upgrades are
explicit, versioned operator actions.

## Control objectives

Every implementation must preserve these rules regardless of adapter:

1. Work flows through versioned artifacts:
   `intent → spec → accepted plan → diff + tests → review → human merge →
   deploy/rollback → production feedback/incident → new intent`.
2. One source of truth is named for every artifact. Forge issues, labels, and
   comments are links, projections, and audit records; they are not a second
   hidden state machine.
3. Human judgment stays at explicit gates. An author cannot approve its own
   work, and no agent merges or passes a production gate by itself.
4. Risk changes the gate. High-risk work receives plan approval before code;
   lower-risk work may combine plan and code review when eval evidence supports
   that shortcut.
5. Skills and prompts are advisory. Rules that must always hold are enforced by
   deterministic hooks, CI, sandbox policy, branch rules, and publishers.
6. Model output is untrusted. Candidate code never shares a sandbox with a
   credential worth stealing.
7. Events are wake-up signals. A durable reconciler reads canonical state and
   repairs missed, repeated, canceled, or partially completed runs.
8. Autonomy is earned in stages: manual → shadow/read-only → bounded write →
   risk-tiered automation. Every stage has a kill switch.
9. Configuration changes are tested like code. Prompts, skills, hooks, models,
   adapters, and permissions run against versioned evals.
10. The loop is measured by user value, quality, flow, recovery, and human
    attention — never by code volume or token use alone.

## Stable interfaces

The core should use capabilities rather than vendor commands.

### Artifact and Git

- read an artifact at an exact commit;
- calculate and compare immutable identities;
- materialize an isolated snapshot or package;
- describe an allowed diff;
- record input and output commits.

### Harness

- plan from trusted artifacts in read-only mode;
- produce a bounded patch or structured artifact;
- review an exact change with no write authority;
- return a structured result and trace, with model and cost metadata when they
  apply to that harness.

### Forge

- identify the repository and default branch;
- open or find one change request for a deterministic branch;
- read approvals and current head/base identities;
- post comments, labels, or status projections;
- expose branch and code-owner controls.

### CI

- start and observe deterministic checks;
- publish machine-verifiable evidence;
- retain check state and artifacts;
- enforce environment-specific gates.

### Execution

- provision a disposable, policy-bound environment;
- isolate candidate code from credentials and the host;
- deny network by default and expose only approved tools/resources;
- destroy the environment without losing the durable session record.

### Orchestration and reconciliation

- wake from an event, schedule, or operator request;
- scan canonical state for pending or stranded work;
- retry at least once delivery without duplicating effects;
- apply backpressure, cancellation, and a kill switch;
- return an actionable recovery reason to the operator.

### Deployment and rollback

- expose deploy, status, and rollback as environment-scoped capabilities;
- require the risk tier's named authorization;
- bind a release to verified source and evidence;
- rehearse and record rollback before autonomous maintenance can invoke it.

### Observability and incident intake

- record stage, tool, adapter, gate, identity, latency, and cost events;
- receive deterministic control-band or security-scan findings;
- create a canonical incident/intent artifact without granting deploy authority;
- feed shipped failures back into evals.

### Publisher and identity

- use a short-lived, single-purpose identity;
- validate base, allowed paths, proof, approval state, and output identity;
- never execute candidate code or invoke a model;
- perform only the fixed external write for its stage.

Adapters implement these interfaces. Core artifacts and policies must not call
`gh`, `glab`, `claude`, or `codex` directly.

## Canonical state and audit

Git artifacts and their immutable identities are canonical. A forge adapter may
project state into PR/MR labels such as `stale` or `needs-human`, but deleting a
label must not erase the underlying state.

Each stage record must make these facts recoverable:

- initiative and stage;
- input and output commit identities;
- risk tier and required gate;
- harness and adapter identity/config, plus model, effort, prompt/skill version,
  and cost when they apply;
- run, retry, skip, stale, and failure reason;
- proof identity and check result;
- human decision and timestamp.

Delivery is **at least once**. Idempotency and reconciliation make repeated
delivery safe; the system does not pretend webhook delivery is exactly once.

## Risk-tiered gates

The initial policy is:

- **High risk** — constitution paths, workflows, identity/auth, security
  controls, database/schema migrations, deployment, production infrastructure,
  or broad architectural change. A human accepts `plan.md` before code.
- **Routine** — small, reversible, well-tested work within an accepted spec and
  established architecture. Plan and code may share the final change request,
  provided an independent plan check passes before the write phase.
- **Bootstrap** — work that creates its own CI or gate. It stays human-gated and
  cannot certify itself.

Every tier still requires deterministic checks and a human merge. Changing the
tier policy requires eval evidence and an operator decision.

An **accepted plan** always has a recorded decision before code. For high-risk
work that decision is the operator's approval. For routine work it may be an
independent plan check backed by eval evidence; the producing agent cannot accept
its own plan.

## Security architecture

Agent execution is split into independent boundaries:

1. **Planner/producer (brain)** — model access, trusted inputs, no repository
   write credential. It produces an artifact or patch.
2. **Verifier** — no model credential, no forge write credential, no network by
   default. It runs candidate code and produces commit-bound evidence.
3. **Reviewer** — read-only access to the exact change. It cannot edit, approve,
   or merge.
4. **Publisher (hands)** — no model and no candidate-code execution. It validates
   the artifact and uses a short-lived adapter credential for one fixed write.
5. **Session/telemetry** — a durable append-only record outside every disposable
   execution sandbox.

Agent-to-agent routes count as capabilities and must be included in the same
permission and threat model as direct tools.

## Evals and measurements

Before bounded autonomous writes, ystack needs a small regression suite built
from real work. It must cover, at minimum:

- stale and moved artifacts;
- repeated, canceled, and missed events;
- approval invalidation and no-push-after-approval;
- actor and rerun identity;
- malicious issue, PR/MR, diff, and comment instructions;
- protected-path, credential, network, and publisher boundaries;
- empty, fake, timed-out, and degraded reviews;
- reviewer severity and false-positive/false-negative behavior;
- adapter contract compliance.

Agent evals run multiple trials where behavior is stochastic. Deterministic,
model-based, and human graders are combined and calibrated. Production failures
become permanent regression cases.

The operating dashboard should pair flow and quality:

- intent-to-spec and accepted-plan-to-merge time;
- queue and human-gate wait;
- first-pass success and rework cycles;
- review latency, precision, recall samples, and stale rate;
- escaped defects and vulnerabilities;
- retry/reconciliation recovery;
- token, latency, and cost per accepted change;
- DORA throughput and instability metrics;
- user or service outcome for the target change.

## Rollout sequence

The roadmap is intentionally ordered by dependency, not by playbook stage name.
Each numbered item becomes its own intent/spec/plan chain and small PRs.

1. **Portable control-plane core** — canonical contracts, capability manifests,
   profile resolution, fake adapters, and adapter contract tests.
2. **Control foundation** — brain/verifier/publisher separation, sandbox and
   credential policy, risk gates, kill switch, and immutable evidence.
3. **Durable orchestrator** — canonical state scanner, at-least-once retry,
   reconciliation, backpressure, and operator recovery messages.
4. **Default adapters** — GitHub forge, GitHub Actions CI, Claude Code producer,
   and Codex reviewer as the first preference profile.
5. **Agent evals and telemetry** — eval/trace framework, then real default-adapter
   regression and qualification evidence, cost/latency, and flow/quality dashboard.
6. **Alternative adapters** — prove at least one alternative harness and one
   alternative forge against the same contract and safety evals. GitLab is the
   recommended first alternative forge.
7. **Shadow vertical slice** — run the artifact lane read-only/manual on real
   self-host and external-target changes, including adversarial and recovery
   smoke tests.
8. **Bounded autonomous writes** — enable one low-risk stage at a time in an
   independent PR after shadow evidence passes.
9. **Safe review-fix loop** — add autonomous fixes only after the credential and
   reconciliation boundaries are proven.
10. **Target packaging** — install profiles and adapters into a fresh target
    without copying personal configuration.
11. **Deploy and rollback** — environment tiers, named production gate, rehearsed
    rollback, and delivery evidence.
12. **Maintenance loop** — deterministic control bands and scans create new
    intents; service owners triage; shipped incidents become evals.

## Current disposition

- PR #146 is a draft experiment and must not merge. It records useful failure
  modes from a GitHub/Claude-specific implementation.
- The old Phase 2 event names are not product requirements. A supported event is
  acceptable only when it is trusted, durable, idempotent, and recoverable.
- The previous Phase 3 controls and the reconciler portion of Phase 4 move ahead
  of autonomous write enablement.
- Existing in-session and autonomous paths must converge on the same artifact
  source of truth before either is called the product loop.

## Non-goals for the first initiative

- implementing every harness or forge;
- opening autonomous write access;
- deployment or production monitoring;
- replacing Git as the first artifact store;
- preserving Claude, Codex, or GitHub as mandatory dependencies.
