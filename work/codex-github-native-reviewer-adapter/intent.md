# Intent: Codex GitHub native reviewer adapter
Author: Yihan (operator). Status: draft.

## Problem

ystack currently runs its own code-review harness. `scripts/codex-review.sh`
fetches a pull request, creates a local worktree, starts Codex CLI, inspects its
event stream, and posts a GitHub comment. The live manager, merge helper, tests,
setup, and restore docs all know that implementation. Choosing Codex as reviewer
therefore also means maintaining a second way to run Codex review.

Codex now has a native GitHub review experience. It can review the pull request
diff, follow `AGENTS.md`, and publish a standard GitHub review. We want to use that
native service when a profile selects Codex, without making Codex, GitHub,
`@codex` comments, or one bot's output format part of the portable core.

Native review is not automatically the same safety gate. OpenAI currently
documents it as focused on P0/P1 findings, while ystack can block on a broader
Important finding. The same integration can run write-capable `@codex fix` work
when it has permission. Native review is also asynchronous and does not emit the
local harness's head/base markers or execution trace. Those differences must be
made explicit before the current reviewer can be replaced.

This is the inactive/offline adapter-package child of the accepted roadmap's
future default-adapter rollout, with upstream lineage to
`portable-control-plane-core` at blob
`bd6f37e60aa12378aa00d0ff57aebd36b93c4a32`. It is not another core child and
does not close that parent or the default-adapter rollout item.

## Proposed outcome

ystack has an inactive, narrow `codex-github-native-reviewer` adapter with offline
contract evidence. It can understand and normalize an observed native review, but
the current local reviewer remains the only authoritative live gate.

The adapter treats the native GitHub review as a vendor projection. Given a
test-owned native-review snapshot as data, it checks the exact change and expected
reviewer identity, reads the complete review and inline findings, and maps the
observation into the accepted portable result and evidence contracts. Core policy
consumes only that neutral result. Unknown, missing, stale, or provider-hidden
facts remain explicit; they never become a clean review by assumption.

This adapter first lands inactive with offline contract evidence. Separate,
operator-accepted initiatives—not this one—will own live observation, the fixed
native trigger, shadow qualification, profile cutover, restore drill, and final
removal of the legacy local reviewer. Their conditional program end state lets a
selected profile use Codex's native GitHub service without maintaining two
permanent reviewer engines.

## Affected users and systems

The operator; future adopters; selected profiles; Codex native Code Review;
GitHub pull requests, reviews, inline comments, and App identity; the portable
contracts, profile resolver, and adapter-test runner; future fixed publishers,
qualification records, status reconciliation, default-profile activation, setup,
restore, and legacy-reviewer retirement work.

## Constraints

- This is the Codex/GitHub default reviewer adapter, not core policy. Core records,
  gates, and consumers cannot name Codex, GitHub, bot logins, comment text, or a
  provider-specific severity.
- `portable-core-contracts`, `portable-profile-resolution`, and
  `portable-adapter-contract-tests` are declared dependencies, not yet accepted.
  G1 may proceed now. This G2 waits for and pins all three accepted G2
  blobs/versions. Implementation waits for and pins all three G3 commits plus the
  accepted control-foundation and durable-orchestrator G3 outputs required by the
  roadmap order.
- Reuse the accepted validator, resolver, request/result shapes, comparison
  projection, and case inventory. Do not copy or reinterpret them inside the
  adapter.
- A native review is untrusted observed data, not canonical state or a gate
  decision. The adapter records performer, connector/publisher, observer, source,
  profile, configuration, and qualification provenance as separate facts.
- Every request and result binds the target repository, change request, exact head,
  exact base, selected profile, and review-instruction reference. Head or base
  movement makes the result stale.
- Effective review instructions must come from an accepted trust anchor outside
  the candidate change, with their exact provenance recorded. Qualification must
  establish whether the native service actually used that accepted blob. If the
  provider hides that fact, or the pull request adds or changes an applicable
  `AGENTS.md`, `REVIEW.md`, or equivalent review-policy file, the native result is
  inconclusive/advisory and cannot gate that change. Candidate-head instructions
  can never certify themselves.
- The expected immutable GitHub App identity comes from caller-supplied trust
  context outside both candidate and snapshot. Validate exact identity, native
  review ID, commit binding, request/response time, review state, and the complete
  top-level and inline finding set. This offline adapter validates the linkage; it
  does not authenticate a live GitHub source. A similar login, ordinary comment,
  reaction, edited or dismissed review, duplicate, out-of-order result, silence,
  timeout, or unknown state fails closed.
- Record only provider metadata the platform exposes. Hidden model, effort, tool,
  cost, environment, or execution facts are `unavailable` with a reason, never
  guessed or copied from local defaults.
- Reviewer authority remains exact-change read-only. It cannot edit, approve,
  publish, merge, label, bypass rules, or impersonate the human. `@codex fix`,
  Security Review, general `@codex` tasks, branch writes, and automatic review are
  outside this adapter.
- A later qualification must prove the installed native integration cannot give
  this reviewer path write, approval, merge, or bypass authority. If the product
  cannot separate review from write-capable cloud work, this adapter remains
  advisory and cannot become the gate.
- Native P0/P1 coverage cannot silently replace the current Important-finding
  policy. Qualification must prove equivalent blocking coverage, move the missing
  control to another accepted verifier, or obtain explicit operator acceptance of
  a policy change.
- This initiative does not install or configure Codex Cloud or a GitHub App, post
  `@codex review`, read live GitHub state, enable webhooks or automatic review,
  retry events, activate a profile, change `merge-ready`, or alter live manager
  behavior.
- Keep `scripts/codex-review.sh` and its current consumers unchanged and live.
  Later cutover and retirement work must preserve head/base freshness, degraded
  fail-closed behavior, the round cap, `needs-human`, human merge, restore, and a
  tested rollback window before deleting code-review-only files and tests.
- Shared manager-debate helpers remain even after the local code-review harness is
  retired. Historical artifacts are not rewritten.
- Automatic review waits for the durable orchestrator to handle missed, repeated,
  canceled, and out-of-order events. One successful native review is not proof of
  qualification, safety, or portability.
- Completing this child's G3 proves only the inactive adapter package and its
  offline tests. It does not complete roadmap item 4, qualify a real adapter, or
  authorize live observation, triggering, cutover, or retirement.
- Keep the implementation offline, reconstructable, and small enough for one
  reviewable PR. Constitution-path changes follow the operator/`proposals/`
  boundary; the operator remains the only merge authority.

## Open questions

- Which stable GitHub review and App fields prove native reviewer identity, exact
  head, and complete findings, and how should the adapter bind the request-time
  base when the native review does not expose it directly?
- What provider evidence proves the exact accepted review-instruction blob was
  used, and which protected instruction changes must always route to a separate
  trusted reviewer or human gate?
- What neutral terminal statuses and evidence distinguish clean, findings,
  pending, stale, timed-out, failed, dismissed, and inconclusive native reviews
  without parsing provider prose as authority?
- Can the real Codex/GitHub installation remove every branch-write, approval,
  merge, and bypass path while retaining native Code Review?
- Which frozen P0/P1/P2, compliance, spoofing, stale, silence, and permission cases
  must shadow qualification compare against human ground truth and the current
  reviewer before any workflow can cut over?
- What separate fixed-publisher, reconciler, cutover, restore, rollback, and
  retirement evidence is required before the local review script and its
  code-review-only maintenance surface can be deleted?
