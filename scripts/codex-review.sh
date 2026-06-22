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
# remote, and the review runs against that repo's PR. Run it from within the target
# repo's clone — there is deliberately no <owner>/<repo> arg, so the script can't
# review one repo's diff and post to another's PR. We also `unset GH_REPO` and pass
# an explicit, cwd-derived `--repo` to every gh call, so a GH_REPO in the environment
# can't redirect the review to a different repo's PR.
#
# Isolated review — the operator's checkout is never touched. Instead of checking the
# PR out into the operator's own working tree (which, even with a clean guard, risks
# discarding unpushed commits via a force reset), the script fetches the PR head
# fork-safely (`git fetch origin pull/<PR#>/head`, which brings the head commit into
# the object store even for fork PRs) and adds a DETACHED, throwaway git worktree at
# that exact commit. `codex exec review` runs inside that temp worktree against the
# qualified, freshly-fetched `origin/<base>`, so it always sees the latest head vs. a
# current base. The operator's branch, index, working tree, and unpushed commits are
# provably untouched — "read-only" is literally true — so there is no clean-worktree
# guard, and the reviewer works even when the operator has local uncommitted work.
#
# Re-run safe: a `trap ... EXIT` removes the temp worktree (`git worktree remove
# --force`) and the temp output file even on failure; `git worktree prune` first
# clears a stale worktree left by a hard-killed previous run. No leftover worktrees,
# branches, or temp files.
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
# in the environment, every `gh repo view` / `gh pr view/comment` would target THAT
# repo instead of the cwd's git remote — so the script could post a review of the cwd
# checkout to a PR in a different repo. Unset it (so gh falls back to the cwd's remote)
# AND derive the repo from the cwd to pass an explicit --repo to each gh call
# (belt-and-suspenders). codex still reviews the cwd's repo via the temp worktree below.
unset GH_REPO

# Guard: must run from within a git repo that gh recognizes (has a remote gh can
# resolve to <owner>/<repo>). This is what removes the footgun — the review is bound
# to the cwd's repo, so the cwd MUST be the target repo's clone.
if ! repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [ -z "$repo" ]; then
  echo "error: not inside a git repo with a gh-recognized remote" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Derive the PR's base branch. Everything operates on the current repo (gh infers
# <owner>/<repo> from the cwd).
base="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName)"

# Fetch the PR head fork-safely AND refresh the base, into THIS repo's object store.
# The `pull/<PR#>/head` refspec brings the PR head commit in even when the PR comes
# from a fork (a plain `git fetch origin` would not), and refreshing the base keeps
# origin/<base> current. FETCH_HEAD then points at the PR head commit (the last ref
# fetched), which we resolve and add the worktree at.
git fetch origin "pull/${pr}/head" "$base"
pr_head="$(git rev-parse FETCH_HEAD)"
base_ref="origin/${base}"

# Prune any stale worktree a hard-killed previous run may have left, so re-runs are
# safe, then allocate temp paths in the system temp dir (never inside the repo, so
# nothing here can be committed): a detached worktree dir and the review output file.
git worktree prune
worktree="$(mktemp -d)"
tmp="$(mktemp)"

# Clean up on EVERY exit (success or failure): remove the temp worktree and the temp
# output file. `git worktree remove --force` drops the worktree even though it is at a
# detached head; the rm -rf fallback covers the case where it was never added.
cleanup() {
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  rm -f "$tmp"
}
trap cleanup EXIT

# Add a DETACHED, throwaway worktree at the PR head, isolated from the operator's
# checkout. Reviewing here means the operator's branch / index / working tree / unpushed
# commits are never touched — that is what makes the reviewer truly read-only.
git worktree add --detach "$worktree" "$pr_head"

# Force read-only via -c so the review cannot inherit a writable sandbox from the
# operator's Codex config. `codex exec review` has no -s/--sandbox flag (only the
# parent `codex exec` does), so the config override is the way to pin it; we avoid
# --ignore-user-config so the operator's model/effort defaults still apply. `-C` is a
# flag on the parent `codex exec` (not on the `review` subcommand), so it must come
# before `review`; it points codex at the temp worktree to review the PR head diff
# against the qualified remote base origin/<base>.
review_cmd=(codex exec -C "$worktree" review -c sandbox_mode="read-only" --base "$base_ref" -o "$tmp")
if [ -n "$model" ]; then
  review_cmd+=(-m "$model")
fi
"${review_cmd[@]}"

# Post the review verbatim, with a short header marking it the cross-vendor reviewer.
{
  echo "## Codex reviewer (cross-vendor, read-only)"
  echo
  echo "_Posted verbatim by \`codex-review.sh\` (\`codex exec review --base ${base_ref}\` in an isolated temp worktree, sandbox forced read-only). Comments only — Codex never pushes, approves, or merges._"
  echo
  cat "$tmp"
} | gh pr comment "$pr" --repo "$repo" --body-file -
