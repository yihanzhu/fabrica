#!/usr/bin/env bash
set -euo pipefail

# codex-review.sh — the Codex cross-vendor reviewer harness.
#
# Wraps Codex's built-in PR review (`codex exec review`) and posts the result to a
# GitHub PR verbatim, so a Claude session never edits or blends the review (that is
# what keeps the cross-vendor split honest). Run by Faber in-session after the coder
# opens a PR; the autonomous upgrade is the Codex GitHub integration (see
# reviewer/codex-review.md).
#
# This script ONLY writes a single PR comment. It never edits files, pushes, or
# merges. Read-only is FORCED via `-c sandbox_mode="read-only"` so the review
# can't inherit a writable sandbox from the operator's Codex config (approval is
# already `never` for review); we deliberately do NOT pass --dangerously-bypass-* .
# We use -c rather than --ignore-user-config on purpose: that flag would also drop
# the operator's model/effort defaults, which we want to keep.
#
# It operates on the CURRENT repo: gh infers <owner>/<repo> from the cwd's git
# remote, and `codex exec review` runs against this same checkout. Run it from
# within the target repo's clone — there is deliberately no <owner>/<repo> arg,
# so the script can't review one repo's diff and post to another's PR. We also
# `unset GH_REPO` and pass an explicit, cwd-derived `--repo` to every gh call, so
# a GH_REPO in the environment can't redirect the review to a different repo's PR.
#
# Re-run safe: it fetches origin and checks the PR out with --force, then reviews
# against the qualified base ref (origin/<base>), so a second pass after a coder
# pushes fixes always sees the latest head against a current base, never stale refs.
# A clean-worktree guard runs before the force checkout so the read-only reviewer
# never discards local-only commits or uncommitted work via `gh pr checkout --force`.
#
# Usage: scripts/codex-review.sh [-m <model>] <PR#>
#   (or, with fabrica/scripts on PATH: codex-review.sh [-m <model>] <PR#>)

usage() {
  echo "usage: $0 [-m <model>] <PR#>" >&2
  echo "  run from within the target repo's clone; reviews the PR on the CURRENT repo" >&2
  echo "  runs 'codex exec review' on the PR and posts Codex's review as a PR comment, verbatim" >&2
  echo "  -m <model>  optional Codex model override (defaults to Codex's own default)" >&2
}

model=""
while getopts ":m:h" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "error: -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    \?) echo "error: unknown option -$OPTARG" >&2; usage; exit 1 ;;
  esac
done
shift "$((OPTIND - 1))"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

pr="$1"

# Pin gh to the cwd's checkout, not whatever GH_REPO points at. If GH_REPO is set
# in the environment, every `gh repo view` / `gh pr view/checkout/comment` would
# target THAT repo instead of the cwd's git remote — so the script could post a
# review of the cwd checkout to a PR in a different repo. Unset it (so gh falls
# back to the cwd's remote) AND derive the repo from the cwd to pass an explicit
# --repo to each gh call (belt-and-suspenders). codex still reviews the cwd checkout.
unset GH_REPO

# Guard: must run from within a git repo that gh recognizes (has a remote gh can
# resolve to <owner>/<repo>). This is what removes the footgun — codex reviews the
# cwd's checkout, so the cwd MUST be the target repo's clone.
if ! repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [ -z "$repo" ]; then
  echo "error: not inside a git repo with a gh-recognized remote" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Derive the PR's base branch and check out the PR so codex reviews the right diff.
# Everything operates on the current repo (gh infers <owner>/<repo> from the cwd).
#
# Re-run safety: a previous pass may have left a stale local PR branch behind, so
# `gh pr checkout` without --force would NOT reset it to the latest PR head. We
# fetch origin first (refreshing both head and base), check out with --force to
# reset the PR branch to the current head, and review against the QUALIFIED remote
# base (origin/<base>) so the base is current too — never a stale local branch.
base="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName)"
git fetch origin

# Clean-worktree guard: `gh pr checkout --force` resets an existing local PR branch
# to the PR head, which would silently discard the operator's local-only commits or
# uncommitted changes. A reviewer documented as read-only / comments-only must never
# destroy work, so abort if the worktree is dirty rather than force-checking-out over it.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: worktree has uncommitted changes; commit or stash before running the reviewer" >&2
  echo "       (the force checkout below would otherwise discard them)" >&2
  exit 1
fi
gh pr checkout "$pr" --repo "$repo" --force
base_ref="origin/${base}"

# Capture only Codex's final review to a transient temp file (avoids the noisy exec
# trace on stdout). trap removes it even if codex or gh fails mid-run; it lives in
# the system temp dir, never inside the repo, so it can't be committed.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Force read-only via -c so the review cannot inherit a writable sandbox from the
# operator's Codex config. `codex exec review` has no -s/--sandbox flag (only the
# parent `codex exec` does), so the config override is the way to pin it; we avoid
# --ignore-user-config so the operator's model/effort defaults still apply.
review_cmd=(codex exec review -c sandbox_mode="read-only" --base "$base_ref" -o "$tmp")
if [ -n "$model" ]; then
  review_cmd+=(-m "$model")
fi
"${review_cmd[@]}"

# Post the review verbatim, with a short header marking it the cross-vendor reviewer.
{
  echo "## Codex reviewer (cross-vendor, read-only)"
  echo
  echo "_Posted verbatim by \`codex-review.sh\` (\`codex exec review --base ${base_ref}\`, sandbox forced read-only). Comments only — Codex never pushes, approves, or merges._"
  echo
  cat "$tmp"
} | gh pr comment "$pr" --repo "$repo" --body-file -
