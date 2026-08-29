# Intent: deliver policy to target reviewers
Author: Yihan (operator). Status: draft.

## Problem

PR #164 defines an exceptional-implementation and source-comment rule for ystack,
its coder routines, and its Claude-facing target template. The rule says reviewers
must block unexplained exceptions. An independent reviewer running inside another
target repository may never see it.

Codex reviewers normally read the target's applicable `AGENTS.md`. A target may
instead have only the optional `CLAUDE.md` template, and a reviewer cannot see
ystack's control-plane `REVIEW.md`. Treating those files as equivalent would create
a silent enforcement gap. Copying the full rule into several templates would create
a different problem: the author and reviewer versions could drift.

This is the strict-subset follow-up from issue #163 and PR #164, recorded as issue
#165. It carries only the operator-approved requirement to make the same accepted
rule reliably available to independent target reviewers. It does not reopen the
other #164 policy decisions and is unrelated to PR #154.

## Proposed outcome

ystack has one versioned, portable way to deliver an accepted review-policy floor
to every selected target reviewer. The author, coder, and reviewer see the same
meaning without making Claude, Codex, GitHub, or one instruction filename a core
requirement.

The delivery path records the exact policy identity and the adapter or target
instruction identity that carried it. Generated or bridged forms are checked
against one source of truth. Missing, stale, incompatible, or candidate-controlled
review rules fail closed rather than silently weakening review.

The result is proven on ystack and on an unrelated target fixture. A pull request
that changes its own applicable reviewer instructions cannot use those candidate
instructions to certify itself.

## Affected users and systems

The operator; target maintainers; Claude and other coding agents; current and future
independent reviewer adapters; target `AGENTS.md` and `CLAUDE.md` conventions;
review-policy packages or generated sections; target setup and upgrade paths;
profile resolution; contract tests; restore documentation; self-host and unrelated
target qualification evidence.

## Constraints

- Parent scope is issue #163. This child carries only the target-reviewer delivery
  gap recorded in #165 and the scoped final review of PR #164.
- G1 may proceed now. G2 waits for #164 to merge, then pins the accepted policy
  source by exact commit and blob identities. No implementation may claim the
  unmerged #164 proposal is already active policy.
- A repo-native template or checked generated section may proceed after that policy
  dependency. If G2 selects portable contract, profile-resolution, or reviewer-
  adapter fields, it also waits for and pins the accepted G2 artifacts from
  `portable-core-contracts`, `portable-profile-resolution`, and
  `portable-adapter-contract-tests`; implementation pins their G3 commits.
- Live adapter/profile activation waits for the accepted control foundation,
  durable orchestrator, default-adapter qualification, and environment-specific
  evidence required by the roadmap. General target install/upgrade machinery stays
  in the later target-packaging initiative; this child cannot implement it early.
- Core policy remains harness-, model-, and forge-neutral. Product names,
  instruction filenames, comment triggers, App identities, and vendor review
  formats belong only in templates, adapters, or selected profiles.
- Keep one source of truth for rule meaning. Any target-specific, harness-specific,
  or generated form must be derived from or mechanically checked against it; do
  not maintain independent prose copies that can drift.
- Resolve effective reviewer instructions from an accepted trust anchor outside
  the candidate change. Record exact source and delivered identities. Candidate
  content cannot choose, replace, weaken, or certify its own review floor.
- When a pull request adds or changes an applicable instruction or review-policy
  file, route that change through a separately trusted reviewer or human gate.
- Preserve the #164 floor: root-cause first; accepted-before-code exceptions; one
  private boundary; regression proof; durable provenance; temporary removal or
  permanent external-invariant lifecycle; no copy or reusable API; no safety-rail
  waiver; and no blanket core comment ban.
- A target may ban optional comments more strictly, but required legal/tooling/API,
  safety/protocol, and exception-provenance material must remain in source or an
  accepted sidecar/metadata mechanism.
- Existing target instruction files are operator-owned. Setup or upgrades cannot
  overwrite them silently. Detect conflicts, show the proposed change, and require
  the target's normal acceptance path.
- Reviewer delivery grants no source write, approval, merge, label, bypass, or
  general task capability. It only supplies trusted review instructions and records
  what was used.
- Prove clean, missing, stale, drifted, self-modifying, conflicting, and stricter-
  target cases with deterministic fixtures. Later real qualification covers both
  ystack and an unrelated target; one successful review is not portability proof.
- Keep restore and reconstruction possible without personal paths or secrets.
  External installation/settings are referenced and diagnosed, not stored as
  credentials in the repository.
- This initiative does not choose a target `AGENTS.md` template, generated section,
  instruction package, or adapter-injection design at G1. G2 compares those options
  and selects the smallest one that meets the constraints.
- Do not change live reviewer selection, enable automatic review, delete the local
  reviewer, merge any PR, or touch PR #154 in this initiative.
- Keep each artifact and implementation PR within the normal size and one-concern
  limits. Constitution-path changes follow the operator/`proposals/` boundary.

## Open questions

- What is the single canonical policy source, and which parts are universal floor
  versus target-specific additions?
- Should target delivery use a canonical `AGENTS.md`, a generated checked section,
  a versioned instruction package, reviewer-adapter input, or a combination with
  one mechanically enforced source of truth?
- How are existing target `AGENTS.md`/`CLAUDE.md` files merged or upgraded without
  overwriting owner content or preserving stale generated text?
- What exact base/default-branch trust anchor and provenance prove which rules a
  local CLI, native GitHub reviewer, or future adapter actually used?
- Which fixtures prove rule equivalence, target stricter-policy behavior,
  self-modification safety, conflict handling, restore, and unrelated-target use?
