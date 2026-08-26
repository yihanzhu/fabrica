#!/usr/bin/env bash
set -euo pipefail

# merge-pr.sh — the safe in-session merge mechanism.
#
# This is the mechanical, safety-guarded way to merge a PR in-session AFTER a clean Codex
# review on a low-risk PR. It is READ-ONLY until the final `gh pr merge`: every step before
# that only reads PR state, and any failed guard refuses (non-zero) without mutating anything.
#
# WIRING: this is invoked by yshifu's in-session auto-merge flow — for a clean, low-risk,
# in-session-reviewed PR, yshifu runs this script to merge instead of stopping at the human
# merge gate (the yshifu sources manager/CLAUDE.md and templates/yshifu-command.md encode
# that). High-risk PRs still go to the human gate; yshifu never calls this for them. The
# unattended status-scan / cross-repo auto-merge path (a daemon merging many repos' PRs
# without a yshifu session) is a FUTURE EXTENSION — see the note below.
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
#   3. CI-green    — it confirms CI is green on the current head before merging. It discovers
#                    which checks are REQUIRED from the PR's own status-check rollup, via
#                    `gh pr checks <pr> --required` (the rollup's `isRequired` flag) — readable
#                    by anyone who can view the PR, so NO branch-protection / Administration
#                    read permission is needed (a non-admin maintainer who can merge but lacks
#                    that permission is no longer locked out). When the rollup reports REQUIRED
#                    checks, the gate is exactly those (a pending/failing OPTIONAL check — a
#                    preview deploy, coverage bot, etc. — is informational and does NOT block).
#                    When the rollup reports NO required checks (gh prints `no required checks
#                    reported …` and emits no JSON), it falls back to the legacy gate over the
#                    FULL check set: refuse unless ≥1 check passes and none fail/pend. If the
#                    discovery call fails for any OTHER reason (auth/network/transient error —
#                    neither a JSON array nor the benign no-required message), it FAILS CLOSED:
#                    refuse with the captured error rather than guess. Either way the guarantee
#                    holds: never merge with a failing REQUIRED check, never merge with zero
#                    passing checks, and never merge when we could not determine the checks.
#   3b. Review-gate — if the base branch requires ≥1 APPROVING review (the PR's
#                    reviewDecision is REVIEW_REQUIRED), it refuses: ystack's reviewer is
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
# nor whether the PR is low/high-risk. That judgment is yshifu's (yshifu invokes this only
# for a clean review + low-risk PR; high-risk → human). This script is the mechanical
# backstop, not the decision-maker.
#
# It operates on the CURRENT repo only and merges in-session: run it from within the
# target repo's clone, after running scripts/codex-review.sh on the same PR in this
# session. The unattended status-scan / cross-repo auto-merge path (a daemon that scans
# many repos' PRs and merges without a yshifu session) is a FUTURE EXTENSION of this
# mechanism — it is NOT supported yet; do not assume it here.
#
# Usage: scripts/merge-pr.sh <PR#>
#   (or, with ystack/scripts on PATH: merge-pr.sh <PR#>)

