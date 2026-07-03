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
# NORTH-STAR SOURCE (#98a) — the debate is against the TARGET's own north star, resolved via
# scripts/lib/north-star.sh from the cwd's checkout: the target's committed
# `.fabrica/north-star.md`, or (on a Fabrica-self run) the control-plane root NORTH_STAR.md.
# The content is read COMMITTED at the SAME commit the review worktree is pinned to (never a
# free-floating later HEAD): the north star is an autonomy-authorization artifact, so an
# uncommitted local edit must not silently redirect the gate. A target with no committed star
# (UNSET), or a LOCAL star still carrying the shipped-default placeholder marker, FAILs before
# any Codex verdict. This gate source is IDENTICAL to Faber's approval source (persona +
# /faber) — they flip together so the gate never reads a source the operator did not approve.
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

# The north star is resolved FOR THE TARGET this run operates on, via the shared resolver
# (scripts/lib/north-star.sh). Historically this script read the control-plane NORTH_STAR.md
# directly; #98a flips it to the per-target star so the consensus gate debates against the
# TARGET's own approved goal (and, for a Fabrica-self run, still against Fabrica's own root
# NORTH_STAR.md). Locate the resolver from the SCRIPT'S OWN location — follow symlinks, then
# dirname/.. — so it is found regardless of which target repo's cwd this is invoked from; the
# actual content read is deferred until after HEAD is pinned (below), because the gate MUST
# read COMMITTED target state at a single captured commit, never a free-floating later HEAD.
script_path="$0"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
control_plane_root="$(cd "$(dirname "$script_path")/.." && pwd -P)"
ns_lib="${control_plane_root}/scripts/lib/north-star.sh"
if [ ! -f "$ns_lib" ]; then
  echo "error: north-star resolver not found (${ns_lib})" >&2
  echo "       it ships in the fabrica control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/north-star.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/north-star.sh
. "$ns_lib"

# Pin gh to the cwd's checkout, not whatever GH_REPO points at. If GH_REPO is set in the
# environment, every `gh repo view` / `gh issue view/comment` would target THAT repo
# instead of the cwd's git remote — so the script could debate the cwd target's north star
# but post the verdict to an issue in a DIFFERENT repo. Unset it (so gh falls back to the
# cwd's remote) AND derive the repo from the cwd to pass an explicit --repo to each gh
# call (belt-and-suspenders). (The resolver's own gh calls clear GH_REPO per-invocation too.)
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

# NESTED/EMBEDDED-REPO guard (#98a, confused-deputy) — refuse to authorize off a north star that
# lives in a SEPARATE git repo NESTED inside ANOTHER git work tree. Running the gate from inside
# an untracked/embedded git repo (with its own committed .fabrica/north-star.md) makes `git
# rev-parse HEAD` / ns_resolve resolve to the NESTED repo, so the gate would authorize against a
# star that was never committed to the REAL (outer) target — a confused deputy. The operator must
# run from the target's OWN top-level clone.
#
# Detection: is the PARENT directory of this repo's top-level itself inside a git work tree, AND
# is that outer work tree a DIFFERENT repository? `--is-inside-work-tree` alone would also flag a
# legitimate LINKED WORKTREE (git worktrees live under another repo's tree yet ARE the same repo),
# so we additionally require the two to have DIFFERENT `--git-common-dir`s — a linked worktree
# SHARES its parent repo's common dir, while a genuinely separate embedded clone has its own. We
# compare the common dirs canonicalized to absolute paths (`cd … && pwd -P`) so a relative
# `--git-common-dir` (git prints `.git` / `../.git` depending on cwd) and any `/var`→`/private/var`
# symlink skew never cause a false compare. `--show-superproject-working-tree` would catch only a
# registered submodule, not an arbitrary untracked nested clone; this probe catches BOTH. Every
# git call is guarded (`|| true` / `2>/dev/null`) so the not-nested case never aborts this `set -e`
# script — the emptiness/inequality checks decide.
gate_toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$gate_toplevel" ]; then
  gate_parent="$(dirname "$gate_toplevel")"
  if [ "$gate_parent" != "$gate_toplevel" ] \
     && git -C "$gate_parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Canonical absolute common dirs for the inner repo (cwd) and the outer parent's repo. A
    # linked worktree shares the inner==outer common dir (allowed); a separate embedded clone
    # differs (the confused-deputy case → FAIL).
    inner_common="$( cd "$gate_toplevel" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P )" || true
    outer_common="$( cd "$gate_parent" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P )" || true
    if [ -n "$inner_common" ] && [ -n "$outer_common" ] && [ "$inner_common" != "$outer_common" ]; then
      outer_toplevel="$(git -C "$gate_parent" rev-parse --show-toplevel 2>/dev/null || true)"
      echo "error: this checkout ($gate_toplevel) is a SEPARATE git repo NESTED inside another" >&2
      echo "       git work tree${outer_toplevel:+ ($outer_toplevel)} — the manager-debate gate refuses to authorize off a" >&2
      echo "       north star in a nested/embedded checkout (its HEAD/.fabrica/north-star.md is not" >&2
      echo "       the real target's). Run this from the target's OWN top-level clone, not a" >&2
      echo "       nested/embedded checkout." >&2
      exit 1
    fi
  fi
