#!/usr/bin/env bash
set -euo pipefail

# manager-review.sh — the Codex cross-vendor MANAGER reviewer harness.
#
# The mirror of codex-review.sh, one layer up: where codex-review.sh debates a *diff*
# with the PR as the message bus, this debates a *proposed issue* with the ISSUE as the
# message bus. It asks Codex whether a Faber-drafted issue is worth raising toward the
# current north star, and posts Codex's verdict to the issue verbatim, so a Claude
# session never edits or blends the manager-review (that is what keeps the cross-vendor
# split honest). Run by Faber in-session on a *proactive* (Faber-generated) issue before
# it gets the `ready` label (see reviewer/manager-review.md).
#
# The debate is over ROUNDS, on the issue: this script posts ONE Codex verdict comment;
# Faber reads it and either advances (consensus to proceed), refines (edit the issue +
# reply + re-run — another round), or drops (close with rationale). Consensus-only: the
# coder loop starts only when BOTH Faber and Codex agree. The reviewer is VETO-ONLY — it
# never labels `ready`, edits the issue, or merges; its only effect is the verdict comment.
#
# This script ONLY writes a single ISSUE comment. It never edits the issue, applies or
# removes labels, pushes, or merges. Read-only is FORCED via `-c sandbox_mode="read-only"`
# so the review can't inherit a writable sandbox from the operator's Codex config; we
# deliberately do NOT pass --dangerously-bypass-* . We use -c rather than
# --ignore-user-config on purpose: that flag would also drop the operator's model/effort
# defaults, which we want to keep.
#
# It operates on the CURRENT repo: gh infers <owner>/<repo> from the cwd's git remote, and
# the comment is posted to that repo's issue. Run it from within the target repo's clone —
# there is deliberately no <owner>/<repo> arg, so the script can't read one repo's issue
# and post to another's. We also `unset GH_REPO` and pass an explicit, cwd-derived
# `--repo` to every gh call, so a GH_REPO in the environment can't redirect the comment to
# a different repo's issue.
#
# Isolated review — the operator's checkout is never touched. The manager-review forms a
# judgment about the issue grounded in the repo, so Codex needs to READ the code; but the
# read-only sandbox only blocks WRITES, it does not stop Codex from reading the operator's
# live worktree — untracked/ignored files (`.env`, secrets, local WIP) or uncommitted state
# that should not ground the judgment. So, mirroring codex-review.sh, we add a DETACHED,
# throwaway git worktree at the current HEAD and run `codex exec -C <worktree>` there. Codex
# then sees exactly the tracked content at HEAD — what should ground the issue review —
# never untracked/ignored files or dirty state, and the whole repo regardless of the cwd
# (subdir vs. root). The operator's branch, index, and working tree are provably untouched.
#
# Re-run safe: a `trap ... EXIT` removes the temp worktree (`git worktree remove --force`)
# and the temp output file even on failure, so this script never leaves a stale entry behind.
# We deliberately do NOT run a global `git worktree prune` (it is repo-wide and would drop
# metadata for unrelated operator worktrees) — it is unneeded anyway: each run adds its
# worktree at a fresh mktemp path, so a stale entry from a hard-killed previous run never
# blocks `git worktree add`. No leftover worktrees or temp files. Re-running posts a fresh
# verdict comment (each round is its own comment) — the issue thread is the durable record.
#
# Usage: scripts/manager-review.sh [-m <model>] <issue#>
#   (or, with fabrica/scripts on PATH: manager-review.sh [-m <model>] <issue#>)