usage() {
  echo "usage: $0 <PR#>" >&2
  echo "  run from within the target repo's clone, after scripts/codex-review.sh on the same PR" >&2
  echo "  refuses unless: a Reviewed-head marker exists, the PR head still equals it, CI is green" >&2
  echo "  (required checks if the PR rollup reports any, else ≥1 pass / no fail), and the" >&2
  echo "  PR does not need an approving review (ystack's reviewer is comments-only)" >&2
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
# when the base branch's protection requires ≥1 approving review and none is present. ystack's
# Codex reviewer is COMMENTS-ONLY and never approves, so `gh pr merge` would be rejected
# server-side with no actionable message. Refuse early and clearly: this protection is
# incompatible with the in-session auto-merge path — the PR must go to the human merge gate.
# (APPROVED / CHANGES_REQUESTED / null are not our concern here; the SHA-pin + CI gate below
# are the mechanical safety. We only intercept the REVIEW_REQUIRED dead-end.)
review_decision="$(gh pr view "$pr" --repo "$repo" --json reviewDecision -q .reviewDecision 2>/dev/null || true)"
if [ "$review_decision" = "REVIEW_REQUIRED" ]; then
  echo "error: PR #$pr requires an approving review (reviewDecision=REVIEW_REQUIRED); refusing to merge" >&2
  echo "       ystack's reviewer (codex-review.sh) is comments-only and never approves, so this" >&2
  echo "       branch-protection shape is incompatible with the in-session auto-merge path" >&2
  echo "       hand this PR to the human merge gate, or switch protection to required status checks" >&2
  echo "       (see templates/repo-setup.md > Branch protection)" >&2
  exit 1
fi

# Confirm CI is green on the current head. `gh pr checks --json` tags each check with a
# `bucket` (pass / fail / pending / skipping / cancel). Which checks GATE the merge depends
# on whether the PR's status-check rollup marks any check REQUIRED. We discover that from the
# PR's OWN rollup via `gh pr checks <pr> --required` (gh derives "required" from each check
# run's `isRequired` flag) — this is readable by ANYONE who can view the PR, so it needs NO
# branch-protection / Administration read permission. (The prior approach read the base
# branch's protection via `gh api .../protection/required_status_checks`, which needs that
# admin-level permission; a non-admin maintainer who could merge but lacked it hit a
# permission error and the fail-closed path then refused even a green PR. The rollup removes
# that requirement.)
#
# `gh pr checks --required` behaves (gh 2.92.0):
#   * required checks present  — exits 0, prints a JSON array of just the required checks.
#   * no required checks        — exits non-zero, prints NO JSON array, and writes
#                                 `no required checks reported on the '<branch>' branch` to
#                                 stderr. This is the benign "unprotected / no required
#                                 checks" case → legacy fallback over the full set.
#   * genuine error (auth/net)  — exits non-zero with neither a JSON array nor that benign
#                                 message → fail closed.
# `gh pr checks` also exits non-zero merely because checks aren't all green (e.g. pending),
# so we DECIDE FROM THE OUTPUT CONTENT, not the exit code: capture stdout and stderr without
# letting `set -e` abort, then classify. We request `name,state,bucket` so diagnostics can
# name offending checks (`gh --json` returns only requested fields).
#
#   * REQUIRED checks present — gate on EXACTLY those required checks:
#       - every required check must be in bucket `pass`; any other bucket (pending preview
#         deploy that is required, a failing required test) blocks — name the non-pass ones.
#       - a non-required (optional) check in ANY bucket is INFORMATIONAL and does NOT block.
#     Guarantee preserved: we never merge with a non-pass REQUIRED check; the required set is
#     non-empty here, so ≥1 check passes by construction.
#
#   * NO required checks reported — fall back to the LEGACY gate over ALL reported checks:
#       - AT LEAST ONE check is `pass` (something CI actually ran and passed); and
#       - NO check is fail/pending/cancel (skipping is tolerated alongside the pass);
#       - refuse on zero checks (CI is the gate, so "no checks" is not "green").
#     This closes the all-skipped hole: if every check is `skipping`, nothing passed.
#
# Either way: never merge with a failing required check; never merge with zero passing checks.
req_errfile="$(mktemp "${TMPDIR:-/tmp}/merge-pr-required-err.XXXXXX")"
# `|| true` so the non-zero exit (no-required-checks, or merely-pending checks) does not
# abort under `set -e` — we classify from the OUTPUT CONTENT below, not the exit code.
req_out="$(gh pr checks "$pr" --repo "$repo" --required --json name,state,bucket 2>"$req_errfile" || true)"
req_err="$(cat "$req_errfile" 2>/dev/null || true)"
rm -f "$req_errfile"

# Is req_out a non-empty JSON array (required checks present)? Tolerate the non-zero rc.
req_is_array="false"
if [ -n "$req_out" ] && jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$req_out"; then
  req_is_array="true"
fi

if [ "$req_is_array" = "true" ]; then
  # REQUIRED checks present (from the PR rollup) — gate on exactly those.
  not_green_required="$(
    jq -r '.[] | select(.bucket != "pass") | "         - \(.name): \(.bucket)"' <<<"$req_out"
  )"
  total_required="$(jq -r 'length' <<<"$req_out")"
  if [ -n "$not_green_required" ]; then
    echo "error: required CI check(s) not green on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       gated on the $total_required required check(s) from the PR rollup" >&2
    echo "       (optional/non-required checks are informational and ignored):" >&2
    printf '%s\n' "$not_green_required" >&2
    exit 1
  fi
  echo "CI gate: all $total_required required check(s) pass (from PR rollup; optional checks ignored)"
