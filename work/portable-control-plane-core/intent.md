# Intent: portable control-plane core
Author: Yihan (operator). Status: draft.

## Problem

ystack's current control plane mixes its durable workflow with one preferred
implementation. Core roles, prompts, model settings, review scripts, GitHub
events, labels, secrets, and publishing commands name Claude, Codex, and GitHub
directly. A different coding harness or Git forge cannot run the same governed
loop without rewriting the product.

That coupling also hides the true safety contract. Cross-vendor review is useful,
but the requirement is separation of duties and independently verified evidence,
not a particular pair of vendors.

## Proposed outcome

ystack has a small, vendor-neutral core that defines artifact and stage-result
contracts, risk metadata, evidence references, and adapter capabilities. A
selected profile supplies the producer, verifier, reviewer, forge, CI, execution,
identity, and publisher adapters used by a stage. An adapter is a small bridge
between the core and an external tool. The core's extension rules let later
control, orchestration, deployment, and incident capabilities join without
changing existing artifact or audit meaning; this initiative does not design or
enforce those later controls.

The current GitHub + GitHub Actions + Claude Code + Codex combination remains a
working default while this core is introduced. Contract tests can swap fake
harness adapters while holding the forge fixed, then swap fake forge adapters
while holding the harness fixed. Each combination preserves the same artifact,
policy, and audit contract. Contract validation rejects malformed or incompatible
declarations. Later initiatives decide, prove, and enforce the capabilities a
risk tier requires.

## Affected users and systems

The operator; future adopters; target repositories; the `work/` artifact chain;
canonical stage/result schemas; profile resolution; capability declarations;
fake adapters; contract tests; and the current setup that must keep working while
later initiatives extract its real adapters.

## Constraints

- Git is the first canonical version-control and artifact protocol. GitHub is an
  adapter, not a requirement.
- Claude Code and Codex are preference adapters, not core requirements.
- Core policies and artifacts cannot call vendor CLIs, APIs, events, secrets, or
  model names directly.
- Author, verifier, reviewer, and publisher capabilities remain separated. An
  adapter cannot weaken no-self-approval, human merge, proof, or sandbox rules.
- Canonical formats must be extensible across
  `intent → spec → accepted plan → build → verify → independent review → human
  merge → deploy/rollback → production feedback/new intent` without changing
  earlier audit meaning. This initiative defines only the common artifact/result/
  profile/capability foundation; later initiatives design and implement
  orchestration, deployment, and monitoring.
- The current setup must keep working unchanged. Real adapter extraction happens
  in later initiatives; there is no one all-at-once rewrite.
- ystack remains its own first target for dogfooding, but core contracts cannot
  special-case the control-plane repo. Contract tests include an unrelated target
  fixture, and a later external-target smoke is required before portability is proven.
- Start with interfaces, fake adapters, and contract tests. Do not enable new
  autonomous writes in this initiative.
- Keep changes small, reversible, documented, and reconstructable from the repo.

## Open questions

- What is the smallest extensible result format for the complete
  `intent → spec → accepted plan → build → verify → independent review → human
  merge → deploy/rollback → production feedback/new intent` loop, without
  implementing the later stages now?
- What risk metadata and capability declarations must the core carry so later
  policies can decide whether an adapter may support a risk tier?
- Should canonical skills live under `.ystack/skills/`, an open Agent Skills
  layout, or another neutral package with generated harness bridges?
- What compatibility seams must the contracts expose so later adapter extraction
  can preserve current behavior without putting vendor names in the core?
- What fields must an evidence reference and fake-adapter contract-test result
  carry so later eval initiatives can set real-adapter qualification rules without
  changing audit meaning?
