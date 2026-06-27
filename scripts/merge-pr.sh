#!/usr/bin/env bash
set -euo pipefail

# merge-pr.sh — the safe in-session merge mechanism.
#
# This is the mechanical, safety-guarded way to merge a PR in-session AFTER a clean Codex
# review on a low-risk PR. It is READ-ONLY until the final `gh pr merge`: every step before
# that only reads PR state, and any failed guard refuses (non-zero) without mutating anything.
#
# WIRING: this is invoked by Faber's in-session auto-merge flow — for a clean, low-risk,
# in-session-reviewed PR, Faber runs this script to merge instead of stopping at the human
# merge gate (the Faber sources manager/CLAUDE.md and templates/faber-command.md encode
# that). High-risk PRs still go to the human gate; Faber never calls this for them. The
# unattended status-scan / cross-repo auto-merge path (a daemon merging many repos' PRs
# without a Faber session) is a FUTURE EXTENSION — see the note below.
#
# What it enforces (the MECHANICAL safety — not judgment):
#   1. SHA-pin     — it merges only the exact commit Codex reviewed. It reads the
#                    reviewed head SHA from the `Reviewed-head:` marker that
#                    scripts/codex-review.sh stamps into its PR comment, confirms the
#                    PR's CURRENT head still equals that SHA (the race guard: refuse if
#                    the author pushed after the review), and passes
#                    `--match-head-commit "<reviewed-sha>"` to the merge as a final,
#                    server-side belt-and-suspenders.
#   2. Repo-scope  — like codex-review.sh, it `unset`s GH_REPO and derives the repo from
#                    the cwd's remote, passing an explicit `--repo "$repo"` to every gh
#                    call, so a stray GH_REPO can't merge a PR in a different repo.
#   2b. Base-pin  — it also reads the reviewed BASE SHA (`Reviewed-base:`) and confirms the
#                    PR's CURRENT base still equals it immediately before the merge, so a
#                    base that advanced after the review (a different effective diff) is
#                    refused.
#   3. CI-green    — it confirms CI is green on the current head before merging. When the
#                    base branch's protection defines REQUIRED status checks, the gate is
#                    those required contexts (a pending/failing OPTIONAL check — a preview
#                    deploy, coverage bot, etc. — is informational and does NOT block). When
#                    no required checks are defined (unprotected / free private repo), it
#                    falls back to the legacy gate: refuse unless ≥1 check passes and none
#                    fail/pend. Either way the guarantee holds: never merge with a failing
#                    REQUIRED check, and never merge with zero passing checks.
#   3b. Review-gate — if the base branch requires ≥1 APPROVING review (the PR's
#                    reviewDecision is REVIEW_REQUIRED), it refuses: Fabrica's reviewer is
#                    comments-only and never approves, so that protection is incompatible
#                    with the in-session auto-merge path — it hands to the human merge gate.
#   3c. Merge-method — it detects the repo's allowed merge methods (squash / merge / rebase)
#                    and prefers `--squash`, falling back to a permitted method; the
#                    `--match-head-commit` SHA-pin works across all three. If none is
#                    allowed it refuses with an actionable message.
#
# RESIDUAL LIMITATION (base-race, honest): `--match-head-commit` pins ONLY the head — gh
# has no `--match-base-commit`, so the merge cannot atomically pin the base server-side the
# way it pins the head. This script minimizes the window by doing the `baseRefOid ==
# Reviewed-base` re-check as LATE as possible (immediately before `gh pr merge`, after the
# CI query), but a PR landing on the base in the gap between that re-check and the merge
# would still merge into an unreviewed base. That race is fully closed ONLY by a server-side
# gate — branch protection with "require branches to be up to date before merging" (or a
# merge queue) on the base branch. That is a per-repo setting and a documented setup step;
# the script alone cannot eliminate the race.
#
# What it deliberately does NOT do: it does NOT judge whether the Codex review passed,
# nor whether the PR is low/high-risk. That judgment is Faber's (Faber invokes this only
# for a clean review + low-risk PR; high-risk → human). This script is the mechanical
# backstop, not the decision-maker.
#
# It operates on the CURRENT repo only and merges in-session: run it from within the
# target repo's clone, after running scripts/codex-review.sh on the same PR in this
# session. The unattended status-scan / cross-repo auto-merge path (a daemon that scans
# many repos' PRs and merges without a Faber session) is a FUTURE EXTENSION of this
# mechanism — it is NOT supported yet; do not assume it here.
#
# Usage: scripts/merge-pr.sh <PR#>
#   (or, with fabrica/scripts on PATH: merge-pr.sh <PR#>)