elif printf '%s\n%s' "$req_out" "$req_err" | grep -qi 'no required checks'; then
  # NO required checks reported by the rollup — the benign case. Legacy gate over the FULL
  # check set: ≥1 pass and nothing failing/pending (skipping tolerated), refuse on zero.
  checks_json="$(gh pr checks "$pr" --repo "$repo" --json name,bucket 2>/dev/null || true)"
  if [ -z "$checks_json" ] || [ "$(jq 'length' <<<"$checks_json")" -eq 0 ]; then
    echo "error: no CI checks found on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       CI is the hard gate — there must be at least one green check" >&2
    exit 1
  fi
  not_green="$(jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | length' <<<"$checks_json")"
  if [ "$not_green" -ne 0 ]; then
    echo "error: CI not green on PR #$pr head ($current_head); refusing to merge" >&2
    echo "       (no required checks reported on PR #$pr — legacy fallback gating on all checks)" >&2
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
  echo "CI gate: legacy fallback (no required checks reported) — $passing passing, none failing/pending"
else
  # Neither a JSON array of required checks nor the benign "no required checks" message — a
  # genuine unexpected failure (auth/network/transient). Fail closed: refuse rather than guess.
  echo "error: could not determine required status checks for PR #$pr; refusing to merge" >&2
  echo "       'gh pr checks --required' returned neither a list of required checks nor the" >&2
  echo "       benign 'no required checks' message — likely an auth, rate-limit, or network" >&2
  echo "       error. Merging blind could land with unverified checks. Re-run when resolved." >&2
  if [ -n "$req_err" ]; then
    echo "       gh error: $(printf '%s' "$req_err" | head -n1)" >&2
  fi
  exit 1
fi

# Pick a merge method the repo actually allows. Hardcoding `--squash` fails server-side on
# any repo that disallows squash merges; we detect the permitted methods and PREFER squash
# (the repo's own history convention here), falling back to merge-commit then rebase. The
# `--match-head-commit` SHA-pin below works across all three methods, so the safety guarantee
# is method-independent. If the repo allows NO merge method, refuse with an actionable error.
# IMPORTANT: this network read (and every other) is done BEFORE the base-race re-check below,
# so the `baseRefOid` read stays the LAST API call before `gh pr merge`. Doing it after the
# base re-check would reopen the base-race window: another PR could land on the base during
# this extra API round-trip, and we'd merge onto a base Codex never reviewed.
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

# Confirm the PR's CURRENT base still equals the reviewed base SHA — done HERE, as the LAST
# API read immediately before the merge, to minimize the base-race window. Every other network
# read (merge-method detection above, CI checks, review-decision, head re-check) happens
# earlier ON PURPOSE so this `baseRefOid` read is the final call before `gh pr merge` — no API
# round-trip sits between it and the merge. `--match-head-commit` and the head check only pin
# the PR head; gh has no `--match-base-commit`, so the base cannot be pinned server-side and we
# must verify it as late as possible. If the base branch advanced after the review (in a repo
# without an up-to-date-branch merge queue), the merge would integrate the head with a base
# Codex never saw — a different effective diff — yet the head guard would still pass. Binding
# the base here closes most of that hole: refuse and ask for a re-review. (Residual: a base
# landing in the gap between this read and the merge below is closed only by server-side branch
# protection / required-up-to-date — see the header.)
current_base="$(gh pr view "$pr" --repo "$repo" --json baseRefOid -q .baseRefOid)"
if [ "$current_base" != "$reviewed_base" ]; then
  echo "error: base advanced since review ($reviewed_base -> $current_base); re-review before merging" >&2
  echo "       run scripts/codex-review.sh $pr on the current base, then re-run this" >&2
  exit 1
fi

# All guards passed — merge, pinned to the reviewed SHA. `--match-head-commit` is a
# server-side belt-and-suspenders on top of the head==reviewed check above: GitHub itself
# refuses the merge if the head isn't exactly this commit, closing the tiny window between
# our check and the merge call.
echo "merging PR #$pr (reviewed head $reviewed_sha, base $reviewed_base, CI green, method ${merge_method#--}) ..."
gh pr merge "$pr" --repo "$repo" "$merge_method" --match-head-commit "$reviewed_sha"