fi

# Resolve the north star FOR THE TARGET, then read its COMMITTED content pinned to the SAME
# commit ($head_commit) the review operates on — NEVER a free-floating later HEAD re-lookup
# (debate GAP, #98a). The north star is an autonomy-authorization artifact: an unreviewed
# LOCAL worktree edit to .fabrica/north-star.md must NOT silently redirect the proactive gate,
# so a star that exists ONLY as an uncommitted working-tree edit does NOT authorize — while a
# star COMMITTED at $head_commit STILL authorizes even if the working-tree copy is later
# deleted or modified. We read `git show "$head_commit:<path>"`, which resolves <path> relative
# to the repo ROOT regardless of the cwd (subdir vs. root) and reads only committed content, so
# the gate's goal matches the clean detached worktree Codex reviews at the same commit and is
# immune to the dirty working tree.
#
# ns_resolve tells us WHICH source applies via its IDENTITY logic — is this a Fabrica-self run
# (root NORTH_STAR.md) or a normal target (.fabrica/north-star.md)? We do NOT use its
# LOCAL-vs-UNSET result to gate authorization, because ns_resolve stats the WORKING-TREE file,
# so a committed-but-worktree-deleted star would read UNSET there. Instead, for a normal target
# the authoritative authorize test is whether .fabrica/north-star.md exists AT $head_commit.
ns_result="$(ns_resolve "$PWD" || true)"
ns_kind="${ns_result%% *}"
north_star=""
if [ "$ns_kind" = "FABRICA_SELF" ]; then
  # Fabrica-self run: the control-plane root NORTH_STAR.md is Fabrica's own real approved goal
  # (it legitimately carries the shipped-default marker — this branch is EXEMPT from the
  # placeholder-FAIL). cwd IS the control-plane checkout, so read the root star COMMITTED at the
  # same $head_commit for the same committed-state guarantee.
  #
  # AUTHORIZATION lives HERE (round-3 [P2]): ns_resolve classifies FABRICA_SELF by git-structural
  # identity (shared git common-dir, so a linked worktree of the control plane counts too; a
  # top-level path match is also accepted) UNCONDITIONALLY — it does NOT check whether NORTH_STAR.md
  # is committed — so this branch is the
  # authorization gate. It must require a COMMITTED root star and FAIL cleanly if there is none: a
  # missing committed root FAILs, it does NOT fall back to `.fabrica/north-star.md` (that fallback
  # would let a stray committed `.fabrica` star mis-steer Fabrica-self). Do the committed read
  # FIRST so an ABSENT root gives the accurate "not committed at HEAD" message — not the symlink
  # message. `if ! …="$(git show …)"` (a condition context) never trips `set -e`: an absent path
  # makes `git show` exit non-zero → the FAIL branch runs cleanly.
  if ! north_star="$(git show "${head_commit}:NORTH_STAR.md" 2>/dev/null)" || [ -z "$north_star" ]; then
    echo "error: NORTH_STAR.md is not committed at HEAD (${head_commit}) in the control plane" >&2
    echo "       ns_resolve classified this run as Fabrica-self by git-structural identity; the manager-debate" >&2
    echo "       gate reads COMMITTED state and does NOT fall back to .fabrica/north-star.md. Commit" >&2
    echo "       the root north star (or restore it), then re-run" >&2
    exit 1
  fi
  # SYMLINK guard (round-2 FIX 4): reject a committed NORTH_STAR.md stored as a SYMLINK. `git show
  # <commit>:NORTH_STAR.md` on a symlink returns the link TARGET-PATH string (which the `[ -n ]`
  # above accepts), not file content — the gate would then authorize off a meaningless string and
  # diverge from the real file Codex reviews. Assert the committed entry is a regular blob
  # (100644/100755). Checked AFTER the committed read so an ABSENT root FAILs with the accurate
  # "not committed" message above rather than this symlink message.
  if ! ns_committed_is_regular_file "$PWD" "$head_commit" "NORTH_STAR.md"; then
    echo "error: the control plane's committed NORTH_STAR.md at HEAD (${head_commit}) is a SYMLINK —" >&2
    echo "       the committed north star must be a regular file, not a symlink (a symlink makes the" >&2
    echo "       gate read the link's target-path string, not the star's content). Replace it with a" >&2
    echo "       regular file, commit it, and re-run" >&2
    exit 1
  fi