usage() {
  echo "usage: $0 <PR#>" >&2
  echo "  run from within the target repo's clone, after scripts/codex-review.sh on the same PR" >&2
  echo "  refuses unless: a Reviewed-head marker exists, the PR head still equals it, CI is green" >&2
  echo "  (required checks if branch protection defines them, else ≥1 pass / no fail), and the" >&2
  echo "  PR does not need an approving review (Fabrica's reviewer is comments-only)" >&2
  echo "  then merges (squash if allowed, else a permitted method), pinned to the reviewed SHA" >&2
}

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

pr="$1"

# Preflight — fail honestly and early with an actionable pointer, before any gh call.
#   gh  — GitHub CLI (authenticated); reads PR state and performs the merge
#   jq  — parses the `gh pr checks --json` CI buckets
missing=()
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "error: missing required command(s): ${missing[*]}" >&2
  echo "       install and configure them, then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites (gh authenticated)" >&2
  exit 1
fi

# Validate the PR argument is a bare positive integer before any gh call uses it.
if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "error: PR# must be a number, got: $pr" >&2
  usage
  exit 1
fi

# Pin gh to the cwd's checkout, not whatever GH_REPO points at (mirror codex-review.sh):
# unset GH_REPO so gh falls back to the cwd's remote, AND derive the repo from the cwd to
# pass an explicit --repo to every gh call (belt-and-suspenders). This binds the merge to
# the cwd's repo, so a stray GH_REPO can't merge a PR in a different repo.
unset GH_REPO

if ! repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [ -z "$repo" ]; then
  echo "error: not inside a git repo with a gh-recognized remote" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Read the reviewed head AND base SHAs from the LATEST AUTHENTICATED codex-review.sh
# comment on the PR. The marker lines alone are NOT trusted — any PR author or collaborator
# could comment them to spoof a review and get an unreviewed integration merged. We accept
# the markers only from a genuine harness comment, which must satisfy BOTH:
#   (a) AUTHOR — the comment is authored by the gh-authenticated operator (the account
#       that runs codex-review.sh). A collaborator's comment has a different author login.
#   (b) SIGNATURE — the comment carries the harness's distinctive header
#       `## Codex reviewer (cross-vendor, read-only)` (the exact text codex-review.sh
#       prefixes) TOGETHER WITH the `Reviewed-head: <40-hex>` marker line. A spoof that
#       copies the marker but not the header fails this; reproducing both still fails (a).
# We resolve the operator login from the same gh auth this script merges with, filter
# comments to that author carrying the header, take the most recent (by createdAt), and
# extract BOTH its `Reviewed-head:` and `Reviewed-base:` SHAs FROM THE SAME comment (so
# head and base are always read from one consistent review, never mixed across comments).
# The `^...$` anchors match only the marker lines the harness writes, so prose mentioning
# the phrase can't spoof it. We emit the two SHAs space-separated on one line (both are
# fixed 40-hex, so a space split is unambiguous) and read them into shell with `read`.
operator="$(gh api user -q .login 2>/dev/null || true)"
if [ -z "$operator" ]; then
  echo "error: could not resolve the gh-authenticated operator (gh api user)" >&2
  echo "       ensure gh is authenticated, then re-run" >&2
  exit 1
fi

marker="$(
  gh pr view "$pr" --repo "$repo" --json comments \
    | jq -r --arg operator "$operator" '
        .comments
        | sort_by(.createdAt) | reverse
        | map(select(.author.login == $operator))
        | map(select(.body | test("(?m)^## Codex reviewer \\(cross-vendor, read-only\\)$")))
        | map({
            head: (.body | capture("(?m)^Reviewed-head: (?<sha>[0-9a-f]{40})$"; "g").sha),
            base: (.body | capture("(?m)^Reviewed-base: (?<sha>[0-9a-f]{40})$"; "g").sha)
          })
        | map(select(.head != null and .base != null))
        | (.[0] // empty) | "\(.head) \(.base)"'
)"
read -r reviewed_sha reviewed_base <<<"$marker"

if [ -z "$reviewed_sha" ] || [ -z "$reviewed_base" ]; then
  echo "error: no authenticated Codex review found on PR #$pr" >&2
  echo "       need a comment by the gh operator ($operator) carrying the codex-review.sh" >&2
  echo "       header and both 'Reviewed-head:' and 'Reviewed-base:' markers — bare marker" >&2
  echo "       lines are not trusted" >&2
  echo "       run scripts/codex-review.sh $pr first, then re-run this" >&2
  exit 1
fi

