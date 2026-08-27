#!/usr/bin/env bash
set -euo pipefail

# manager-review.sh — the Codex cross-vendor MANAGER reviewer harness.
#
# The mirror of codex-review.sh, one layer up: where codex-review.sh debates a *diff*
# with the PR as the message bus, this debates a *proposed issue* with the ISSUE as the
# message bus. It asks Codex whether a yshifu-drafted issue is worth raising toward the
# current north star, and posts Codex's verdict to the issue verbatim, so a Claude
# session never edits or blends the manager-review (that is what keeps the cross-vendor
# split honest). Run by yshifu in-session on a *proactive* (yshifu-generated) issue before
# it gets the `ready` label (see reviewer/manager-review.md).
#
# NORTH-STAR SOURCE (#98a) — the debate is against the TARGET's own north star, resolved via
# scripts/lib/north-star.sh from the cwd's checkout: the target's committed
# `.ystack/north-star.md` (with the legacy `.fabrica/north-star.md` still honored as a
# fallback, so targets that have not renamed yet keep working), or (on a ystack-self run)
# the control-plane root NORTH_STAR.md.
# The content is read COMMITTED at the SAME commit the review worktree is pinned to (never a
# free-floating later HEAD): the north star is an autonomy-authorization artifact, so an
# uncommitted local edit must not silently redirect the gate. A target with no committed star
# (UNSET), or a LOCAL star still carrying the shipped-default placeholder marker (either the
# current or the legacy marker string), FAILs before any Codex verdict. This gate source is
# IDENTICAL to yshifu's approval source (persona + /yshifu) — they flip together so the gate
# never reads a source the operator did not approve.
#
# The debate is over ROUNDS, on the issue: this script posts ONE Codex verdict comment;
# yshifu reads it and either advances (consensus to proceed), refines (edit the issue +
# reply + re-run — another round), or drops (close with rationale). Consensus-only: the
# coder loop starts only when BOTH yshifu and Codex agree. The reviewer is VETO-ONLY — it
# never labels `ready`, edits the issue, or merges; its only effect is the verdict comment.
#
# This script ONLY writes a single ISSUE comment. It never edits the issue, applies or
# removes labels, pushes, or merges. Read-only is FORCED via `-c sandbox_mode="read-only"`
# so the review can't inherit a writable sandbox from the operator's Codex config; we
# deliberately do NOT pass --dangerously-bypass-* . We use -c rather than
# --ignore-user-config on purpose: that flag would also drop the operator's model/effort
# defaults, which we want to keep.
#
# MODEL TIERING (#110) — the manager-debate gate is a max-capability decision point
# (spend-by-leverage, see config/models.conf), so it does not simply "keep the operator's
# model/effort defaults": it sources this clone's shipped config/models.conf (resolved from
# THIS script's own location, alongside the ns_lib/ghr_lib sourcing below) and ALWAYS passes
# `-c model_reasoning_effort="$YSTACK_DEBATE_EFFORT"`, explicitly raising the gate to that
# effort (default `high`) instead of silently inheriting whatever the operator's personal
# `~/.codex/config.toml` happens to default to (often `low`). A `-m <model>` is passed only
# when one is actually resolved (the CLI `-m` flag keeps precedence; else YSTACK_CODEX_MODEL,
# empty by default = inherit Codex's own default model) — never downgraded by task class. The
# resolved model + effort are echoed into the posted issue comment's header (`reviewer: <model>
# @ <effort>`) so every debate documents what gated it. A missing/unsourceable shipped config
# FAILs loudly (pointing at scripts/doctor.sh) rather than silently debating at an unknown effort.
#
# PER-TARGET OVERRIDE — PARSE-NOT-SOURCE (P1 fix, adversarial review of PR #115). If the TARGET
# repo has committed its own `.ystack/models.conf` (see templates/.ystack/models.conf; the older
# legacy `.fabrica/models.conf` still works as a fallback), it may override the PRODUCER/MODEL keys
# only. This script's trust anchor was already correct (the override is read from the SAME
# pinned worktree/commit, $head_commit, the debate runs against — the gh-bound default branch,
# fetched fresh, never the operator's possibly-stale cwd checkout), but the override used to be
# `source`d directly into this non-sandboxed harness shell — a target-committed file must never
# run as shell here. It is now read as DATA via mc_parse_target_override
# (scripts/lib/models-conf.sh) — never `source`/`.`/`eval`. The parser also refuses to let a
# target set YSTACK_DEBATE_EFFORT at all (recognized, but ignored with a visible warning folded
# into the posted issue comment) — a target can never lower or otherwise change its own
# manager-debate gate.
#
# PER-TARGET OVERRIDE — SYMLINK-SAFE READ (P2 fix, adversarial review of PR #115). The parse-not-
# source fix above still read the override with a `<`-redirect from the checked-out worktree
# path, which FOLLOWS SYMLINKS. A target that commits its models.conf override as a symlink to
# an arbitrary operator-local regular file would pass the `[ -f ]` check and have the parser
# read the POINTED-TO file's content; a charset-valid `YSTACK_CODEX_MODEL=<value>` line there
# then leaked into the PUBLIC issue comment header — a narrow info-leak of an arbitrary local
# file (the device/FIFO DoS variant was already blocked by `[ -f ]`). The override is now read
# via `git show "${head_commit}:<path>"` instead — the SAME anchor commit, but as a git blob,
# never a filesystem path — so a symlink entry yields only its link-target-path STRING (which
# fails the parser's charset check and is ignored), exactly mirroring codex-review.sh's
# identical `git show`-based read and its existing symlink guards on the committed north star
# above (SYMLINK guard, round-2 FIX 4).
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
# DEGRADED-REVIEW DETECTION (#117, hardened in #119) — FAIL LOUDLY instead of posting a fake
# PROCEED/REFINE/DROP. The same real incident that motivated codex-review.sh's #117 hardening
# applies here: a codex run whose code-mode/host toolchain failed to spawn can still "complete"
# (exit 0) with a generic, non-substantive verdict that never actually read the issue/repo.
#
# The harness forces `codex exec --json`: stdout is a typed JSONL event stream instead of the
# normal stream that repeats the final, issue-influenced verdict. The shared detector validates
# every event/item type (unknown schema fails closed), requires a final `turn.completed` after an
# agent message PLUS at least one successful structured command_execution (positive proof the
# repository command host ran), treats fatal `error` / `turn.failed` as hard failures, and
# phrase-matches only CLI-authored error/failed-MCP fields — never agent messages, command output,
# or the `-o` answer. It also checks raw stderr and catches the process exit code explicitly.
# This structured boundary fixes #119's P1 false-positive: normal
# Codex writes the final answer to BOTH `-o` and stdout, so unstructured stdout is not
# diagnostic-only. On any degraded signal or invalid/incomplete JSONL: exit non-zero AND post an
# explicit DEGRADED marker issue comment (never the untrustworthy `-o` answer body verbatim — see
# the INTEGRITY note below) — `VERDICT: DEGRADED`, never PROCEED/REFINE/DROP, with a DIFFERENT
# header line than the real `## Codex manager-reviewer (cross-vendor, read-only)` one — so
# yshifu's "proceed only on consensus" rule can never read this as a PROCEED. A genuine verdict
# (codex ran, read the repo, formed a real PROCEED/REFINE/DROP judgment) carries neither signal
# and still posts normally. A genuine exit-0 run with an EMPTY/whitespace-only `-o` capture (no
# actual verdict text) is ALSO refused — mirroring codex-review.sh's non-empty guard — rather
# than posting a header-only comment with no PROCEED/REFINE/DROP.
#
# DEGRADED-COMMENT INTEGRITY (#119 P2 fix, highest priority; same fix as codex-review.sh). The
# DEGRADED comment used to `cat` codex's raw `$tmp`/`$stderr_tmp` output verbatim into the posted
# body. scripts/merge-pr.sh scans the WHOLE body of any comment authored by the gh-authenticated
# operator for line-anchored marker lines — and the DEGRADED comment IS authored by that operator
# (this harness posts as them). Although merge-pr.sh only acts on PR comments today, this issue
# comment could still carry the exact marker text if codex's diagnostic output were adversarially
# influenced (e.g. by injected content in the issue body it read); a DEGRADED comment therefore
# never embeds the `-o` answer at all and embeds only a BOUNDED, SANITIZED snippet of the
# raw-stderr tail via `cd_sanitize_snippet`; JSONL is never posted because it contains
# agent/command/repository payloads that a line prefix would not make private.
#
# Usage: scripts/manager-review.sh [-m <model>] <issue#>
#   (or, with ystack/scripts on PATH: manager-review.sh [-m <model>] <issue#>)

