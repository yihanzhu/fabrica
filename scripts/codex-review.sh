#!/usr/bin/env bash
set -euo pipefail

# codex-review.sh — the Codex cross-vendor reviewer harness.
#
# Wraps Codex's built-in PR review (`codex exec review`) and posts the result to a
# GitHub PR verbatim, so a Claude session never edits or blends the review (that is
# what keeps the cross-vendor split honest). Run by Faber in-session after the coder
# opens a PR — this in-session harness is the only review path that exists today (see
# reviewer/codex-review.md; an autonomous Codex GitHub integration is a future option,
# not wired).
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
# fork-safely (`git fetch https://github.com/<owner>/<repo>.git refs/pull/<PR#>/head`,
# which brings the head commit into the object store even for fork PRs) and adds a
# DETACHED, throwaway git worktree at that exact commit. `codex exec review` runs inside
# that temp worktree against the qualified, freshly-fetched base, so it always sees the
# latest head vs. a current base. The operator's branch, index, working tree, and
# unpushed commits are provably untouched — "read-only" is literally true — so there is
# no clean-worktree guard, and the reviewer works even when the operator has local
# uncommitted work.
#
# Re-run safe: a `trap ... EXIT` removes the temp worktree (`git worktree remove
# --force`) and the temp output file even on failure, so this script never leaves a
# stale entry behind. We deliberately do NOT run a global `git worktree prune` (it is
# repo-wide and would drop metadata for unrelated operator worktrees, e.g. an unmounted
# one past gc.worktreePruneExpire — an operator-state mutation we must avoid). It is
# unneeded anyway: each run adds its worktree at a fresh mktemp path, so a stale entry
# from a hard-killed previous run never blocks `git worktree add`. No leftover
# worktrees, branches, or temp files.
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

# Preflight — fail honestly and early, BEFORE any fetch/worktree side-effect, so a
# first-time adopter gets an actionable "install X" pointer instead of an opaque
# mid-run `command not found`. Required tools (see QUICKSTART.md > Prerequisites):
#   gh    — GitHub CLI (authenticated)
#   git   — for the fork-safe fetch + temp worktree
#   codex — the OpenAI Codex CLI (signed in); runs the review
missing=()
for tool in gh git codex; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "error: missing required command(s): ${missing[*]}" >&2
  echo "       install and configure them, then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites (gh authenticated, Codex CLI signed in, git installed)" >&2
  exit 1
fi

# Validate the PR argument is a bare positive integer before any gh/git call uses it.
if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "error: PR# must be a number, got: $pr" >&2
  usage
  exit 1
fi

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

# Fetch the PR head fork-safely AND refresh the base, into THIS repo's object store,
# from the CANONICAL repo `gh` resolved (`$repo`), NOT the literal `origin` remote. In a
# fork workflow (`origin` = your fork, `upstream` = the canonical repo PRs target), `gh`
# reports the PR on the canonical repo; fetching from `origin` would fail (the PR ref
# doesn't exist on the fork) or silently grab a same-numbered, unrelated PR — reviewing
# the wrong diff or nothing. Pointing the fetch at `https://github.com/$repo.git` makes
# the source PROVABLY the repo `gh` resolved (`$repo` is its `nameWithOwner`), so the head
# and base always come from the repo the review is bound to.
#
# We use EXPLICIT, FULLY-QUALIFIED refspecs so both land at a known ref regardless of the
# clone's configured fetch refspecs. Both sources are qualified (`refs/pull/<PR#>/head`
# and `refs/heads/<base>`) so a same-named tag on the repo (e.g. a release branch and tag
# both named `v1.2.0`) can't make the fetch source resolve ambiguously or fail before
# Codex runs. The `refs/pull/<PR#>/head` source brings the PR head commit in even when
# the PR comes from a fork (a plain `git fetch` of a branch would not). We write BOTH into
# private local refs we control (under `refs/codex-review/`), never a remote-tracking ref
# tied to a remote name — that keeps the destinations independent of which remote `origin`
# happens to be, and avoids clobbering the operator's `origin/<base>` tracking ref with a
# commit fetched from a different URL. Read-only stays literally true: we force-update
# (the `+` prefix) ONLY these two refs we own and delete both before exit (the head right
# after its SHA is captured, the base in the cleanup trap once `--base` has read it);
# never a global `git fetch --force`. A global `--force` plus git's tag
# auto-following could force-update local `refs/tags/*` if the repo moved a tag reachable
# from the fetched commits — an operator-state mutation. `--no-tags` disables that
# auto-following, so this fetch touches nothing outside the two named destination refs.
pr_head_ref="refs/codex-review/pr-head"
base_dest_ref="refs/codex-review/base"
git fetch --no-tags "https://github.com/${repo}.git" \
  "+refs/pull/${pr}/head:${pr_head_ref}" \
  "+refs/heads/${base}:${base_dest_ref}"
pr_head="$(git rev-parse "$pr_head_ref")"
git update-ref -d "$pr_head_ref"
base_ref="$base_dest_ref"
# Record the EXACT base commit Codex reviews against. The review runs `--base
# refs/codex-review/base`, so the effective diff is `pr_head` vs. THIS commit. Capturing it
# lets a later actor (scripts/merge-pr.sh) refuse if the base advanced after the review — a
# moved base changes the merged integration even when the head is unchanged.
base_head="$(git rev-parse "$base_ref")"

# Allocate temp paths in the system temp dir (never inside the repo, so nothing here
# can be committed): a detached worktree dir and the review output file. Both get a
# fresh mktemp path each run, so a stale worktree entry from a hard-killed previous run
# never collides with — or blocks — the `git worktree add` below; that is why no global
# `git worktree prune` is needed (and we avoid one to not touch unrelated worktrees).
worktree="$(mktemp -d)"
tmp="$(mktemp)"

# Clean up on EVERY exit (success or failure): remove the temp worktree, the temp output
# file, and the private base ref we own (the head ref was already deleted above once its
# SHA was captured; the base ref must live until `codex exec review --base` reads it, so it
# is dropped here). `git worktree remove --force` drops the worktree even though it is at a
# detached head; the rm -rf fallback covers the case where it was never added.
cleanup() {
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  git update-ref -d "$base_dest_ref" 2>/dev/null || true
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
# against the qualified, freshly-fetched base ref (refs/codex-review/base).
review_cmd=(codex exec -C "$worktree" review -c sandbox_mode="read-only" --base "$base_ref" -o "$tmp")
if [ -n "$model" ]; then
  review_cmd+=(-m "$model")
fi
"${review_cmd[@]}"

# Post the review verbatim, with a short header marking it the cross-vendor reviewer.
# The header also records the EXACT commits Codex reviewed as parseable marker lines
# (`Reviewed-head: <full-sha>` and `Reviewed-base: <full-sha>`), so a later actor (e.g.
# scripts/merge-pr.sh) can bind a merge to the precise integration this review covered,
# and refuse if EITHER the head OR the base has since moved (both change the effective
# diff). The markers are part of Faber's header prefix — clearly separate from Codex's
# verbatim body below — so this stays read-only / comments-only / verbatim (no behavior
# change).
{
  echo "## Codex reviewer (cross-vendor, read-only)"
  echo
  echo "Reviewed-head: ${pr_head}"
  echo "Reviewed-base: ${base_head}"
  echo
  echo "_Posted verbatim by \`codex-review.sh\` (\`codex exec review --base ${base_ref}\` in an isolated temp worktree, sandbox forced read-only). Comments only — Codex never pushes, approves, or merges._"
  echo
  cat "$tmp"
} | gh pr comment "$pr" --repo "$repo" --body-file -