# Confirm the PR's CURRENT head still equals the reviewed SHA. If the author pushed after
# the review, the head moved and the review no longer covers what we'd merge — refuse and
# ask for a re-review (this is the race guard).
current_head="$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)"
if [ "$current_head" != "$reviewed_sha" ]; then
  echo "error: head changed since review ($reviewed_sha -> $current_head); re-review before merging" >&2
  echo "       run scripts/codex-review.sh $pr on the new head, then re-run this" >&2
  exit 1
fi

# Approving-review protection (additive guard). GitHub's `reviewDecision` is REVIEW_REQUIRED
# when the base branch's protection requires ≥1 approving review and none is present. Fabrica's
# Codex reviewer is COMMENTS-ONLY and never approves, so `gh pr merge` would be rejected
# server-side with no actionable message. Refuse early and clearly: this protection is
# incompatible with the in-session auto-merge path — the PR must go to the human merge gate.
# (APPROVED / CHANGES_REQUESTED / null are not our concern here; the SHA-pin + CI gate below
# are the mechanical safety. We only intercept the REVIEW_REQUIRED dead-end.)
review_decision="$(gh pr view "$pr" --repo "$repo" --json reviewDecision -q .reviewDecision 2>/dev/null || true)"
if [ "$review_decision" = "REVIEW_REQUIRED" ]; then
  echo "error: PR #$pr requires an approving review (reviewDecision=REVIEW_REQUIRED); refusing to merge" >&2
  echo "       Fabrica's reviewer (codex-review.sh) is comments-only and never approves, so this" >&2
  echo "       branch-protection shape is incompatible with the in-session auto-merge path" >&2
  echo "       hand this PR to the human merge gate, or switch protection to required status checks" >&2
  echo "       (see templates/repo-setup.md > Branch protection)" >&2
  exit 1
fi

# Confirm CI is green on the current head. `gh pr checks --json` tags each check with a
# `bucket` (pass / fail / pending / skipping / cancel). Which checks GATE the merge depends
# on whether the PR's BASE branch defines REQUIRED status checks in its branch protection:
#
#   * REQUIRED checks defined (protected base) — gate on EXACTLY those required contexts:
#       - every required context must be present on the head AND in bucket `pass`
#         (a missing required context = it hasn't reported yet = not green); and
#       - a non-required (optional) check in ANY bucket — a pending preview deploy, a
#         failing coverage bot — is INFORMATIONAL and does NOT block. (operator-approved
#         semantics change: optional checks no longer stall a genuinely mergeable PR.)
#     Guarantee preserved: we never merge with a failing/absent REQUIRED check, and the set
#     of required contexts is non-empty here, so ≥1 check passes by construction.
#
#   * NO required checks defined (unprotected / free private repo — the protection endpoint
#     404s) — fall back to the LEGACY gate over ALL reported checks:
#       - AT LEAST ONE check is `pass` (something CI actually ran and passed); and
#       - NO check is fail/pending/cancel (skipping is tolerated alongside the pass);
#       - refuse on zero checks (CI is the gate, so "no checks" is not "green").
#     This closes the all-skipped hole: if every check is `skipping`, nothing passed.
#
# Either way: never merge with a failing required check; never merge with zero passing checks.
#
# `gh pr checks` exits non-zero when checks aren't all passing (e.g. 8 = pending), so we
# capture its output without letting `set -e` abort, then judge the buckets ourselves. We
# request `name` alongside `bucket` so diagnostics can name the offending checks — `gh --json`
# returns only requested fields, so omitting `name` would print null.
checks_json="$(gh pr checks "$pr" --repo "$repo" --json name,bucket 2>/dev/null || true)"
if [ -z "$checks_json" ] || [ "$(jq 'length' <<<"$checks_json")" -eq 0 ]; then
  echo "error: no CI checks found on PR #$pr head ($current_head); refusing to merge" >&2
  echo "       CI is the hard gate — there must be at least one green check" >&2
  exit 1
fi

# Determine the REQUIRED status-check contexts from the base branch's protection. The
# endpoint 404s (and `gh api` exits non-zero) when the branch is unprotected OR protected
# without required status checks — both are the "no required checks" fallback. We capture
# the body and exit code separately so `set -e` can't abort on the expected 404, then read
# the `contexts` array (legacy field; the `checks[].context` shape carries the same names).
base_ref="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName)"
# URL-encode the branch name for the REST path: slashed names like `release/1.0` or
# `feature/x` carry `/`, which a raw interpolation would send as path separators — the
# lookup would 404 and wrongly fall back to the legacy all-checks gate. `@uri` encodes
# `/` → `%2F` (and other reserved chars).
base_ref_enc="$(jq -rn --arg b "$base_ref" '$b | @uri')"
required_json=""
if required_json="$(gh api "repos/$repo/branches/$base_ref_enc/protection/required_status_checks" 2>/dev/null)"; then
  :