usage() {
  echo "usage: $0 [-m <model>] <issue#>" >&2
  echo "  run from within the target repo's clone; debates the ISSUE on the CURRENT repo" >&2
  echo "  runs 'codex exec' read-only with the manager-reviewer prompt + north star + the" >&2
  echo "  issue, and posts Codex's PROCEED/REFINE/DROP verdict as an issue comment, verbatim" >&2
  echo "  always runs at config/models.conf's YSTACK_DEBATE_EFFORT (a target's committed" >&2
  echo "  .ystack/models.conf — or the legacy .fabrica/models.conf — may override" >&2
  echo "  YSTACK_CODEX_MODEL only; it can never lower/change the gate's effort); -m here" >&2
  echo "  keeps precedence over YSTACK_CODEX_MODEL" >&2
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

issue="$1"

# Preflight — fail honestly and early, BEFORE any gh/git/codex side-effect, so a first-time
# adopter gets an actionable "install X" pointer instead of an opaque mid-run `command not
# found`. Required tools (see QUICKSTART.md > Prerequisites):
#   gh    — GitHub CLI (authenticated); reads the issue and posts the verdict comment
#   git   — for the detached temp worktree at HEAD
#   codex — the OpenAI Codex CLI (signed in); forms the manager-review
#   jq    — validates/filters Codex's `--json` event stream without matching agent content
missing=()
for tool in gh git codex jq; do
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
# TARGET's own approved goal (and, for a ystack-self run, still against ystack's own root
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
  echo "       it ships in the ystack control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/north-star.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/north-star.sh
. "$ns_lib"

# Source the shared gh-bound remote-identity selection helper (scripts/lib/gh-remote.sh),
# alongside the resolver. The gate anchors its pin to the gh-BOUND remote's default branch
# (fetched fresh, #102), reusing the SAME remote-selection codex-review.sh uses — factored into
# this shared lib so the two can't diverge. Located under the same control-plane root.
ghr_lib="${control_plane_root}/scripts/lib/gh-remote.sh"
if [ ! -f "$ghr_lib" ]; then
  echo "error: gh-remote helper not found (${ghr_lib})" >&2
  echo "       it ships in the ystack control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/gh-remote.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/gh-remote.sh
. "$ghr_lib"

# Source the shared PARSER for a target-committed models.conf override (P1 fix, #115) —
# mc_parse_target_override reads that file as DATA, never as shell (see scripts/lib/models-conf.sh
# for the full rationale). Located under the same control-plane root.
mc_lib="${control_plane_root}/scripts/lib/models-conf.sh"
if [ ! -f "$mc_lib" ]; then
  echo "error: models-conf helper not found (${mc_lib})" >&2
  echo "       it ships in the ystack control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/models-conf.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/models-conf.sh
. "$mc_lib"

# Source the shared DEGRADED-REVIEW detector (#117) — cd_degraded_reason decides, in ONE place,
# whether a codex run FAILED TO RUN a genuine debate (non-zero exit, or a known code-mode/host
# spawn-failure signal in its output/stderr) vs. genuinely ran clean, so manager-review.sh and
# codex-review.sh can't diverge on what counts as degraded. Located under the same control-plane
# root as the libs above.
cd_lib="${control_plane_root}/scripts/lib/codex-degraded.sh"
if [ ! -f "$cd_lib" ]; then
  echo "error: codex-degraded helper not found (${cd_lib})" >&2
  echo "       it ships in the ystack control-plane repo alongside this script;" >&2
  echo "       restore scripts/lib/codex-degraded.sh, then re-run" >&2
  exit 1
fi
# shellcheck source=scripts/lib/codex-degraded.sh
. "$cd_lib"

# Source the shipped model-tiering defaults (config/models.conf, #109) from this clone's own
# control-plane root ($control_plane_root, resolved above), so the manager-debate gate ALWAYS
# runs at an explicit, known reasoning effort (#110) instead of silently inheriting whatever the
# operator's personal Codex CLI/config happens to resolve to. Fail loudly rather than silently
# debating at unknown effort: a missing or unsourceable config is a restore/setup gap, not
# something to paper over.
models_conf="${control_plane_root}/config/models.conf"
if [ ! -f "$models_conf" ]; then
  echo "error: config/models.conf not found (${models_conf})" >&2
  echo "       it ships in the ystack control-plane repo; restore it (see RESTORE.md), then" >&2
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
if [ -z "${YSTACK_DEBATE_EFFORT:-}" ]; then
  echo "error: YSTACK_DEBATE_EFFORT is unset/empty after sourcing ${models_conf}" >&2
  echo "       the manager-debate gate refuses to run at an unknown reasoning effort; fix the" >&2
  echo "       shipped config (scripts/doctor.sh check (k) diagnoses it), then re-run" >&2
  exit 1
fi

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

# Sanity-resolve local HEAD first — used by the nested-repo guard below and as the local-only
# fallback anchor (below) when there is genuinely no gh repo/remote. The AUTHORITATIVE anchor is
# resolved AFTER the nested-repo guard (#102): it is the gh-bound remote's default-branch commit,
# fetched fresh — NOT raw local HEAD (which authorizes off whatever branch the checkout sits on).
if ! git rev-parse HEAD >/dev/null 2>&1; then
  echo "error: cannot resolve HEAD of the current repo" >&2
  echo "       run this from within the target repo's clone" >&2
  exit 1
fi

# NESTED/EMBEDDED-REPO guard (#98a, confused-deputy) — refuse to authorize off a north star that
# lives in a SEPARATE git repo NESTED inside ANOTHER git work tree. Running the gate from inside
# an untracked/embedded git repo (with its own committed north star) makes `git
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
      echo "       north star in a nested/embedded checkout (its HEAD/.ystack/north-star.md is not" >&2
      echo "       the real target's). Run this from the target's OWN top-level clone, not a" >&2
      echo "       nested/embedded checkout." >&2
      exit 1
    fi
  fi
fi

# ANCHOR RESOLUTION (#102) — pin the gate to the gh-BOUND remote's DEFAULT branch, FETCHED FRESH,
# not raw local HEAD. Before #102 the gate captured `git rev-parse HEAD`, so a north star committed
# on a NON-default (feature) branch could authorize proactive work — the checkout's current branch,
# not the integrated/operator-approved state, was the anchor. The APPROVED north star is the one on
# the target's DEFAULT branch (where reviewed changes land via the loop); "default branch" is a
# proxy for operator approval (approval is the operator's out-of-band act, not a line in the file),
# but it is the best available signal that a committed star is the INTEGRATED one, not a feature
# variant. We resolve the anchor commit into $head_commit (kept as the downstream variable name):
# BOTH the committed north-star read (`git show "${head_commit}:…"`) AND the Codex review worktree
# (`git worktree add --detach … "$head_commit"`) pin to this SINGLE commit, preserving every 98a
# guarantee (committed-only read, placeholder/no-active/symlink/nested guards) — only WHICH commit
# is the anchor changes.
#
# Consumer-specific fallback (round-3): manager-review.sh is gh-BOUND — it reads AND posts a GitHub
# issue. The gate's anchor MUST bind to the SAME repo identity the verdict is posted to, never one
# repo's default branch while commenting on another's issue. So:
#   - gh resolved a repo (guaranteed: the guard above exits if not) AND a configured remote matches
#     that identity → select it (same shared pattern as codex-review.sh; prefer `origin` only if it
#     matches, else e.g. `upstream` in a fork), FETCH FRESH, anchor to the fetched commit.
#   - gh resolved a repo but NO configured remote matches → FAIL clearly. Do NOT fall back to local
#     HEAD: an unbound local anchor while commenting on a gh-bound issue is the wrong-source risk.
#   - only when there is genuinely NO gh repo/remote at all (local-only / greenfield-pre-remote — not
#     reachable here past the gh guard above, but handled for completeness / parity with doctor) do we
#     use the visible local-default/HEAD fallback, LOGGING the line so it is never silent.
#
# `head_commit` = the resolved anchor commit; `anchor_ref` = the private per-run fetch ref to clean
# up on exit (empty when we did not fetch). We register the ref cleanup NOW so an early exit between
# the fetch and the main cleanup trap can't leak it.
head_commit=""
anchor_ref=""
cleanup_anchor_ref() {
  [ -n "$anchor_ref" ] || return 0
  git update-ref -d "$anchor_ref" 2>/dev/null || true
  anchor_ref=""
}
trap cleanup_anchor_ref EXIT

if [ -n "$repo" ]; then
  # gh-BOUND path. Compute gh's canonical identity (host + owner/repo) and select the configured
  # git remote whose URL matches it, via the SHARED helper (identical to codex-review.sh).
  gh_repo_id="$(ghr_gh_repo_id "$repo")"
  selected_remote="$(ghr_select_remote "$gh_repo_id")"
  if [ -z "$selected_remote" ]; then
    echo "error: gh resolved this repo as ${repo}, but no configured git remote matches that identity." >&2
    echo "       The manager-debate gate anchors its authorization to the gh-BOUND remote's default" >&2
    echo "       branch (fetched fresh) — it will NOT fall back to local HEAD while posting the verdict" >&2
    echo "       to ${repo}'s issue (an unbound local anchor on a gh-bound issue is the wrong source)." >&2
    echo "       Add the matching remote (e.g. 'git remote add upstream <url>' for a fork, or point" >&2
    echo "       'origin' at ${repo}), then re-run." >&2
    exit 1
  fi
  # EFFECTIVE-URL IDENTITY GATE (#102 fix A, FAIL-CLOSED). Selection matched the remote by URL, but
  # the fetch below goes BY NAME — which applies any `url.<other>.insteadOf`, so the URL git actually
  # contacts can be a DIFFERENT repo. Before fetching (and anchoring the gate off it), assert the
  # EFFECTIVE fetch URL is a NON-EMPTY GitHub id EQUAL to gh's: a cross-repo GitHub substitution, a
  # local-path/file://-substitution, or any transport we can't PROVE is gh's repo all FAIL closed
  # (round-2 — empty is no longer trusted; a deliberate local mirror needs YSTACK_ALLOW_LOCAL_MIRROR=1).
  # So the gate never reads a source it can't prove is the repo the verdict posts to.
  if ! ghr_assert_effective_identity "$selected_remote" "$gh_repo_id"; then
    exit 1
  fi
  # Resolve the default branch NAME AUTHORITATIVELY from gh — the SAME binding the verdict posts to
  # (#102 round-2 fix B): `gh repo view "$repo" --json defaultBranchRef`. NOT the stale/spoofable
  # local `refs/remotes/<remote>/HEAD` symref, and NOT `ls-remote` off the selected remote (which an
  # insteadOf could redirect) — the default-branch NAME is an AUTHORIZATION input (which branch's
  # committed north star authorizes the gate), so it must be as authoritative as the repo identity.
  # We use only the NAME here — never a commit — and FETCH FRESH from the validated remote below.
  # If gh can't resolve it on this gh-bound run, FAIL closed (no local-symref authorization).
  default_branch="$(ghr_gh_default_branch "$repo")"
  if [ -z "$default_branch" ]; then
    echo "error: gh could not resolve the default branch of ${repo} (gh repo view --json defaultBranchRef)." >&2
    echo "       The manager-debate gate anchors its authorization to that branch's freshly-fetched" >&2
    echo "       commit and takes the branch NAME from gh — the SAME binding the verdict posts to —" >&2
    echo "       never a stale/spoofable local refs/remotes/${selected_remote}/HEAD symref. It will" >&2
    echo "       NOT fall back to a local source on a gh-bound run. Confirm 'gh repo view ${repo}'" >&2
    echo "       works (auth + network), then re-run." >&2
    exit 1
  fi
  # FETCH FRESH into a PRIVATE, PER-RUN-UNIQUE ref we own (under refs/manager-review/<PID>/), via the
  # shared ghr_fetch_default_commit (the generalization of codex-review.sh's per-run PR/base fetch).
  # This is what makes the anchor the INTEGRATED commit, not a stale local remote-tracking cache:
  # `refs/remotes/<selected>/HEAD` (and its tracking branch) may be arbitrarily out of date, so we go
  # to the remote for the current tip. The helper force-updates ONLY our own per-run ref and never a
  # remote-tracking ref, so the operator's `<remote>/<default>` tracking state is untouched.
  anchor_ref="refs/manager-review/$$/anchor"
  if ! head_commit="$(ghr_fetch_default_commit "$selected_remote" "$default_branch" "$anchor_ref")" \
     || [ -z "$head_commit" ]; then
    # cleanup_anchor_ref (EXIT trap) still deletes the ref if a partial fetch created it.
    echo "error: failed to fetch the default branch '${default_branch}' from remote '${selected_remote}' (${repo})." >&2
    echo "       The manager-debate gate anchors to that branch's freshly-fetched commit. Confirm network" >&2
    echo "       access and that the branch exists on the remote, then re-run." >&2
    exit 1
  fi
else
  # LOCAL-ONLY / GREENFIELD fallback (no gh repo/remote at all). Not reachable past the gh guard
  # above for manager-review, but kept for completeness. Prefer the LOCAL default branch's commit if
  # resolvable; else raw local HEAD. VISIBLE (never silent) — the operator must see that the gate is
  # authorizing off local state, not an integrated/gh-bound remote.
  local_default="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  head_commit="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head_commit" ]; then
    echo "error: cannot resolve HEAD of the current repo" >&2
    echo "       run this from within the target repo's clone" >&2
    exit 1
  fi
  echo "note: no gh-bound repo/remote resolved — anchoring the gate to LOCAL ${local_default:-HEAD} (${head_commit})." >&2
  echo "      this local fallback applies only to a genuinely local/greenfield target with no GitHub remote." >&2
fi

# Resolve the north star FOR THE TARGET, then read its COMMITTED content pinned to the SAME
# commit ($head_commit) the review operates on — NEVER a free-floating later HEAD re-lookup
# (debate GAP, #98a). The north star is an autonomy-authorization artifact: an unreviewed
# LOCAL worktree edit to the target's north-star file must NOT silently redirect the proactive
# gate, so a star that exists ONLY as an uncommitted working-tree edit does NOT authorize —
# while a star COMMITTED at $head_commit STILL authorizes even if the working-tree copy is later
# deleted or modified. We read `git show "$head_commit:<path>"`, which resolves <path> relative
# to the repo ROOT regardless of the cwd (subdir vs. root) and reads only committed content, so
# the gate's goal matches the clean detached worktree Codex reviews at the same commit and is
# immune to the dirty working tree.
#
# ns_resolve tells us WHICH source applies via its IDENTITY logic — is this a ystack-self run
# (root NORTH_STAR.md) or a normal target (.ystack/north-star.md, or the older
# .fabrica/north-star.md as a legacy fallback)? We do NOT use its LOCAL-vs-UNSET result to gate
# authorization, because ns_resolve stats the WORKING-TREE file, so a
# committed-but-worktree-deleted star would read UNSET there. Instead, for a normal target the
# authoritative authorize test is whether a north-star file exists AT $head_commit — the new
# .ystack/ path is tried first, and the legacy .fabrica/ path only when the new one is absent,
# so targets that have not renamed yet keep working.
ns_result="$(ns_resolve "$PWD" || true)"
ns_kind="${ns_result%% *}"
north_star=""
if [ "$ns_kind" = "YSTACK_SELF" ]; then
  # ystack-self run: the control-plane root NORTH_STAR.md is ystack's own real approved goal
  # (it legitimately carries the shipped-default marker — this branch is EXEMPT from the
  # placeholder-FAIL). cwd IS the control-plane checkout, so read the root star COMMITTED at the
  # same $head_commit for the same committed-state guarantee.
  #
  # AUTHORIZATION lives HERE (round-3 [P2]): ns_resolve classifies YSTACK_SELF by git-structural
  # identity (shared git common-dir, so a linked worktree of the control plane counts too; a
  # top-level path match is also accepted) UNCONDITIONALLY — it does NOT check whether NORTH_STAR.md
  # is committed — so this branch is the
  # authorization gate. It must require a COMMITTED root star and FAIL cleanly if there is none: a
  # missing committed root FAILs, it does NOT fall back to a per-target star file (that fallback
  # would let a stray committed `.ystack`/legacy-`.fabrica` star mis-steer ystack-self). Do the committed
  # read FIRST so an ABSENT root gives the accurate "not committed at HEAD" message — not the
  # symlink message. `if ! …="$(git show …)"` (a condition context) never trips `set -e`: an
  # absent path makes `git show` exit non-zero → the FAIL branch runs cleanly.
  if ! north_star="$(git show "${head_commit}:NORTH_STAR.md" 2>/dev/null)" || [ -z "$north_star" ]; then
    echo "error: NORTH_STAR.md is not committed at HEAD (${head_commit}) in the control plane" >&2
    echo "       ns_resolve classified this run as ystack-self by git-structural identity; the manager-debate" >&2
    echo "       gate reads COMMITTED state and does NOT fall back to .ystack/north-star.md. Commit" >&2
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
else
  # A normal target: the authorize test is committed existence, independent of the working
  # tree — a committed star authorizes even if the worktree copy was deleted/modified, and a
  # worktree-only edit that is NOT committed falls through to the UNSET FAIL below.
  #
  # PATH FALLBACK (the ystack rename): try the new `.ystack/north-star.md` first; only when
  # that path is ABSENT at $head_commit, fall back to the legacy `.fabrica/north-star.md`, so
  # targets that have not renamed yet keep working. A present-but-broken new-path entry (an
  # empty file, or a symlink) FAILs loudly below — it never silently falls back.
  star_relpath=".ystack/north-star.md"
  if ! north_star="$(git show "${head_commit}:.ystack/north-star.md" 2>/dev/null)"; then
    if north_star="$(git show "${head_commit}:.fabrica/north-star.md" 2>/dev/null)"; then # legacy fallback
      star_relpath=".fabrica/north-star.md" # legacy fallback
    else
      north_star=""
    fi
  fi
  if [ -n "$north_star" ]; then
    # A committed star at $head_commit → LOCAL.
    #
    # SYMLINK guard (round-2 FIX 4) — BEFORE the marker check: reject a committed north star
    # stored as a SYMLINK. `git show <commit>:<path>` on a symlink returns the link TARGET-PATH
    # string (which the non-empty check above accepts), so without this guard the gate would run
    # the marker check against a path string and could AUTHORIZE off it, diverging from the real
    # file Codex reviews. Assert the committed entry is a regular blob (100644/100755) first.
    if ! ns_committed_is_regular_file "$PWD" "$head_commit" "$star_relpath"; then
      echo "error: ${repo}'s committed ${star_relpath} at HEAD (${head_commit}) is a SYMLINK —" >&2
      echo "       the committed north star must be a regular file, not a symlink (a symlink makes the" >&2
      echo "       gate read the link's target-path string, not the star's content). Replace it with a" >&2
      echo "       regular file, commit it, and re-run" >&2
      exit 1
    fi
    #
    # A LOCAL committed star still carrying the shipped-default placeholder marker is an
    # un-replaced template — NOT a real approved goal — so FAIL before any verdict. (YSTACK_SELF
    # above is exempt; the marker-FAIL is keyed to LOCAL only.)
    #
    # The check goes through ns_has_shipped_default_marker (shared with doctor.sh (h)), which
    # SCOPES the match to the ACTIVE-entry region, matches the marker WHITESPACE/CASE-
    # INSENSITIVELY, and accepts BOTH marker strings — the current `ystack-shipped-default` and
    # the legacy `fabrica-shipped-default` — so an un-replaced template FAILs no matter which
    # marker it shipped with. Scoping stops the marker's mentions in the template PROSE from
    # wrongly FAILing a correctly-replaced star (marker cleared from the active heading, still
    # named in prose); the insensitive match stops a placeholder whose marker is spaced/cased/
    # split differently from wrongly AUTHORIZING. Feed the committed content over stdin (`-`)
    # so we never touch a working-tree file.
    if printf '%s' "$north_star" | ns_has_shipped_default_marker -; then
      echo "error: ${repo}'s ${star_relpath} is still the shipped placeholder (carries the" >&2
      echo "       '<!-- ystack-shipped-default -->' marker — the legacy" >&2
      echo "       legacy '<!-- fabrica-shipped-default -->' marker counts too) — the manager-debate gate" >&2
      echo "       will not debate against an un-replaced template. Replace it with your own north" >&2
      echo "       star, remove the marker from the active heading line, commit it, and approve it," >&2
      echo "       then re-run. See reviewer/manager-review.md > north star" >&2
      exit 1
    fi
  else
    # No committed north star for this target: either UNSET/EMPTY/NOREPO from the resolver, or a
    # north-star file that exists ONLY as an uncommitted working-tree edit (not at
    # $head_commit). None authorizes proactive work — FAIL with an actionable pointer BEFORE
    # invoking Codex, so the operator sets and COMMITS a north star rather than debating an empty
    # (or uncommitted, unreviewed) goal.
    echo "error: no committed north star resolved for ${repo} (resolver: ${ns_kind}) — .ystack/north-star.md is" >&2
    echo "       not committed at HEAD (${head_commit}), and neither is the legacy .fabrica/north-star.md." >&2
    echo "       The manager-debate gate reads COMMITTED target state — an uncommitted local edit" >&2
    echo "       does not authorize proactive work. Set one up:" >&2
    echo "         copy '${control_plane_root}/templates/.ystack/north-star.md' into the target" >&2
    echo "         as .ystack/north-star.md, replace the placeholder with your own direction," >&2
    echo "         remove the '<!-- ystack-shipped-default -->' marker from the active heading," >&2
    echo "         then commit and approve it — see reviewer/manager-review.md > north star." >&2
    echo "       (setup-target-repo.sh only creates the loop labels; it does NOT seed the star.)" >&2
    exit 1
  fi
fi

# NO-ACTIVE-ENTRY FAIL (round-3 [P2]) — a committed north star with NO valid `status: active`
# heading does NOT authorize proactive work. We reach here only on an AUTHORIZED source (the
# YSTACK_SELF or LOCAL committed branch above populated $north_star; UNSET/placeholder/symlink
# already exited). But "the file exists and is not the shipped placeholder" is NOT enough:
# proactive work is authorized ONLY by an approved ACTIVE north star, and a target that committed
# its north-star file (or the control plane its NORTH_STAR.md) with the `status: active`
# heading mistyped/removed has NO active goal — debating Codex against that goalless file would
# authorize work the operator never steered. So require a NON-EMPTY active region from the SAME
# committed content already read ($north_star), via the shared ns_active_region helper (identical
# to doctor's (h) check and to the placeholder scoping), fed over stdin (`-`). This sits ALONGSIDE
# the UNSET-FAIL (no committed star) and the placeholder-FAIL (committed but un-replaced template),
# closing the goalless-debate gap between them. doctor.sh diagnoses the same condition as a WARN
# (user-directed work stays valid; only the proactive gate FAILs).
if [ -z "$(printf '%s' "$north_star" | ns_active_region - | head -n1 || true)" ]; then
  echo "error: no active 'status: active' north-star entry in the committed north star for ${repo}" >&2
  echo "       (resolver: ${ns_kind}) at HEAD (${head_commit}). The manager-debate gate authorizes" >&2
  echo "       proactive work ONLY against an approved ACTIVE north star, and this committed file has" >&2
  echo "       no 'status: active' heading (e.g. the marker was mistyped or removed when editing the" >&2
  echo "       template). Set an active entry (a heading carrying 'status: active'), commit it, and" >&2
  echo "       approve it, then re-run. See reviewer/manager-review.md > north star." >&2
  exit 1
fi

# Pull the issue title + body + the comment thread — the proposal Codex debates, PLUS the
# prior debate. On a REFINE rerun, yshifu edits the issue and replies in an issue comment
# (issue-as-bus), so the comment thread carries the prior Codex verdicts and yshifu's
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
# committed): a detached worktree dir, the Codex output file, a captured-stderr file, and (#119)
# a captured stdout JSONL-event file (`codex exec --json`), distinct from the `-o "$tmp"`
# verdict-answer file. All four get a fresh mktemp path each run, so a stale worktree entry from
# a hard-killed previous run never collides with — or blocks — the `git worktree add` below;
# that is why no global `git worktree prune` is needed (and we avoid one so unrelated operator
# worktrees are never touched).
worktree="$(mktemp -d)"
tmp="$(mktemp)"
stderr_tmp="$(mktemp)"
stdout_tmp="$(mktemp)"

# Clean up on EVERY exit (success or failure): remove the temp worktree, the temp output file,
# AND the private per-run anchor ref (#102) if the gh-bound fetch created one. `git worktree
# remove --force` drops the worktree even at a detached head; the rm -rf fallback covers the case
# where it was never added. cleanup_anchor_ref (defined above, idempotent) deletes only OUR own
# refs/manager-review/<PID>/anchor, never a concurrent run's ref or a remote-tracking ref. This
# REPLACES the earlier `trap cleanup_anchor_ref EXIT`, so we fold the ref cleanup in here.
cleanup() {
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  rm -f "$tmp" "$stderr_tmp" "$stdout_tmp"
  cleanup_anchor_ref
}
trap cleanup EXIT

# Add a DETACHED, throwaway worktree at the current HEAD, isolated from the operator's
# checkout. Codex reviews HERE — so it sees exactly the tracked content at HEAD (the right
# thing to ground the issue review), never untracked/ignored files (`.env`, secrets, WIP) or
# uncommitted state, and never mutates the operator's branch / index / working tree.
git worktree add --detach "$worktree" "$head_commit"

# Per-target override: if the TARGET repo has committed a .ystack/models.conf (same
# format/keys as config/models.conf — see templates/.ystack/models.conf; the older
# legacy .fabrica/models.conf is still honored as a fallback when the new path is absent, so targets
# that have not renamed yet keep working), PARSE it (never source/eval it — see
# scripts/lib/models-conf.sh for the full P1 rationale) AFTER the shipped defaults, so it can
# override the PRODUCER/MODEL keys for this target only. Read it via `git show
# "${head_commit}:<path>"` — the SAME EXACT anchored commit ($head_commit) already resolved
# above for the committed north-star reads and the worktree checkout — never a `<`-redirect
# from the checked-out worktree path (P2 fix, adversarial review of PR #115): a target could
# commit its override AS A SYMLINK to an arbitrary operator-local file, and an `[ -f ]` check
# on that checked-out path follows the symlink, so a redirect from it would read and parse the
# POINTED-TO file's content — a charset-valid `YSTACK_CODEX_MODEL=<value>` line in that file
# would then leak into the PUBLIC issue comment header (`reviewer: <model> @ <effort>`
# below) — a narrow info-leak of an arbitrary local file (the device/FIFO DoS variant was already
# blocked by `[ -f ]`). `git show <commit>:path` never dereferences a symlink: for a symlinked
# path it returns the link TARGET-PATH string itself (as blob content), which fails the parser's
# charset check below and is silently ignored — mirroring codex-review.sh's identical
# `git show`-based read of this same file. Absence is normal (most targets have no override;
# `git show` exits non-zero and we skip). GATE keys (YSTACK_DEBATE_EFFORT) are recognized by the
# parser but never applied from a target override — a target can never lower/change its own
# manager-debate gate — mc_parse_target_override instead warns (stderr) and sets
# MC_TARGET_OVERRIDE_GATE_WARNING, folded into the posted issue comment below.
MC_TARGET_OVERRIDE_GATE_WARNING=0
if target_models_conf_content="$(git show "${head_commit}:.ystack/models.conf" 2>/dev/null)" \
   || target_models_conf_content="$(git show "${head_commit}:.fabrica/models.conf" 2>/dev/null)"; then # legacy fallback
  # Here-string, NOT a pipe: the rightmost command of a pipe runs in a SUBSHELL under bash 3.2 (no
  # `lastpipe`), which would silently discard the YSTACK_* assignments the parser makes here.
  mc_parse_target_override <<<"$target_models_conf_content"
fi

# Resolve the effective Codex model: the existing -m CLI flag keeps precedence over config (per
# #110) — it is only missing when the operator omitted -m, in which case we fall back to
# YSTACK_CODEX_MODEL (empty by default, meaning "inherit the operator's own Codex CLI/config
# default"; a target's committed models.conf override, parsed just above, may have changed it).
# model_display feeds the resolved-config echo below so every debate documents what gated it,
# even when nothing was explicitly pinned (shown as "operator-default").
effective_model="$model"
if [ -z "$effective_model" ]; then
  effective_model="${YSTACK_CODEX_MODEL:-}"
fi
model_display="${effective_model:-operator-default}"

# Build the manager-reviewer prompt: the role + the current north star + the issue under
# debate + an instruction to read the repo to ground the judgment, asking for a structured
# PROCEED / REFINE / DROP verdict with reasoning and any gap yshifu missed. This is a
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
You are the cross-vendor MANAGER reviewer for an autonomous coding team. yshifu (a Claude
manager) has DRAFTED the GitHub issue below as a *proactive* proposal toward the team's
current north star. Your job is to debate whether this issue is worth raising NOW — not to
review code, and not to rubber-stamp it. You are VETO-ONLY: you never approve, label, edit
the issue, or merge anything; you only give a verdict that yshifu weighs. The team proceeds
ONLY on consensus (you and yshifu both agree), and DEFAULT-DROPS on no consensus, so do not
invent busywork: if the issue does not clearly serve the north star, say so.

== CURRENT NORTH STAR (the target's committed north star) ==
%s

== PROPOSED ISSUE #%s ==
Title: %s

%s

== ISSUE COMMENT THREAD (the debate so far, oldest first) ==
On a rerun this carries any prior verdicts of yours and yshifu's refinement replies (the
issue is the message bus). Read it: do not just repeat a prior objection if yshifu already
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

GAP YSHIFU MISSED: anything yshifu overlooked — a risk, a dependency, a simpler path, a
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
#
# `-c model_reasoning_effort="$YSTACK_DEBATE_EFFORT"` is ALWAYS passed (#110) — the
# manager-debate gate is a max-capability decision point (spend-by-leverage), never
# class-routed down, so this raises it from whatever effort the operator's Codex config
# happened to default to (often `low`) to the resolved config's explicit value. `-m` is passed
# only when a model was actually resolved (CLI flag or YSTACK_CODEX_MODEL); empty means
# "inherit Codex's own default model".
review_cmd=(codex exec -C "$worktree" --json -c sandbox_mode="read-only" -c model_reasoning_effort="$YSTACK_DEBATE_EFFORT" -o "$tmp")
if [ -n "$effective_model" ]; then
  review_cmd+=(-m "$effective_model")
fi

# #117/#119 — run with errexit MOMENTARILY OFF so a non-zero Codex exit is caught HERE and can
# still post the explicit DEGRADED marker. `pipefail` makes `$?` reflect Codex through the stdin
# pipe. `--json` makes stdout a JSONL event stream; stderr is the remaining raw runtime/tracing
# channel. Both are captured with bash-3.2-portable redirects and re-emitted after Codex exits.
set +e
printf '%s' "$prompt" | "${review_cmd[@]}" - >"$stdout_tmp" 2>"$stderr_tmp"
codex_rc=$?
set -e
cat "$stdout_tmp"
cat "$stderr_tmp" >&2

# #117/#119 DEGRADED DETECTION — the shared detector requires: exit 0; fully-understood JSONL
# ending in an agent message + `turn.completed`; at least one successful command_execution as
# positive inspection evidence; no fatal/failed event or host-failure text in a trusted error
# field; and no host-failure signal in raw stderr. It excludes JSON agent/command payloads and
# NEVER sees `$tmp`, closing both the empty-inspection pass and quoted-phrase false positive.
if degraded_reason="$(cd_degraded_reason "$codex_rc" "$stdout_tmp" "$stderr_tmp")"; then
  echo "error: Codex manager-review DEGRADED — ${degraded_reason}. NOT posting a PROCEED/REFINE/DROP verdict." >&2
  degraded_body="$(
    echo "## Codex manager-reviewer — DEGRADED, REVIEW DID NOT RUN (cross-vendor, read-only)"
    echo
    echo "VERDICT: DEGRADED (never PROCEED / REFINE / DROP — this run did not genuinely debate the issue)"
    echo "reviewer: ${model_display} @ ${YSTACK_DEBATE_EFFORT}"
    echo
    echo "**This Codex run FAILED TO RUN a genuine debate on issue #${issue}. Treat this as NO"
    echo "consensus — never as PROCEED. yshifu must not advance on the strength of this comment.**"
    echo
    echo "Reason: ${degraded_reason}."
    echo
    echo "_Posted by \`manager-review.sh\` (#117/#119 hardening): a degraded/non-substantive Codex_"
    echo "_run is surfaced loudly instead of silently posted as a real verdict. The \`-o\` verdict_"
    echo "_answer is NOT shown here — it is untrustworthy on a degraded run, and codex's raw_"
    echo "_output is untrusted content that must never be embedded verbatim where it could be_"
    echo "_mistaken for a real review marker. JSONL is intentionally omitted because it contains_"
    echo "_agent/command/repository payloads; only bounded, neutralized raw stderr appears below._"
    echo "_Fix the underlying codex/toolchain issue, then re-run_"
    echo "_\`scripts/manager-review.sh ${issue}\`._"
    echo
    echo '```'
    echo "-- codex JSONL events --"
    echo "> (omitted: may contain private agent, command, and repository payloads)"
    echo
    echo "-- codex stderr (diagnostic; last ${cd_snippet_max_lines} lines, sanitized) --"
    cd_sanitize_snippet "$stderr_tmp"
    echo '```'
  )"
  echo "$degraded_body"
  printf '%s\n' "$degraded_body" | gh issue comment "$issue" --repo "$repo" --body-file - || \
    echo "error: additionally failed to post the DEGRADED marker comment to issue #${issue}" >&2
  exit 1
