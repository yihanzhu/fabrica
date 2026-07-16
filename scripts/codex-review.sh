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
# MODEL TIERING (#110) — the review gate is a max-capability decision point (spend-by-leverage,
# see config/models.conf), so it does not simply "keep the operator's model/effort defaults": it
# sources this clone's shipped config/models.conf (resolved from THIS script's own location) and
# ALWAYS passes `-c model_reasoning_effort="$FABRICA_REVIEW_EFFORT"`, explicitly raising the gate
# to that effort (default `high`) instead of silently inheriting whatever the operator's personal
# `~/.codex/config.toml` happens to default to (often `low`). A `-m <model>` is passed only when
# one is actually resolved (the CLI `-m` flag keeps precedence; else FABRICA_CODEX_MODEL, empty by
# default = inherit Codex's own default model) — never downgraded by task class. The resolved
# model + effort are echoed into the posted PR comment's header (`reviewer: <model> @ <effort>`)
# so every review documents what gated it. A missing/unsourceable shipped config FAILs loudly
# (pointing at scripts/doctor.sh) rather than silently reviewing at an unknown effort.
#
# PER-TARGET OVERRIDE — TRUST ANCHOR + PARSE-NOT-SOURCE (P1 fix, adversarial review of PR #115).
# If the REVIEWED repo has committed its own `.fabrica/models.conf` (see
# templates/.fabrica/models.conf), it may override the PRODUCER/MODEL keys only. Two things
# changed from the original design here, both security-critical:
#   - TRUST ANCHOR: the override is read from the gh-BOUND repo's DEFAULT branch, fetched fresh —
#     the SAME class of anchor manager-review.sh uses — never the PR head worktree. The PR head is
#     the untrusted diff UNDER review; reading a config override off it would let a malicious PR
#     gate its own review. The default branch is already-merged, already-gated content, so it is
#     trusted as a config source the same way manager-review.sh's anchor is.
#   - PARSE, NOT SOURCE: the override is read as DATA via mc_parse_target_override
#     (scripts/lib/models-conf.sh) — never `source`/`.`/`eval`. A target-committed file must never
#     run as shell in this non-sandboxed harness. The parser also refuses to let a target set
#     FABRICA_REVIEW_EFFORT at all (recognized, but ignored with a visible warning folded into the
#     posted PR comment) — a target can never lower or otherwise change its own review gate.
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
# fork-safely (`git fetch <remote> refs/pull/<PR#>/head`, from the configured git remote
# whose URL matches the repo gh resolved — so the operator's own authenticated transport is
# used, which works on private repos and SSH-only checkouts where a synthesized web URL would
# fail; fork-safe + host-correct on GitHub Enterprise too — which brings the head commit into
# the object store even for fork PRs) and adds a
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
# DEGRADED-REVIEW DETECTION (#117) — FAIL LOUDLY instead of posting a fake "clean". Real
# incident (2026-07-11): `codex-code-mode-host` failed to spawn (missing from a Homebrew codex
# install); `codex exec review` still exited 0 in ~8-14s at confidence ~0.05 with a generic
# "no actionable findings" and ZERO diff inspection — and this script posted it as a normal
# clean review, which the standing auto-merge rail would then merge unreviewed code on. This
# script now catches codex's exit code EXPLICITLY (errexit momentarily off, mirroring the
# config-sourcing pattern above) and greps the captured stdout (`-o`) + stderr for a known
# code-mode/host spawn-failure signal, via the SHARED detector `cd_degraded_reason`
# (scripts/lib/codex-degraded.sh — shared with manager-review.sh so the two gates can't diverge
# on what counts as degraded). On EITHER signal: exit non-zero AND post an explicit DEGRADED
# marker comment (never the clean verdict) — with a DIFFERENT header line than the real
# `## Codex reviewer (cross-vendor, read-only)` one and NO `Reviewed-head`/`Reviewed-base`
# markers, so scripts/merge-pr.sh's marker parser (which matches that exact header + those exact
# marker keys) does not mistake it for a completed review — belt-and-suspenders on top of Faber
# reading the comment text. A genuine clean review (codex ran, inspected the diff, found
# nothing) carries neither signal and still posts normally — see scripts/lib/codex-degraded.sh
# for why no confidence/duration heuristic is layered on top (over-triggering risk).
#
# Usage: scripts/codex-review.sh [-m <model>] <PR#>
#   (or, with fabrica/scripts on PATH: codex-review.sh [-m <model>] <PR#>)