usage() {
  echo "usage: $0 [-m <model>] <issue#>" >&2
  echo "  run from within the target repo's clone; debates the ISSUE on the CURRENT repo" >&2
  echo "  runs 'codex exec' read-only with the manager-reviewer prompt + north star + the" >&2
  echo "  issue, and posts Codex's PROCEED/REFINE/DROP verdict as an issue comment, verbatim" >&2
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

issue="$1"

# Preflight — fail honestly and early, BEFORE any gh/git/codex side-effect, so a first-time
# adopter gets an actionable "install X" pointer instead of an opaque mid-run `command not
# found`. Required tools (see QUICKSTART.md > Prerequisites):
#   gh    — GitHub CLI (authenticated); reads the issue and posts the verdict comment
#   git   — for the detached temp worktree at HEAD
#   codex — the OpenAI Codex CLI (signed in); forms the manager-review
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

# Validate the issue argument is a bare positive integer before any gh call uses it.
if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
  echo "error: issue# must be a number, got: $issue" >&2
  usage
  exit 1
fi

# The north star lives in NORTH_STAR.md in the fabrica CONTROL-PLANE repo, NOT in each
# target repo (target repos only get the labels from setup-target-repo.sh; they never get a
# NORTH_STAR.md). The script also lives only in the control plane, so resolve NORTH_STAR.md
# from the SCRIPT'S OWN location — follow symlinks, then dirname/.. — the same derivation
# install.sh/doctor.sh use, so the script reads the control plane's north star regardless of
# which target repo's cwd it is invoked from. If the file is missing, fail with an actionable
# pointer rather than debating against an empty goal.
script_path="$0"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
control_plane_root="$(cd "$(dirname "$script_path")/.." && pwd -P)"
north_star_file="${control_plane_root}/NORTH_STAR.md"
if [ ! -f "$north_star_file" ]; then
  echo "error: NORTH_STAR.md not found in the control-plane repo (${north_star_file})" >&2
  echo "       the manager-review debates the issue against the current north star;" >&2
  echo "       it lives in the fabrica control-plane repo, alongside this script;" >&2
  echo "       see reviewer/manager-review.md > NORTH_STAR.md" >&2
  exit 1
fi
north_star="$(cat "$north_star_file")"

# Pin gh to the cwd's checkout, not whatever GH_REPO points at. If GH_REPO is set in the
# environment, every `gh repo view` / `gh issue view/comment` would target THAT repo
# instead of the cwd's git remote — so the script could read the cwd's NORTH_STAR.md but
# post the verdict to an issue in a DIFFERENT repo. Unset it (so gh falls back to the
# cwd's remote) AND derive the repo from the cwd to pass an explicit --repo to each gh
# call (belt-and-suspenders).
unset GH_REPO

# Guard: must run from within a git repo that gh recognizes (has a remote gh can resolve
# to <owner>/<repo>). This binds the verdict comment to the cwd's repo, so the cwd MUST be
# the target repo's clone.
if ! repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [ -z "$repo" ]; then
  echo "error: not inside a git repo with a gh-recognized remote" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Resolve the current commit (HEAD) — this is the tracked content Codex grounds its
# judgment in, materialized in a clean detached worktree below. The usage allows running
# from anywhere inside the clone, and a worktree at HEAD always contains the WHOLE repo's
# tracked tree, so the review covers the full repo regardless of cwd (subdir vs. root).
if ! head_commit="$(git rev-parse HEAD 2>/dev/null)" || [ -z "$head_commit" ]; then
  echo "error: cannot resolve HEAD of the current repo" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# Pull the issue title + body + the comment thread — the proposal Codex debates, PLUS the
# prior debate. On a REFINE rerun, Faber edits the issue and replies in an issue comment
# (issue-as-bus), so the comment thread carries the prior Codex verdicts and Faber's
# refinement rationale; feeding it in means the next Codex run sees the prior debate and
# does not just repeat the same objection or miss why the issue was refined. Fail early if
# the issue can't be read (wrong number, no access) before invoking codex. gh's `-q` runs
# its bundled jq, so we extract each field with gh's own jq — no external jq dependency. The
# title/body fetch also serves as the access check; the comments are rendered into a readable
# "@author (createdAt): body" thread, oldest first (gh returns them in chronological order).
if ! issue_title="$(gh issue view "$issue" --repo "$repo" --json title -q .title 2>/dev/null)"; then
  echo "error: cannot read issue #${issue} on ${repo} via gh" >&2
  echo "       confirm the issue exists and you have access, then re-run" >&2
  exit 1
fi
issue_body="$(gh issue view "$issue" --repo "$repo" --json body -q .body)"
issue_comments="$(gh issue view "$issue" --repo "$repo" --json comments \
  -q 'if (.comments | length) == 0 then "(no comments yet)" else (.comments[] | "@\(.author.login) (\(.createdAt)):\n\(.body)\n") end')"

# Allocate temp paths in the system temp dir (never inside the repo, so nothing here can be
# committed): a detached worktree dir and the Codex output file. Both get a fresh mktemp path
# each run, so a stale worktree entry from a hard-killed previous run never collides with — or
# blocks — the `git worktree add` below; that is why no global `git worktree prune` is needed
# (and we avoid one so unrelated operator worktrees are never touched).
worktree="$(mktemp -d)"
tmp="$(mktemp)"

# Clean up on EVERY exit (success or failure): remove the temp worktree and the temp output
# file. `git worktree remove --force` drops the worktree even at a detached head; the rm -rf
# fallback covers the case where it was never added.
cleanup() {
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  rm -f "$tmp"
}
trap cleanup EXIT

# Add a DETACHED, throwaway worktree at the current HEAD, isolated from the operator's
# checkout. Codex reviews HERE — so it sees exactly the tracked content at HEAD (the right
# thing to ground the issue review), never untracked/ignored files (`.env`, secrets, WIP) or
# uncommitted state, and never mutates the operator's branch / index / working tree.
git worktree add --detach "$worktree" "$head_commit"

# Build the manager-reviewer prompt: the role + the current north star + the issue under
# debate + an instruction to read the repo to ground the judgment, asking for a structured
# PROCEED / REFINE / DROP verdict with reasoning and any gap Faber missed. This is a
# hand-written prompt (unlike codex-review.sh, which uses Codex's built-in review): there is
# no built-in "should this issue exist?" review, and the whole point is Codex's own
# independent judgment on the proposal vs. the north star — see reviewer/manager-review.md.
#
# The role text is a quoted heredoc (delimiter 'PROMPT_TMPL') so NOTHING in it is expanded
# or re-parsed — issue/north-star content (which can contain backticks, $, and parens) is
# substituted afterward via printf %s args, never evaluated by the shell. This is why the
# untrusted issue body can't break parsing or trigger command substitution.
# Read the role template into a variable via a QUOTED heredoc (delimiter 'PROMPT_TMPL') so
# nothing in it is expanded or re-parsed. We use `read -r -d ''` rather than a
# `$(cat <<…)` command substitution on purpose: a heredoc wrapped in `$(...)` whose body
# contains parentheses can fail bash's parser ("unexpected EOF") — `read` has no such issue.
# `read` returns non-zero at EOF (the heredoc has no trailing NUL), so guard with `|| true`.
prompt_tmpl=""
IFS= read -r -d '' prompt_tmpl <<'PROMPT_TMPL' || true
You are the cross-vendor MANAGER reviewer for an autonomous coding team. Faber (a Claude
manager) has DRAFTED the GitHub issue below as a *proactive* proposal toward the team's
current north star. Your job is to debate whether this issue is worth raising NOW — not to
review code, and not to rubber-stamp it. You are VETO-ONLY: you never approve, label, edit
the issue, or merge anything; you only give a verdict that Faber weighs. The team proceeds
ONLY on consensus (you and Faber both agree), and DEFAULT-DROPS on no consensus, so do not
invent busywork: if the issue does not clearly serve the north star, say so.

== CURRENT NORTH STAR (from NORTH_STAR.md) ==
%s

== PROPOSED ISSUE #%s ==
Title: %s

%s

== ISSUE COMMENT THREAD (the debate so far, oldest first) ==
On a rerun this carries any prior verdicts of yours and Faber's refinement replies (the
issue is the message bus). Read it: do not just repeat a prior objection if Faber already
addressed it, and weigh the refinement rationale. On a first round it may be empty.

