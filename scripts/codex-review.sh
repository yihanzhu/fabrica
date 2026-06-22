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
# merges. `codex exec review` runs read-only by default (sandbox: read-only,
# approval: never) — we deliberately do NOT pass --dangerously-bypass-* .
#
# It operates on the CURRENT repo: gh infers <owner>/<repo> from the cwd's git
# remote, and `codex exec review` runs against this same checkout. Run it from
# within the target repo's clone — there is deliberately no <owner>/<repo> arg,
# so the script can't review one repo's diff and post to another's PR.
#
# Usage: scripts/codex-review.sh [-m <model>] <PR#>

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

# Guard: must run from within a git repo that gh recognizes (has a remote gh can
# resolve to <owner>/<repo>). This is what removes the footgun — codex reviews the
# cwd's checkout, so the cwd MUST be the target repo's clone.
if ! gh repo view --json nameWithOwner >/dev/null 2>&1; then
  echo "error: not inside a git repo with a gh-recognized remote" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Derive the PR's base branch and check out the PR so codex reviews the right diff.
# Everything operates on the current repo (gh infers <owner>/<repo> from the cwd).
base="$(gh pr view "$pr" --json baseRefName -q .baseRefName)"
gh pr checkout "$pr"

# Capture only Codex's final review to a transient temp file (avoids the noisy exec
# trace on stdout). trap removes it even if codex or gh fails mid-run; it lives in
# the system temp dir, never inside the repo, so it can't be committed.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

review_cmd=(codex exec review --base "$base" -o "$tmp")
if [ -n "$model" ]; then
  review_cmd+=(-m "$model")
fi
"${review_cmd[@]}"

# Post the review verbatim, with a short header marking it the cross-vendor reviewer.
{
  echo "## Codex reviewer (cross-vendor, read-only)"
  echo
  echo "_Posted verbatim by \`scripts/codex-review.sh\` (\`codex exec review --base ${base}\`). Comments only — Codex never pushes, approves, or merges._"
  echo
  cat "$tmp"
} | gh pr comment "$pr" --body-file -