usage() {
  echo "usage: $0 [-m <model>] <PR#>" >&2
  echo "  run from within the target repo's clone; reviews the PR on the CURRENT repo" >&2
  echo "  runs 'codex exec review' on the PR and posts Codex's review as a PR comment, verbatim" >&2
  echo "  always runs at config/models.conf's FABRICA_REVIEW_EFFORT (a target's committed" >&2
  echo "  .fabrica/models.conf, read from its default branch, may override FABRICA_CODEX_MODEL" >&2
  echo "  only — it can never lower/change the gate's effort); -m here keeps precedence" >&2
  echo "  -m <model>  optional Codex model override (defaults to the resolved config, else Codex's own default)" >&2
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

# Source the shared gh-bound remote-identity selection helper (scripts/lib/gh-remote.sh), located
# from THIS script's OWN location (follow symlinks, then dirname/..) so it is found regardless of
# which target repo's cwd this is invoked from. The remote-selection logic (normalize a git URL to
# host+owner/repo, compute gh's identity, pick the matching configured remote) is FACTORED here so
# codex-review.sh and manager-review.sh share ONE implementation and can't diverge.
cr_script_path="$0"
while [ -L "$cr_script_path" ]; do
  cr_link_target="$(readlink "$cr_script_path")"
  case "$cr_link_target" in
    /*) cr_script_path="$cr_link_target" ;;
    *)  cr_script_path="$(dirname "$cr_script_path")/$cr_link_target" ;;
  esac
done
# This script lives at <root>/scripts/codex-review.sh; the lib is its sibling under lib/.
ghr_lib="$(dirname "$cr_script_path")/lib/gh-remote.sh"
if [ ! -f "$ghr_lib" ]; then
  echo "error: gh-remote helper not found (${ghr_lib})" >&2
  echo "       it ships in the fabrica control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/gh-remote.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/gh-remote.sh
. "$ghr_lib"

# Source the shared PARSER for a target-committed .fabrica/models.conf override (P1 fix, #115) —
# mc_parse_target_override reads that file as DATA, never as shell (see scripts/lib/models-conf.sh
# for the full rationale). Located alongside gh-remote.sh, from this script's own location.
mc_lib="$(dirname "$cr_script_path")/lib/models-conf.sh"
if [ ! -f "$mc_lib" ]; then
  echo "error: models-conf helper not found (${mc_lib})" >&2
  echo "       it ships in the fabrica control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/models-conf.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/models-conf.sh
. "$mc_lib"

# Source the shared DEGRADED-REVIEW detector (#117) — cd_degraded_reason decides, in ONE place,
# whether a codex run FAILED TO RUN a genuine review (non-zero exit, or a known code-mode/host
# spawn-failure signal in its output/stderr) vs. genuinely ran clean, so codex-review.sh and
# manager-review.sh can't diverge on what counts as degraded. Located alongside gh-remote.sh and
# models-conf.sh, from this script's own location.
cd_lib="$(dirname "$cr_script_path")/lib/codex-degraded.sh"
if [ ! -f "$cd_lib" ]; then
  echo "error: codex-degraded helper not found (${cd_lib})" >&2
  echo "       it ships in the fabrica control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/codex-degraded.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/codex-degraded.sh
. "$cd_lib"

# This clone's own control-plane root (same derivation as $ghr_lib above, canonicalized via
# cd/pwd -P) — used below to resolve config/models.conf relative to THIS script's location,
# never a hardcoded personal path, regardless of which target repo's cwd invoked it.
cr_control_plane_root="$(cd "$(dirname "$cr_script_path")/.." && pwd -P)"

# Source the shipped model-tiering defaults (config/models.conf, #109) from this clone's own
# control-plane root, so the review gate ALWAYS runs at an explicit, known reasoning effort
# (#110) instead of silently inheriting whatever the operator's personal Codex CLI/config
# happens to resolve to. Fail loudly rather than silently reviewing at unknown effort: a missing
# or unsourceable config is a restore/setup gap, not something to paper over.
models_conf="$cr_control_plane_root/config/models.conf"
if [ ! -f "$models_conf" ]; then
  echo "error: config/models.conf not found (${models_conf})" >&2
  echo "       it ships in the fabrica control-plane repo; restore it (see RESTORE.md), then" >&2
  echo "       re-run. scripts/doctor.sh check (k) diagnoses this file — run it for details" >&2
  exit 1
fi
# Source it with errexit MOMENTARILY OFF, capturing the real exit status via `$?` right after —
# NOT `if ! . "$models_conf"; then …` (which looks equivalent but is NOT reliable: under `set -e`,
# some bash versions — e.g. bash 3.2, macOS's shipped /bin/bash — abort the WHOLE script the
# instant a command inside a SOURCED file fails, even when the `.` itself sits in a tested `if`/`||`
# context that POSIX says should be exempt from errexit. Toggling errexit off for the source call
# sidesteps that version-dependent gap entirely, on every bash we need to support).
set +e
# shellcheck source=config/models.conf
. "$models_conf"
models_conf_rc=$?
set -e
if [ "$models_conf_rc" -ne 0 ]; then
  echo "error: config/models.conf failed to source (${models_conf}) — check it for a shell" >&2
  echo "       syntax error (bash -n ${models_conf}). scripts/doctor.sh check (k) diagnoses" >&2
  echo "       this file — run it for details" >&2
  exit 1
fi
if [ -z "${FABRICA_REVIEW_EFFORT:-}" ]; then
  echo "error: FABRICA_REVIEW_EFFORT is unset/empty after sourcing ${models_conf}" >&2
  echo "       the review gate refuses to run at an unknown reasoning effort; fix the shipped" >&2
  echo "       config (scripts/doctor.sh check (k) diagnoses it), then re-run" >&2
  exit 1
fi

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

# Resolve gh's canonical repo identity — the HOST + `owner/repo` of the repo it bound the
# review to — and select the configured git remote whose URL resolves to that SAME identity,
# via the SHARED helper (scripts/lib/gh-remote.sh), so codex-review.sh and manager-review.sh
# select the remote identically. ghr_gh_repo_id passes `$repo` EXPLICITLY to `gh repo view`
# (so the URL reports THAT repo, never a PR-followed parent/upstream) and reads the HOST off it
# (host-correct on GitHub Enterprise / non-github.com). ghr_select_remote then matches on repo
# IDENTITY (fork-safe) — NOT blindly `origin`: in a fork workflow `origin` = your fork while the
# PR lives on `upstream`, so it prefers `origin` ONLY when `origin` is itself the match. If NO
# configured remote resolves to gh's repo, we REFUSE (below) rather than fetch from an
# unauthenticated synthesized URL — using the selected remote NAME means the operator's own
# configured transport + credentials are used (works on private repos and SSH-only checkouts,
# where a synthesized HTTPS web URL carries no credentials and `git fetch <url>` would fail).
gh_repo_id="$(ghr_gh_repo_id "$repo")"
selected_remote="$(ghr_select_remote "$gh_repo_id")"

if [ -z "$selected_remote" ]; then
  echo "error: the repo gh resolved (${repo}) is not reachable via any configured git remote;" >&2
  echo "       add it (e.g. 'git remote add upstream <url>') and re-run" >&2
  exit 1
fi

# EFFECTIVE-URL IDENTITY GATE (#102 fix A, FAIL-CLOSED). Selection matched the remote by URL, but the
# fetch below goes BY NAME — which applies any `url.<other>.insteadOf`, so the URL git actually
# contacts can be a DIFFERENT repo. Before fetching the PR head + base (and reviewing off them), assert
# the EFFECTIVE fetch URL is a NON-EMPTY GitHub identity EQUAL to the one gh bound the review to: a
# cross-repo substitution, a local-path/file://-substitution, or any transport we can't PROVE is gh's
# repo all FAIL closed (round-2 — empty is no longer trusted; a deliberate local mirror needs
# FABRICA_ALLOW_LOCAL_MIRROR=1). So the reviewer never fetches a source it can't prove is the PR's repo.
if ! ghr_assert_effective_identity "$selected_remote" "$gh_repo_id"; then
  exit 1
fi

# Fetch the PR head fork-safely AND refresh the base, into THIS repo's object store, from the
# SELECTED REMOTE NAME (not a synthesized URL) so the operator's configured transport +
# credentials are used. The remote was chosen by matching gh's canonical host + owner/repo, so
# the source is PROVABLY the repo `gh` resolved — fork-safe (we match identity, not blindly
# `origin`), host-correct (it's the operator's real remote URL, GHE included), and auth-correct
# (the operator's transport: SSH key, gh credential helper, etc.). In a fork workflow (`origin`
# = your fork, `upstream` = the canonical repo PRs target) we'd select `upstream`; fetching from
# `origin` there would fail (the PR ref doesn't exist on the fork) or grab a same-numbered,
# unrelated PR.
#
# We use EXPLICIT, FULLY-QUALIFIED refspecs so both land at a known ref regardless of the
# clone's configured fetch refspecs. Both sources are qualified (`refs/pull/<PR#>/head`
# and `refs/heads/<base>`) so a same-named tag on the repo (e.g. a release branch and tag
# both named `v1.2.0`) can't make the fetch source resolve ambiguously or fail before
# Codex runs. The `refs/pull/<PR#>/head` source brings the PR head commit in even when
# the PR comes from a fork (a plain `git fetch` of a branch would not). We write BOTH into
# private, PER-RUN-UNIQUE local refs we control (under `refs/codex-review/<PR#>-<PID>/`),
# never a remote-tracking ref tied to a remote name — that keeps the destinations
# independent of which remote we selected, avoids clobbering the operator's
# `<remote>/<base>` tracking ref with a commit fetched into our own ref, AND keeps two
# reviews launched from the SAME checkout from colliding (a shared ref name would let a later
# run's fetch force-update — or its cleanup delete — the ref while an earlier run is still
# resolving `--base`, reviewing the wrong base or failing spuriously; the temp worktree is
# already per-run via mktemp, so the refs now match). Read-only stays literally true: we
# force-update (the `+` prefix) ONLY these two refs we own and delete both before exit (the
# head right after its SHA is captured, the base in the cleanup trap once `--base` has read
# it); never a global `git fetch --force`. A global `--force` plus git's tag
# auto-following could force-update local `refs/tags/*` if the repo moved a tag reachable
# from the fetched commits — an operator-state mutation. `--no-tags` disables that
# auto-following, so this fetch touches nothing outside the two named destination refs.
# `--refmap=` (empty, #102 fix C) additionally DISABLES the remote's configured fetch refmap for
# this fetch, so the operator's `refs/remotes/<remote>/<base>` tracking ref is NOT force-updated as
# a side effect of fetching the base branch — only the two explicit per-run destinations are written.
run_ref_ns="refs/codex-review/${pr}-$$"
pr_head_ref="${run_ref_ns}/head"
base_dest_ref="${run_ref_ns}/base"
git fetch --no-tags --refmap= "$selected_remote" \
  "+refs/pull/${pr}/head:${pr_head_ref}" \
  "+refs/heads/${base}:${base_dest_ref}"
pr_head="$(git rev-parse "$pr_head_ref")"
git update-ref -d "$pr_head_ref"
base_ref="$base_dest_ref"
# Record the EXACT base commit Codex reviews against. The review runs `--base
# "$base_ref"` (the per-run base ref), so the effective diff is `pr_head` vs. THIS commit.
# Capturing it lets a later actor (scripts/merge-pr.sh) refuse if the base advanced after the
# review — a moved base changes the merged integration even when the head is unchanged.
base_head="$(git rev-parse "$base_ref")"

# TRUST ANCHOR for the per-target .fabrica/models.conf override (P1 fix, adversarial review of PR
# #115) — fetch the gh-BOUND repo's DEFAULT branch FRESH: the SAME class of anchor
# manager-review.sh uses. NEVER the PR head/base above — those are the untrusted diff UNDER
# review, so reading a config override off either would let a malicious PR gate its OWN review
# (via injected shell, or — even without injection — simply by committing a lowered
# FABRICA_REVIEW_EFFORT). The default branch is already-merged, already-gated content, so it is
# trusted as the override's source the same way the manager-debate gate's anchor is. This is
# independent of the PR's base branch ($base above): a PR can target a non-default branch, so we
# resolve the default branch AUTHORITATIVELY from gh (ghr_gh_default_branch), never assume it
# equals $base.
default_branch="$(ghr_gh_default_branch "$repo")"
if [ -z "$default_branch" ]; then
  echo "error: gh could not resolve the default branch of ${repo} (gh repo view --json defaultBranchRef)." >&2
  echo "       The per-target .fabrica/models.conf override is read from that branch's" >&2
  echo "       freshly-fetched commit — never the PR head, which is untrusted content under" >&2
  echo "       review. Confirm 'gh repo view ${repo}' works (auth + network), then re-run." >&2
  exit 1
fi
models_anchor_ref="${run_ref_ns}/models-anchor"
if ! models_anchor_commit="$(ghr_fetch_default_commit "$selected_remote" "$default_branch" "$models_anchor_ref")" \
   || [ -z "$models_anchor_commit" ]; then
  echo "error: failed to fetch the default branch '${default_branch}' from remote '${selected_remote}'" >&2
  echo "       (${repo}) to read the per-target .fabrica/models.conf override. Confirm network" >&2
  echo "       access and that the branch exists on the remote, then re-run." >&2
  exit 1
fi

# Allocate temp paths in the system temp dir (never inside the repo, so nothing here
# can be committed): a detached worktree dir, the review output file, and (#117) a captured-
# stderr file. All three get a fresh mktemp path each run, so a stale worktree entry from a
# hard-killed previous run never collides with — or blocks — the `git worktree add` below; that
# is why no global `git worktree prune` is needed (and we avoid one to not touch unrelated
# worktrees).
worktree="$(mktemp -d)"
tmp="$(mktemp)"
stderr_tmp="$(mktemp)"

# Clean up on EVERY exit (success or failure): remove the temp worktree, the temp output
# file, and the private per-run base + models-anchor refs we own (the head ref was already
# deleted above once its SHA was captured; the base ref must live until `codex exec review
# --base` reads it, and the models-anchor ref until the .fabrica/models.conf override read
# below, so both are dropped here). Deleting only this run's own `refs/codex-review/<PR#>-<PID>/*`
# never disturbs a concurrent run's refs. `git worktree remove --force` drops the worktree even
# though it is at a detached head; the rm -rf fallback covers the case where it was never added.
cleanup() {
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  git update-ref -d "$base_dest_ref" 2>/dev/null || true
  git update-ref -d "$models_anchor_ref" 2>/dev/null || true
  rm -f "$tmp" "$stderr_tmp"
}
trap cleanup EXIT

# Add a DETACHED, throwaway worktree at the PR head, isolated from the operator's
# checkout. Reviewing here means the operator's branch / index / working tree / unpushed
# commits are never touched — that is what makes the reviewer truly read-only.
git worktree add --detach "$worktree" "$pr_head"

# Per-target override: if the REVIEWED repo has committed a .fabrica/models.conf (same
# format/keys as config/models.conf — see templates/.fabrica/models.conf), PARSE it (never
# source/eval it — see scripts/lib/models-conf.sh for the full P1 rationale) AFTER the shipped
# defaults, so it can override the PRODUCER/MODEL keys for this target only. Read it from the
# gh-BOUND DEFAULT BRANCH's freshly-fetched commit ($models_anchor_commit, resolved above) — NEVER
# the PR head worktree ($worktree, at the untrusted $pr_head under review). Absence is normal
# (most targets have no override; `git show` exits non-zero and we skip). GATE keys
# (FABRICA_REVIEW_EFFORT) are recognized by the parser but never applied from a target override —
# a target can never lower/change its own review gate — mc_parse_target_override instead warns
# (stderr) and sets MC_TARGET_OVERRIDE_GATE_WARNING, which we fold into the posted PR comment below.
MC_TARGET_OVERRIDE_GATE_WARNING=0
if target_models_conf_content="$(git show "${models_anchor_commit}:.fabrica/models.conf" 2>/dev/null)"; then
  # Here-string, NOT a pipe: the rightmost command of a pipe runs in a SUBSHELL under bash 3.2 (no
  # `lastpipe`), which would silently discard the FABRICA_* assignments the parser makes here.
  mc_parse_target_override <<<"$target_models_conf_content"
fi

# Resolve the effective Codex model: the existing -m CLI flag keeps precedence over config (per
# #110) — it is only missing when the operator omitted -m, in which case we fall back to
# FABRICA_CODEX_MODEL (empty by default, meaning "inherit the operator's own Codex CLI/config
# default"; a target's .fabrica/models.conf override, parsed just above, may have changed it).
# model_display feeds the resolved-config echo below so every review documents what gated it,
# even when nothing was explicitly pinned (shown as "operator-default").
effective_model="$model"
if [ -z "$effective_model" ]; then
  effective_model="${FABRICA_CODEX_MODEL:-}"
fi
model_display="${effective_model:-operator-default}"

# Force read-only via -c so the review cannot inherit a writable sandbox from the
# operator's Codex config. `codex exec review` has no -s/--sandbox flag (only the
# parent `codex exec` does), so the config override is the way to pin it; we avoid
# --ignore-user-config so the operator's model/effort defaults still apply. `-C` is a
# flag on the parent `codex exec` (not on the `review` subcommand), so it must come
# before `review`; it points codex at the temp worktree to review the PR head diff
# against the qualified, freshly-fetched per-run base ref (refs/codex-review/<PR#>-<PID>/base).
# `-c model_reasoning_effort="$FABRICA_REVIEW_EFFORT"` is ALWAYS passed (#110) — the review
# gate is a max-capability decision point (spend-by-leverage), never class-routed down, so this
# raises it from whatever effort the operator's Codex config happened to default to (often
# `low`) to the resolved config's explicit value. `-m` is passed only when a model was actually
# resolved (CLI flag or FABRICA_CODEX_MODEL); empty means "inherit Codex's own default model".
review_cmd=(codex exec -C "$worktree" review -c sandbox_mode="read-only" -c model_reasoning_effort="$FABRICA_REVIEW_EFFORT" --base "$base_ref" -o "$tmp")
if [ -n "$effective_model" ]; then
  review_cmd+=(-m "$effective_model")
fi

# #117 — run with errexit MOMENTARILY OFF (same pattern as the config-sourcing block above) so a
# non-zero codex exit is caught HERE, explicitly, instead of aborting the whole script via
# `set -e` before we can post the DEGRADED marker below (spec point 3: ANY detection must still
# emit/post that marker where the review normally lands, not just exit quietly). Stderr is
# captured to $stderr_tmp — never discarded — so it can be (a) grepped for a code-mode/host
# spawn-failure signal and (b) surfaced: re-emitted to the operator's terminal right after, and
# folded into the posted DEGRADED comment for a human reading the PR.
set +e
"${review_cmd[@]}" 2>"$stderr_tmp"
codex_rc=$?
set -e
cat "$stderr_tmp" >&2

# #117 DEGRADED DETECTION — the REQUIRED robust core, via the shared detector
# (scripts/lib/codex-degraded.sh, sourced above) so this gate and manager-review.sh can't
# diverge: a non-zero codex exit OR a known code-mode/host spawn-failure signal anywhere in the
# captured stdout (-o "$tmp") or stderr means codex FAILED TO RUN a genuine review — it did not
# actually inspect the diff — as distinct from a genuine clean review (exits 0, no such signal),
# which must still PASS (no over-triggering). `if degraded_reason="$(...)"` is a condition
# context, so it is exempt from `set -e` even though cd_degraded_reason returns non-zero for the
# "genuine, not degraded" case.
if degraded_reason="$(cd_degraded_reason "$codex_rc" "$tmp" "$stderr_tmp")"; then
  echo "error: Codex review DEGRADED — ${degraded_reason}. NOT posting a clean verdict." >&2
  {
    echo "## Codex reviewer — DEGRADED, REVIEW DID NOT RUN (cross-vendor, read-only)"
    echo
    echo "Attempted-head: ${pr_head}"
    echo "Attempted-base: ${base_head}"
    echo "reviewer: ${model_display} @ ${FABRICA_REVIEW_EFFORT}"
    echo
    echo "**This Codex run FAILED TO RUN a genuine review — this is NOT a clean verdict. Do not"
    echo "merge on the strength of this comment. (Deliberately: this header and these"
    echo "\`Attempted-*\` lines do NOT match what \`scripts/merge-pr.sh\` looks for — no"
    echo "\`Reviewed-head\`/\`Reviewed-base\` marker is stamped here, so it cannot be mistaken for"
    echo "a completed review even mechanically.)**"
    echo
    echo "Reason: ${degraded_reason}."
    echo
    echo "_Posted by \`codex-review.sh\` (#117 hardening): a degraded/non-substantive Codex run_"
    echo "_is surfaced loudly instead of silently posted as a fake pass. Fix the underlying_"
    echo "_codex/toolchain issue (see the captured output/stderr below), then re-run_"
    echo "_\`scripts/codex-review.sh ${pr}\`._"
    echo
    echo '```'
    echo "-- codex stdout/-o capture --"
    if [ -s "$tmp" ]; then cat "$tmp"; else echo "(empty)"; fi
    echo
    echo "-- codex stderr --"
    if [ -s "$stderr_tmp" ]; then cat "$stderr_tmp"; else echo "(empty)"; fi
    echo '```'
  } | gh pr comment "$pr" --repo "$repo" --body-file - || \
    echo "error: additionally failed to post the DEGRADED marker comment to PR #${pr}" >&2
  exit 1
fi

# Non-empty guard. The degraded-detection block above already caught a non-zero codex exit and
# any known spawn-failure signal; this guards the REMAINING vacuous case — a zero exit with an
# empty (or whitespace-only) `-o` capture (a terse non-answer, or an empty review for some
# diffs) — which would otherwise post a header-only comment with no body. That vacuous review
# still carries the `Reviewed-head:`/`Reviewed-base:` markers, so scripts/merge-pr.sh (which
# keys its "a review exists" check on the markers, not the content) would treat the merge gate
# as satisfied. Refuse to post when there's no review content. The cleanup trap still runs on
# this exit (it is an EXIT trap), so the temp worktree, output file, and per-run base ref are
# removed.
if ! grep -q '[^[:space:]]' "$tmp"; then
  echo 'error: Codex produced no review output; not posting' >&2
  exit 1
fi

# Post the review verbatim, with a short header marking it the cross-vendor reviewer.
# The header also records the EXACT commits Codex reviewed as parseable marker lines
# (`Reviewed-head: <full-sha>` and `Reviewed-base: <full-sha>`), so a later actor (e.g.
# scripts/merge-pr.sh) can bind a merge to the precise integration this review covered,
# and refuse if EITHER the head OR the base has since moved (both change the effective
# diff). The markers are part of Faber's header prefix — clearly separate from Codex's
# verbatim body below — so this stays read-only / comments-only / verbatim (no behavior
# change). A `reviewer: <model> @ <effort>` line records the RESOLVED config (#110) — model
# and reasoning effort actually applied, after CLI/-m > FABRICA_CODEX_MODEL and any per-target
# .fabrica/models.conf override — so every review documents what gated it on the record, and
# personal-config drift (e.g. a stray operator default) is visible in the PR history. If the
# target's override tried to set FABRICA_REVIEW_EFFORT (rejected by mc_parse_target_override,
# #115 P1 fix), a visible warning line is folded in here too — never a silent ignore.
{
  echo "## Codex reviewer (cross-vendor, read-only)"
  echo
  echo "Reviewed-head: ${pr_head}"
  echo "Reviewed-base: ${base_head}"
  echo "reviewer: ${model_display} @ ${FABRICA_REVIEW_EFFORT}"
  if [ "$MC_TARGET_OVERRIDE_GATE_WARNING" = "1" ]; then
    echo "warning: target override attempted to set gate effort — ignored"
  fi
  echo
  echo "_Posted verbatim by \`codex-review.sh\` (\`codex exec review --base ${base_ref}\` in an isolated temp worktree, sandbox forced read-only). Comments only — Codex never pushes, approves, or merges._"
  echo
  cat "$tmp"
} | gh pr comment "$pr" --repo "$repo" --body-file -