%s

== YOUR TASK ==
Read the repository (read-only) to ground your judgment in what actually exists — do not
judge on the issue text alone. Then respond with EXACTLY this structure:

VERDICT: one of PROCEED / REFINE / DROP
- PROCEED — this clearly serves the north star and is well-scoped; the team should build it.
- REFINE — the intent is north-star-relevant but the issue needs changes first (scope,
  acceptance criteria, sequencing). Say specifically what to change.
- DROP — this does not clearly serve the current north star, duplicates existing work, or
  is premature; the team should not build it now. (Default to this on genuine doubt.)

REASONING: why, grounded in the north star and the repo as it stands.

GAP FABER MISSED: anything Faber overlooked — a risk, a dependency, a simpler path, a
conflict with existing files, or a reason this is already covered. If none, say "none".
PROMPT_TMPL

# Substitute the issue/north-star content into the template as %s ARGS (never as the format
# string), so untrusted issue text can't act as a printf format or be evaluated by the shell.
# shellcheck disable=SC2059  # prompt_tmpl is our own trusted template; values are %s args.
prompt="$(printf "$prompt_tmpl" "$north_star" "$issue" "$issue_title" "$issue_body" "$issue_comments")"

# Run Codex read-only. Force the read-only sandbox via -c so the review cannot inherit a
# writable sandbox from the operator's Codex config; we deliberately do NOT pass
# --dangerously-bypass-* , and avoid --ignore-user-config so the operator's model/effort
# defaults still apply. `-o <tmp>` captures Codex's clean final message off the noisy exec
# trace. `-C "$worktree"` pins Codex to the clean detached worktree at HEAD so it reads the
# whole repo's tracked content (never the operator's untracked/ignored files or dirty state)
# read-only to ground its judgment, regardless of which subdirectory the script was run from.
#
# The prompt is fed over STDIN (the trailing `-` positional, which `codex exec` reads as
# "prompt from stdin"), NOT as an argv argument. The prompt embeds the issue body + the full
# comment thread + the north star, which can be large (GitHub allows a 65k issue body plus
# many comments) — passing that on the command line risks `E2BIG` once the thread grows, and
# on a shared machine it would also expose the issue/north-star text in `ps`/process listings
# while Codex runs. stdin avoids both. All flags stay BEFORE the `-` (flags then positional).
review_cmd=(codex exec -C "$worktree" -c sandbox_mode="read-only" -o "$tmp")
if [ -n "$model" ]; then
  review_cmd+=(-m "$model")