elif north_star="$(git show "${head_commit}:.fabrica/north-star.md" 2>/dev/null)" && [ -n "$north_star" ]; then
  # A normal target with .fabrica/north-star.md COMMITTED at $head_commit → LOCAL. This is the
  # authorize test (committed existence), independent of the working tree: a committed star
  # authorizes even if the worktree copy was deleted/modified, and a worktree-only edit that is
  # NOT committed here falls through to the UNSET FAIL below (it does not reach this branch).
  #
  # SYMLINK guard (round-2 FIX 4) — BEFORE the marker check: reject a committed .fabrica/north-star.md
  # stored as a SYMLINK. `git show <commit>:.fabrica/north-star.md` on a symlink returns the link
  # TARGET-PATH string (which `[ -n ]` above accepts), so without this guard the gate would run the
  # marker check against a path string and could AUTHORIZE off it, diverging from the real file Codex
  # reviews. Assert the committed entry is a regular blob (100644/100755) first.
  if ! ns_committed_is_regular_file "$PWD" "$head_commit" ".fabrica/north-star.md"; then
    echo "error: ${repo}'s committed .fabrica/north-star.md at HEAD (${head_commit}) is a SYMLINK —" >&2
    echo "       the committed north star must be a regular file, not a symlink (a symlink makes the" >&2
    echo "       gate read the link's target-path string, not the star's content). Replace it with a" >&2
    echo "       regular file, commit it, and re-run" >&2
    exit 1
  fi
  #
  # A LOCAL committed star still carrying the shipped-default placeholder marker is an
  # un-replaced template — NOT a real approved goal — so FAIL before any verdict. (FABRICA_SELF
  # above is exempt; the marker-FAIL is keyed to LOCAL only.)
  #
  # The check goes through ns_has_shipped_default_marker (shared with doctor.sh (h)), which
  # SCOPES the match to the ACTIVE-entry region and matches the marker WHITESPACE/CASE-
  # INSENSITIVELY. Scoping stops the marker's mentions in the template PROSE from wrongly FAILing
  # a correctly-replaced star (marker cleared from the active heading, still named in prose);
  # the insensitive match stops an un-replaced placeholder whose marker is spaced/cased/split
  # differently (`<!--fabrica-shipped-default-->`, UPPERCASE, tab, reflow-split) from wrongly
  # AUTHORIZING. Feed the committed content over stdin (`-`) so we never touch a working-tree file.
  if printf '%s' "$north_star" | ns_has_shipped_default_marker -; then
    echo "error: ${repo}'s .fabrica/north-star.md is still the shipped placeholder (carries the" >&2
    echo "       '<!-- fabrica-shipped-default -->' marker) — the manager-debate gate will not" >&2
    echo "       debate against an un-replaced template. Replace it with your own north star," >&2
    echo "       remove the marker from the active heading line, commit it, and approve it," >&2
    echo "       then re-run. See reviewer/manager-review.md > north star" >&2
    exit 1
  fi
else
  # No committed north star for this target: either UNSET/EMPTY/NOREPO from the resolver, or a
  # .fabrica/north-star.md that exists ONLY as an uncommitted working-tree edit (not at
  # $head_commit). None authorizes proactive work — FAIL with an actionable pointer BEFORE
  # invoking Codex, so the operator sets and COMMITS a north star rather than debating an empty
  # (or uncommitted, unreviewed) goal.
  echo "error: no committed north star resolved for ${repo} (resolver: ${ns_kind}) — .fabrica/north-star.md is" >&2
  echo "       not committed at HEAD (${head_commit}). The manager-debate gate reads COMMITTED" >&2
  echo "       target state — an uncommitted local edit does not authorize proactive work. Set one up:" >&2
  echo "         run '\"${control_plane_root}/scripts/setup-target-repo.sh\" ${repo}' from this" >&2
  echo "         checkout to seed .fabrica/north-star.md, then replace the placeholder, commit," >&2
  echo "         and approve it — see reviewer/manager-review.md > north star" >&2
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

== CURRENT NORTH STAR (the target's committed north star) ==
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