fi

# NON-EMPTY GUARD (#119 P3 fix — parity with codex-review.sh). The degraded-detection block above
# already caught a non-zero codex exit and any known spawn-failure signal on the diagnostic
# streams; this guards the REMAINING vacuous case — a zero exit with an empty (or
# whitespace-only) `-o` capture — which would otherwise post a header-only issue comment with no
# PROCEED/REFINE/DROP verdict at all. Refuse to post when there is no verdict content. The
# cleanup trap still runs on this exit (it is an EXIT trap), so the temp worktree, output files,
# and per-run anchor ref are removed.
if ! grep -q '[^[:space:]]' "$tmp"; then
  echo 'error: Codex produced no verdict output; not posting' >&2
  exit 1
fi

# Compose the issue comment: a short header marking it the cross-vendor manager-reviewer,
# then Codex's verdict VERBATIM. The header is yshifu's prefix — clearly separate from
# Codex's verbatim body — so this stays read-only / comments-only / verbatim (no Claude
# rewriting). Build it into a second temp file so we can both echo it to stdout (the
# operator sees the verdict in-session) and post it as the issue comment. A
# `reviewer: <model> @ <effort>` line records the RESOLVED config (#110) — model and reasoning
# effort actually applied, after CLI/-m > YSTACK_CODEX_MODEL and any per-target
# models.conf override — so every debate documents what gated it on the record, and
# personal-config drift (e.g. a stray operator default) is visible in the issue history. If the
# target's override tried to set YSTACK_DEBATE_EFFORT (rejected by mc_parse_target_override,
# #115 P1 fix), a visible warning line is folded in here too — never a silent ignore.
comment="$(mktemp)"
# Re-arm the trap to also remove this second temp file. We re-`git worktree remove` the
# worktree here too (replacing, not appending to, the EXIT trap) so the worktree cleanup is
# not lost; it is idempotent / harmless if the worktree is already gone. cleanup_anchor_ref is
# folded in so the per-run anchor ref (#102) is dropped on exit as well (kept alive until now so
# the fetched anchor commit stays reachable through the worktree add above).
trap 'git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"; rm -f "$tmp" "$stderr_tmp" "$stdout_tmp" "$comment"; cleanup_anchor_ref' EXIT
{
  echo "## Codex manager-reviewer (cross-vendor, read-only)"
  echo
  echo "reviewer: ${model_display} @ ${YSTACK_DEBATE_EFFORT}"
  if [ "$MC_TARGET_OVERRIDE_GATE_WARNING" = "1" ]; then
    echo "warning: target override attempted to set gate effort — ignored"
  fi
  echo
  echo "_Posted verbatim by \`manager-review.sh\` (\`codex exec --json\`, sandbox forced read-only, debating issue #${issue} against the current north star). Comments only — veto-only: Codex never labels \`ready\`, edits the issue, or merges. Proceed only on consensus._"
  echo
  cat "$tmp"
} >"$comment"

# Echo to stdout, then post the SAME content as the issue comment (the durable record).
cat "$comment"
gh issue comment "$issue" --repo "$repo" --body-file "$comment"