fi
printf '%s' "$prompt" | "${review_cmd[@]}" -

# Compose the issue comment: a short header marking it the cross-vendor manager-reviewer,
# then Codex's verdict VERBATIM. The header is Faber's prefix — clearly separate from
# Codex's verbatim body — so this stays read-only / comments-only / verbatim (no Claude
# rewriting). Build it into a second temp file so we can both echo it to stdout (the
# operator sees the verdict in-session) and post it as the issue comment.
comment="$(mktemp)"
# Re-arm the trap to also remove this second temp file. We re-`git worktree remove` the
# worktree here too (replacing, not appending to, the EXIT trap) so the worktree cleanup is
# not lost; it is idempotent / harmless if the worktree is already gone.
trap 'git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"; rm -f "$tmp" "$comment"' EXIT
{
  echo "## Codex manager-reviewer (cross-vendor, read-only)"
  echo
  echo "_Posted verbatim by \`manager-review.sh\` (\`codex exec\`, sandbox forced read-only, debating issue #${issue} against the current north star). Comments only — veto-only: Codex never labels \`ready\`, edits the issue, or merges. Proceed only on consensus._"
  echo
  cat "$tmp"
} >"$comment"

# Echo to stdout, then post the SAME content as the issue comment (the durable record).
cat "$comment"
gh issue comment "$issue" --repo "$repo" --body-file "$comment"