else
  required_json=""
fi
required_contexts="$(
  jq -r '([.contexts // []] | flatten) + ([.checks // [] | map(.context)] | flatten) | unique | .[]' \
    <<<"${required_json:-{}}" 2>/dev/null || true
)"

if [ -n "$required_contexts" ]; then
  # Protected base with required checks — gate on those contexts only.
  not_green_required=""
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    bucket="$(jq -r --arg ctx "$ctx" '[.[] | select(.name == $ctx)] | (.[0].bucket // "missing")' <<<"$checks_json")"
    if [ "$bucket" != "pass" ]; then
      not_green_required+="         - $ctx: $bucket"$'\n'
    fi
  done <<<"$required_contexts"
  if [ -n "$not_green_required" ]; then
    echo "error: required CI check(s) not green on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       required checks not passing (optional checks are informational and ignored):" >&2
    printf '%s' "$not_green_required" >&2
    exit 1
  fi
else
  # No required checks (unprotected / free private repo) — legacy gate over all checks.
  not_green="$(jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | length' <<<"$checks_json")"
  if [ "$not_green" -ne 0 ]; then
    echo "error: CI not green on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       (no required checks defined on base '$base_ref' — gating on all checks)" >&2
    echo "       not-passing checks:" >&2
    jq -r '.[] | select(.bucket != "pass" and .bucket != "skipping") | "         - \(.name): \(.bucket)"' <<<"$checks_json" >&2
    exit 1
  fi
  passing="$(jq -r '[.[] | select(.bucket == "pass")] | length' <<<"$checks_json")"
  if [ "$passing" -eq 0 ]; then
    echo "error: no passing CI check on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       every check is skipped/optional — CI must actually run and pass to be the gate" >&2
    exit 1
  fi
fi

# Confirm the PR's CURRENT base still equals the reviewed base SHA — done HERE, as the LAST
# read immediately before the merge, to minimize the base-race window. `--match-head-commit`
# and the head check above only pin the PR head; gh has no `--match-base-commit`, so the base
# cannot be pinned server-side and we must verify it as late as possible. If the base branch
# advanced after the review (in a repo without an up-to-date-branch merge queue), the merge
# would integrate the head with a base Codex never saw — a different effective diff — yet the
# head guard would still pass. Binding the base here closes most of that hole: refuse and ask
# for a re-review. (Residual: a base landing in the gap between this read and the merge below
# is closed only by server-side branch protection / required-up-to-date — see the header.)
current_base="$(gh pr view "$pr" --repo "$repo" --json baseRefOid -q .baseRefOid)"
if [ "$current_base" != "$reviewed_base" ]; then
  echo "error: base advanced since review ($reviewed_base -> $current_base); re-review before merging" >&2
  echo "       run scripts/codex-review.sh $pr on the current base, then re-run this" >&2
  exit 1
fi

# Pick a merge method the repo actually allows. Hardcoding `--squash` fails server-side on
# any repo that disallows squash merges; we detect the permitted methods and PREFER squash
# (the repo's own history convention here), falling back to merge-commit then rebase. The
# `--match-head-commit` SHA-pin below works across all three methods, so the safety guarantee
# is method-independent. If the repo allows NO merge method, refuse with an actionable error.
merge_flags="$(gh repo view "$repo" --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed)"
if [ "$(jq -r '.squashMergeAllowed' <<<"$merge_flags")" = "true" ]; then
  merge_method="--squash"
elif [ "$(jq -r '.mergeCommitAllowed' <<<"$merge_flags")" = "true" ]; then
  merge_method="--merge"
elif [ "$(jq -r '.rebaseMergeAllowed' <<<"$merge_flags")" = "true" ]; then
  merge_method="--rebase"
else
  echo "error: repo $repo allows no merge method (squash/merge/rebase all disabled); refusing" >&2
  echo "       enable at least one merge method in the repo's settings, then re-run" >&2
  exit 1
fi

# All guards passed — merge, pinned to the reviewed SHA. `--match-head-commit` is a
# server-side belt-and-suspenders on top of the head==reviewed check above: GitHub itself
# refuses the merge if the head isn't exactly this commit, closing the tiny window between
# our check and the merge call.
echo "merging PR #$pr (reviewed head $reviewed_sha, base $reviewed_base, CI green, method ${merge_method#--}) ..."
gh pr merge "$pr" --repo "$repo" "$merge_method" --match-head-commit "$reviewed_sha"
