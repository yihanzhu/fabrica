#!/usr/bin/env bash
set -euo pipefail

# merge-pr.sh — the safe in-session merge harness.
#
# Faber invokes this in-session AFTER a clean Codex review on a low-risk PR, to merge
# that PR with mechanical safety guards. It is READ-ONLY until the final `gh pr merge`:
# every step before that only reads PR state, and any failed guard refuses (non-zero)
# without mutating anything.
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
#   3. CI-green    — it confirms CI is green on the current head before merging.
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
  echo "  refuses unless: a Reviewed-head marker exists, the PR head still equals it, and CI is green" >&2
  echo "  then squash-merges, pinned to the reviewed SHA (--match-head-commit)" >&2
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

# Read the reviewed head SHA from the LATEST AUTHENTICATED codex-review.sh comment on the
# PR. A `Reviewed-head: <sha>` line alone is NOT trusted — any PR author or collaborator
# could comment that exact line to spoof a review and get an unreviewed head merged. We
# accept the marker only from a genuine harness comment, which must satisfy BOTH:
#   (a) AUTHOR — the comment is authored by the gh-authenticated operator (the account
#       that runs codex-review.sh). A collaborator's comment has a different author login.
#   (b) SIGNATURE — the comment carries the harness's distinctive header
#       `## Codex reviewer (cross-vendor, read-only)` (the exact text codex-review.sh
#       prefixes) TOGETHER WITH the `Reviewed-head: <40-hex>` marker line. A spoof that
#       copies the marker but not the header fails this; reproducing both still fails (a).
# We resolve the operator login from the same gh auth this script merges with, filter
# comments to that author carrying the header, take the most recent (by createdAt), and
# extract its `Reviewed-head:` SHA. The `^...$` anchors match only the marker line the
# harness writes, so prose mentioning the phrase can't spoof it.
operator="$(gh api user -q .login 2>/dev/null || true)"
if [ -z "$operator" ]; then
  echo "error: could not resolve the gh-authenticated operator (gh api user)" >&2
  echo "       ensure gh is authenticated, then re-run" >&2
  exit 1
fi

reviewed_sha="$(
  gh pr view "$pr" --repo "$repo" --json comments \
    | jq -r --arg operator "$operator" '
        .comments
        | sort_by(.createdAt) | reverse
        | map(select(.author.login == $operator))
        | map(select(.body | test("(?m)^## Codex reviewer \\(cross-vendor, read-only\\)$")))
        | map(.body | capture("(?m)^Reviewed-head: (?<sha>[0-9a-f]{40})$"; "g").sha)
        | map(select(. != null)) | .[0] // empty'
)"

if [ -z "$reviewed_sha" ]; then
  echo "error: no authenticated Codex review found on PR #$pr" >&2
  echo "       need a comment by the gh operator ($operator) carrying the codex-review.sh" >&2
  echo "       header and a 'Reviewed-head:' marker — a bare marker line is not trusted" >&2
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

# Confirm CI is green on the current head. `gh pr checks --json` tags each check with a
# `bucket` (pass / fail / pending / skipping / cancel). Green here means BOTH:
#   - AT LEAST ONE check is `pass` — something CI actually ran and passed; and
#   - NO check is fail/pending/cancel (skipping is tolerated alongside the pass).
# Requiring a real pass closes the all-skipped hole: when every reported check is
# `skipping` (e.g. jobs gated off by `if:` conditions), there is no fail/pending/cancel
# but nothing actually passed — that must NOT count as green. We still refuse on zero
# checks (CI must be the gate, so "no checks" is not "green").
# `gh pr checks` exits non-zero when checks aren't all passing (e.g. 8 = pending), so we
# capture its output without letting `set -e` abort, then judge the buckets ourselves.
checks_json="$(gh pr checks "$pr" --repo "$repo" --json bucket 2>/dev/null || true)"
if [ -z "$checks_json" ] || [ "$(jq 'length' <<<"$checks_json")" -eq 0 ]; then
  echo "error: no CI checks found on PR #$pr head ($current_head); refusing to merge" >&2
  echo "       CI is the hard gate — there must be at least one green check" >&2
  exit 1
fi
not_green="$(jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | length' <<<"$checks_json")"
if [ "$not_green" -ne 0 ]; then
  echo "error: CI not green on PR #$pr head ($current_head); refusing to merge" >&2
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

# All guards passed — merge, pinned to the reviewed SHA. `--match-head-commit` is a
# server-side belt-and-suspenders on top of the head==reviewed check above: GitHub itself
# refuses the merge if the head isn't exactly this commit, closing the tiny window between
# our check and the merge call.
echo "merging PR #$pr (reviewed head $reviewed_sha, CI green) ..."
gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$reviewed_sha"
