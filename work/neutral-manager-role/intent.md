# Intent: neutral manager role
Author: Yihan (operator). Status: draft.

## Problem

ystack's live manager currently runs through Claude Code. Its role is stored in
`manager/CLAUDE.md`, loaded by the `/yshifu` command, and restored as Claude project
instructions. That file is not merely misnamed: it is the current Claude-specific
manager adapter.

The problem is that the adapter is also the product definition. One long prompt
mixes neutral manager judgment and authority with Claude subagent spawning, GitHub
issues and labels, Codex review scripts, model configuration, local checkout
assumptions, retry state, and recovery steps. `templates/yshifu-command.md` repeats
much of the same state machine. A different manager harness would have to copy and
rewrite all of it, creating policy drift.

Directly renaming the file to `manager/AGENTS.md` or another neutral-looking name
would hide the coupling without removing it. It would also break the current live
Claude command and restore path.

## Proposed outcome

ystack has one versioned, vendor-neutral manager-role contract. It defines what a
manager is responsible for, what authority it never has, which accepted artifacts
and gate results it consumes, which stage or operator-decision request it may
produce, and how it reports status and handoff reasons.

The neutral role uses only capabilities granted by accepted policy and permission
records. A selected profile may request capabilities and adapter bindings; it
cannot grant authority. The role does not name Claude, Codex, GitHub, local scripts,
labels, model IDs, command files, or one orchestration runtime. It references
accepted policy and contract identities instead of copying their rules into
another prompt.

The current `manager/CLAUDE.md` remains the live default during migration and later
becomes a thin Claude Code wrapper. GitHub projections and Codex debate/review live
behind adapters. Future manager harnesses can supply their own thin wrappers over
the same role. The default profile may still call the manager `yshifu`; the display
name does not grant authority.

## Affected users and systems

The operator; yshifu; future manager harnesses; `manager/CLAUDE.md`;
`templates/yshifu-command.md`; selected profiles; portable contracts; control and
orchestration state; Claude coder spawning; GitHub forge projections; Codex manager
debate and code review; model configuration; setup, restore, prompt activation,
shadow qualification, telemetry, rollback, and later target packaging.

## Constraints

- This initiative defines a neutral role contract, not a filename cleanup. Do not
  rename or delete `manager/CLAUDE.md` at G1.
- G1 may proceed now. G2 waits for and pins the accepted G2 artifacts from
  `portable-core-contracts`, `portable-profile-resolution`, and
  `portable-adapter-contract-tests`, plus the accepted control-foundation and
  durable-orchestrator G2 artifacts that separate authority from role logic and
  durable state. Implementation waits for and pins every corresponding G3 commit.
- The role consumes canonical artifact, risk, gate, status, result, evidence,
  profile, capability, permission, actor, environment, and qualification records.
  It cannot define a parallel schema inside prompt prose.
- Portable policy remains outside the role. Human merge, no self-approval, role
  separation, risk gates, stale evidence, exception rules, and other safety floors
  are referenced by exact accepted identity rather than independently rewritten.
- The manager never authors implementation code or implementation PRs, approves
  its own work, publishes source changes, approves a review, merges, bypasses a
  rule, mints authority, or impersonates the operator.
- The role may request operator judgment only through a typed reason and bounded
  handoff. A user one-liner is still a request, not approval. Proactive work still
  requires the accepted north-star and manager-debate gates until a later accepted
  policy changes them.
- Claude manager-session context handling and command discovery belong in a Claude
  wrapper. Coder dispatch does not. The manager produces a typed stage request;
  the durable orchestrator dispatches it through the producer adapter chosen by
  trusted profile resolution and records the actual actor, capability, and executor
  evidence. GitHub issues, PRs, comments, labels, and `gh` belong in forge or
  selected-profile adapters. Codex commands and model settings belong in reviewer,
  debate, or model adapters.
- Retry, reconciliation, missed/repeated events, backpressure, cancellation,
  durable resume, and kill-switch state belong in the durable orchestrator, not a
  manager prompt or chat memory.
- The selected profile carries the requested display name, capabilities, and
  adapter bindings. Trusted resolution plus accepted policy and permission records
  decide what takes effect; a profile never grants authority. Target or candidate
  content, ambient environment, and unaccepted prompt text cannot choose the
  manager identity, capabilities, permissions, gates, or trust anchors.
- Current behavior remains live and unchanged while the neutral contract is
  designed. No merge of an artifact silently updates the installed `/yshifu`
  command, pasted Claude project persona, or already-open sessions.
- Default-adapter implementation later proves a thin Claude wrapper, GitHub
  projection, and Codex debate/review mapping, but it cannot activate them. Live
  activation waits for an accepted default-adapter qualification record and
  environment-specific evidence from roadmap items 5–7. That record binds the
  exact workflow scope; accepted role, policy, and contract identities; resolved
  profile; adapter and configuration identities; permissions; actual model
  snapshot and reasoning effort; exact tool, prompt, skill, and verification
  references or versions; and the execution environment. A required fact that the
  provider does not expose is recorded as unavailable and cannot support live
  activation. A change to any bound identity invalidates qualification and returns
  that wrapper and environment to shadow. Alternative wrappers and environments
  qualify separately under the same contract.
- After that qualification gate, live cutover also requires exact prompt, profile,
  and configuration backups; operator approval; a newly generated command;
  replacement of the live project persona; a new session; self-host and unrelated-
  target smoke; permission checks; and a tested rollback to the prior prompt,
  profile, and configuration.
- General installation, upgrades, and conflict handling remain in the target-
  packaging roadmap item. This initiative cannot implement them early.
- Keep each artifact and implementation PR to one concern and the normal size
  budget. Constitution-path changes follow the operator/`proposals/` boundary.
- Do not combine this work with `/faber` command retirement, `.fabrica` or
  `FABRICA_*` compatibility retirement, reviewer-adapter implementation, target-
  reviewer policy delivery, or PR #154.
- The operator remains the only merge authority. G1 accepts design exploration;
  it does not approve implementation or activation.

## Open questions

- What is the smallest neutral manager request/result contract after the portable
  core records are accepted?
- Which manager decisions are role logic, which are portable policy decisions,
  and which belong entirely to the durable orchestrator?
- How should a thin wrapper load exact accepted policy, role, profile, and target
  identities without copying them into prompt prose?
- Which current `manager/CLAUDE.md` behaviors map to Claude harness, GitHub forge,
  Codex reviewer/debate, model, publisher, or orchestration adapters?
- How are display name, role identity, actor identity, and authorization kept
  distinct in records and user-facing output?
- What shadow cases prove parity for user-directed intake, proactive debate,
  exception resume, review bounce, round cap, status-only reporting, degraded
  tools, no-merge, self-host, and unrelated targets?
- What exact backup, activation, restore, and rollback evidence is required before
  the current thick Claude persona can be reduced to a wrapper?
