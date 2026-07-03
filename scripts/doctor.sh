#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — read-only restore self-check for Fabrica.
#
# RESTORE.md only proves a rebuild by running a full live loop; this answers the
# faster question "is the team reconstructable from HERE?" — a restorer can have
# every file back yet still be blocked on a missing credential, an uninstalled
# /faber command, or absent loop labels. doctor surfaces those gaps in seconds.
#
# Beyond presence/PATH it also probes whether the setup actually WORKS for a real
# run, so a green doctor can't overstate readiness: it verifies Codex is signed in
# (not merely on PATH), warns when the TARGET's north star (resolved via the shared
# resolver — the target's .fabrica/north-star.md, or the control-plane NORTH_STAR.md
# on a Fabrica-self run) is unset or still the shipped Fabrica-self default, and — in
# the target-repo path — checks the target has PR-triggered CI (the hard merge gate)
# and reports (advisory only) whether a CLAUDE.md "Stack & commands" override is
# present (commands are auto-discovered, so it is optional).
#
# It is STRICTLY READ-ONLY: it never creates, edits, or deletes anything (and the
# optional label check delegates to setup-target-repo.sh's --check mode, which is
# itself read-only). Every check prints a single `pass:`/`warn:`/`fail:` line.
#
# WARN vs FAIL: a `fail:` is a real blocker and makes doctor exit non-zero (so it
# stays usable as a CI/pre-flight gate); a `warn:` flags a likely-wrong-but-not-
# blocking condition (e.g. an unreplaced north star) and does NOT by itself change
# the exit code. doctor exits non-zero ONLY when at least one check failed.
#
# Checks:
#   (a) ~/.claude/commands/faber.md exists AND contains THIS clone's resolved
#       control-plane path — i.e. /faber points at this clone (same path
#       derivation install.sh uses).
#   (b) gh is present and authenticated.
#   (c) claude (Claude Code CLI) is on PATH — the team runs in a Claude Code session.
#   (d) codex is on PATH AND signed in (auth probed via `codex login status` when that
#       subcommand exists; degrades to a PATH-only pass with a note if it doesn't).
#   (e) jq is on PATH — required by scripts/merge-pr.sh to parse gh's CI-check JSON.
#   (f) every file in ci/required-files.txt is present on disk (the manifest is
#       read live — the list is never duplicated here).
#   (h) the TARGET's north star (resolved via scripts/lib/north-star.sh from the cwd —
#       consistent with the manager-review.sh gate) is set and its ACTIVE entry is not
#       still the shipped Fabrica-self default (WARN). Detected by a stable MARKER
#       (`<!-- fabrica-shipped-default -->`) on the active-entry heading line, NOT a
#       north-star phrase — so no transition needs a doctor edit (the marker rides to the
#       new default; adopters remove it when they set their own star) and the whole-file doc
#       mentions of the token never false-warn. UNSET (non-empty target, no committed star),
#       EMPTY (commit-less), and NOREPO all WARN (not FAIL) — the gate FAILs, doctor only
#       diagnoses. Also WARNs if there is no `status: active` entry (a malformed file). doctor
#       reads the WORKING-TREE copy (diagnostic) and NOTES if it differs from HEAD, since the
#       gate reads committed state. When a target arg is given, the local read is attributed
#       only if the cwd's slug matches it (else WARN that it wasn't checked).
#   (g) optional <owner>/<repo> arg → delegate to setup-target-repo.sh --check to
#       verify the loop labels exist and match.
#   (i) [target-repo path] the target has PR-triggered CI (the hard merge gate).
#       Detected from the OBSERVED checks on RECENTLY-UPDATED PRs (ground truth): check-runs
#       / commit statuses on a recent PR's HEAD. This covers GitHub Actions AND external
#       CI (CircleCI/Buildkite/Jenkins) uniformly — anything that posts a check on a PR
#       head — with no false pass from disabled/inactive workflow files. It is
#       PR-SPECIFIC: a repo whose CI runs only on pushes to the default branch — never on
#       PRs — has no gate for merge-pr.sh, so doctor must NOT count default-branch checks.
#       It is also RECENCY-SCOPED: only PRs updated within the last ~90 days count, so a
#       repo that HAD CI but since removed it (old closed PRs still carry check-runs) no
#       longer false-passes on those stale historical checks. No checks (or no recent PRs)
#       → WARN, not FAIL: merge-pr.sh's `gh pr checks` is the real enforcement, so doctor
#       flags the risk rather than hard-failing a valid external-CI repo (or one with no
#       recent PRs). Enumerating *active* Actions workflows via the Actions API is a
#       deferred enhancement (a follow-up issue).
#   (j) [target-repo path] ADVISORY: whether the target has a filled-in CLAUDE.md
#       "Stack & commands" override (exists, no `<cmd>` placeholders, AND has the section).
#       Informational only — the coder auto-discovers install/test/build commands from the
#       repo's CI workflows and standard manifests, so a CLAUDE.md is an OPTIONAL override
#       (pin/disambiguate a non-standard toolchain), NOT a prerequisite. WARN flags its
#       absence/placeholders as a heads-up, never as a blocker.
#
# Usage:
#   scripts/doctor.sh                 run the clone-local checks against this clone
#   scripts/doctor.sh <owner>/<repo>  also run the target-repo checks for that repo

usage() {
  echo "usage: $0 [<owner>/<repo>]" >&2
  echo "  read-only restore self-check: /faber install, gh auth, claude/codex (auth)/jq on" >&2
  echo "  PATH, restore-critical files, and NORTH_STAR not still the shipped default. Prints" >&2
  echo "  a pass/warn/fail line per check; exits non-zero only on a fail (warnings never do)." >&2
  echo "  Pass <owner>/<repo> to also verify that repo's loop labels and PR-triggered CI," >&2
  echo "  plus an advisory note on whether an optional CLAUDE.md command override is present." >&2
}

# Accept at most one positional arg (the optional <owner>/<repo>). Reject -h/--help
# with usage, and anything else with an error.
target_repo=""
if [ "$#" -gt 1 ]; then
  echo "error: too many arguments" >&2
  usage
  exit 1
fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
    *) target_repo="$1" ;;
  esac
fi

# Resolve THIS clone's repo root from the script's own location, following symlinks
# so the derived path is the real clone directory even if doctor.sh is symlinked.
# This MUST match install.sh's derivation so check (a)'s expected path is exactly the
# one install.sh would have written into faber.md.
script_path="$0"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
repo_root="$(cd "$(dirname "$script_path")/.." && pwd -P)"

# Source the shared north-star resolver (scripts/lib/north-star.sh) so check (h) resolves the
# TARGET's north star the SAME way manager-review.sh's gate does (#98a) — the target's
# `.fabrica/north-star.md`, or the control-plane root NORTH_STAR.md on a Fabrica-self run —
# rather than always reading the control plane's own NORTH_STAR.md. It lives at the fixed,
# install-location-independent path under this clone.
#
# GUARD the source (#98a robustness): doctor is a restore self-check, so the lib may be exactly
# what's MISSING on a partial restore. An unconditional `. "$ns_lib"` would abort doctor under
# `set -e` BEFORE check (f) can report the missing restore-critical file and before the summary
# prints — the opposite of a self-check's job. So we source it only if present, record whether we
# did, and have check (h) report a missing lib as a `fail:` line (the resolver-backed check can't
# run without it) while (f) independently flags it in the manifest and the summary still prints.
ns_lib="$repo_root/scripts/lib/north-star.sh"
ns_lib_ok=0
if [ -f "$ns_lib" ]; then
  # shellcheck source=scripts/lib/north-star.sh
  . "$ns_lib" && ns_lib_ok=1
fi

# Source the shared gh-bound remote-identity helper too (scripts/lib/gh-remote.sh), so check (h)
# diagnoses the SAME anchored source the gate authorizes on (#102): the gh-BOUND remote's
# default-branch committed state, fetched fresh. Guarded like the resolver — a partial restore may
# be missing exactly this file; (h) then falls back to the visible local-default/HEAD anchor (a
# diagnostic may legitimately run local-only), and check (f) independently flags the missing file.
ghr_lib="$repo_root/scripts/lib/gh-remote.sh"
ghr_lib_ok=0
if [ -f "$ghr_lib" ]; then
  # shellcheck source=scripts/lib/gh-remote.sh
  . "$ghr_lib" && ghr_lib_ok=1
fi

passed=0
warned=0
failed=0

# Record a check result and print one aligned pass/warn/fail line. First arg: 0 = pass,
# non-zero = fail. Remaining args: the human-readable check description.
report() {
  local ok="$1"
  shift
  if [ "$ok" -eq 0 ]; then
    passed=$((passed + 1))
    echo "pass: $*"
  else
    failed=$((failed + 1))
    echo "fail: $*"
  fi
}

# Record a non-blocking warning. WARN never increments `failed`, so warnings alone
# leave the exit code at 0 — they flag a likely-wrong-but-not-blocking condition.
report_warn() {
  warned=$((warned + 1))
  echo "warn: $*"
}

# (a) /faber points at this clone -------------------------------------------------
faber_cmd="$HOME/.claude/commands/faber.md"
# Match a path BOUNDARY ("$repo_root/"), not a bare prefix: the generated command
# embeds paths like "<root>/manager/CLAUDE.md", so the trailing slash anchors the
# match to a path component and stops a clone whose path is a prefix of another's
# (e.g. /work/fabrica vs an installed /work/fabrica-old) from false-passing.
if [ ! -f "$faber_cmd" ]; then
  report 1 "(a) /faber command installed at $faber_cmd (missing — run scripts/install.sh)"
elif grep -qF -- "$repo_root/" "$faber_cmd"; then
  report 0 "(a) /faber command points at this clone ($repo_root)"
else
  report 1 "(a) /faber command does not reference this clone ($repo_root) — run scripts/install.sh from here"
fi

# (b) gh present and authenticated ------------------------------------------------
# When a target repo is given, scope the probe to it: `gh repo view "$repo"` verifies
# auth AND access to exactly that repo (mirroring setup-target-repo.sh), so an unrelated
# stale host/account in gh's config can't fail the preflight when target access is fine.
# With no target there's nothing to scope to, so fall back to the general auth status.
if ! command -v gh >/dev/null 2>&1; then
  report 1 "(b) gh present and authenticated (gh not on PATH — install the GitHub CLI)"
elif [ -n "$target_repo" ]; then
  if gh repo view "$target_repo" >/dev/null 2>&1; then
    report 0 "(b) gh authenticated with access to $target_repo"
  else
    report 1 "(b) gh present but cannot access $target_repo — run 'gh auth login' (and confirm you can see it)"
  fi
elif gh auth status >/dev/null 2>&1; then
  report 0 "(b) gh present and authenticated"
else
  report 1 "(b) gh present but NOT authenticated — run 'gh auth login'"
fi

# (c) claude (Claude Code CLI) on PATH --------------------------------------------
# The whole team runs inside a Claude Code session (QUICKSTART step 7 = run /faber),
# so a green doctor must not imply readiness when claude is unavailable. `command -v
# claude` is the probe; a hard fail keeps this consistent with the gh/codex checks.
if command -v claude >/dev/null 2>&1; then
  report 0 "(c) claude (Claude Code CLI) on PATH"
else
  report 1 "(c) claude NOT on PATH — install Claude Code; the team runs in a Claude Code session"
fi

# (d) codex on PATH AND signed in -------------------------------------------------
# PATH alone is not enough: the loop's first `codex exec review` fails mid-run if Codex
# isn't authenticated, yet a PATH-only check would go green. So when codex is present we
# also probe sign-in. The auth subcommand differs across CLI versions, so we discover it
# rather than hardcode: if `codex login status` exists on THIS install (detected from
# `codex login --help`), we run it and treat a clean exit as signed-in (mirroring the gh
# auth check). If that subcommand is absent we degrade gracefully — keep the PATH pass and
# skip the auth assertion with a note, rather than breaking doctor on an unknown version.
if ! command -v codex >/dev/null 2>&1; then
  report 1 "(d) codex NOT on PATH — install the Codex CLI and sign in"
elif codex login --help 2>/dev/null | grep -qw status; then
  if codex login status >/dev/null 2>&1; then
    report 0 "(d) codex on PATH and signed in"
  else
    report 1 "(d) codex on PATH but NOT signed in — run 'codex login'"
  fi
else
  report 0 "(d) codex on PATH (sign-in not verifiable on this CLI version — run 'codex login status' to confirm)"
fi

# (e) jq on PATH ------------------------------------------------------------------
# scripts/merge-pr.sh parses `gh pr checks --json` with jq; without it a fresh machine
# passes setup but the merge step fails. A hard fail keeps this consistent with gh/codex.
if command -v jq >/dev/null 2>&1; then
  report 0 "(e) jq on PATH"
else
  report 1 "(e) jq not on PATH — install jq; required by scripts/merge-pr.sh"
fi

# (f) all restore-critical files present -----------------------------------------
# Read the manifest live (don't duplicate the list); skip blank lines and # comments.
# Resolve paths relative to repo_root so doctor works regardless of the cwd it's run
# from. Report ONE rolled-up line listing any missing files.
manifest="$repo_root/ci/required-files.txt"
if [ ! -f "$manifest" ]; then
  report 1 "(f) required-files manifest present ($manifest missing)"
else
  missing_files=()
  while IFS= read -r f || [ -n "$f" ]; do
    case "$f" in
      ''|'#'*) continue ;;
    esac
    if [ ! -f "$repo_root/$f" ]; then
      missing_files+=("$f")
    fi
  done < "$manifest"
  if [ "${#missing_files[@]}" -eq 0 ]; then
    report 0 "(f) all files in ci/required-files.txt present"
  else
    report 1 "(f) missing restore-critical file(s): ${missing_files[*]}"
  fi
fi

# (h) the TARGET's north star is set and not still the shipped default -------------
# Consistent with the manager-review.sh gate (#98a), doctor resolves the north star FOR THE
# TARGET via the shared resolver (scripts/lib/north-star.sh) from the cwd's checkout: the
# target's own `.fabrica/north-star.md` (LOCAL), or the control-plane root NORTH_STAR.md on a
# Fabrica-self run (FABRICA_SELF). If it aims at the shipped Fabrica-self default (never
# replaced), the gate would debate proposals against the wrong goal. WARN (not FAIL): a stale
# or unset north star doesn't block restore, but it must be set + replaced before proactive
# mode is meaningful for the adopter's repo. UNSET (a non-empty target with no committed star)
# is likewise a WARN, matching the gate's autonomy-authorization gap without hard-failing
# restore. The gate FAILs on these — doctor only diagnoses.
#
# DIAGNOSTIC read of the WORKING-TREE copy: unlike the gate (which reads COMMITTED state at a
# pinned commit — an uncommitted edit must not authorize proactive work), doctor is a
# read-only self-check, so reading the on-disk file is acceptable; it additionally NOTES when
# the working-tree copy differs from HEAD, so an operator sees an uncommitted edit that the
# gate would ignore.
#
# Detection is MARKER-BASED, not phrase-based, and SCOPED to the ACTIVE ENTRY, via the SHARED
# helper ns_has_shipped_default_marker (so doctor and the gate never disagree on what counts as
# an un-replaced placeholder). The shipped-default entry carries a stable marker —
# `fabrica-shipped-default` (as an HTML comment) — on the active-entry heading, so a north-star
# transition never needs a matching edit here (the transition carries the marker onto the new
# active/shipped-default entry), and an adopter who sets their own star REMOVES the marker and the
# warning clears. Scoping to the active-entry region keeps the mechanism clearable: NORTH_STAR.md /
# the template also NAME the token in prose, so a whole-file bare-token grep would warn forever;
# the helper's whitespace/case-insensitive match also catches a spacing/casing/reflow-split marker
# variant. We also WARN when there is no `status: active` entry at all (a malformed/active-less
# file) — an independent readiness gap.
#
# (#98a) doctor (h) now diagnoses the SAME COMMITTED source the gate authorizes on — for a LOCAL
# target, `HEAD:.fabrica/north-star.md`; for a Fabrica-self run, `HEAD:NORTH_STAR.md` — read via
# `git show`. Previously it read the WORKING-TREE copy, so it could disagree with the gate on a
# committed-but-worktree-modified/deleted star. The working-tree copy is now only a SUPPLEMENTARY
# note (does it differ from / is it committed at HEAD?). UNSET/EMPTY/NOREPO still WARN.

# FIX D — if the resolver lib could not be sourced (a partial restore where
# scripts/lib/north-star.sh is exactly what's missing), (h) cannot run its resolver-backed logic.
# Report it as a FAIL line here (check (f) independently flags it in the manifest) and skip the
# rest of (h), so the summary still prints instead of doctor having crashed at the top-of-file
# source. Guarded so this is the ONLY resolver-dependent code that runs when the lib is absent.
if [ "$ns_lib_ok" -ne 1 ]; then
  report 1 "(h) north-star resolver lib missing ($ns_lib) — cannot check the target's north star; restore scripts/lib/north-star.sh (see (f))"
else

# Resolve the target's north star from the cwd, the same source the gate reads. `|| true` so a
# non-git / resolver hiccup degrades to an empty result (handled as the no-star case below)
# rather than aborting under `set -e`.
ns_h_result="$(ns_resolve "$PWD" || true)"
ns_h_kind="${ns_h_result%% *}"
ns_h_path="${ns_h_result#"$ns_h_kind"}"; ns_h_path="${ns_h_path# }"

# When a target <owner>/<repo> was given, the LOCAL/FABRICA_SELF read only describes the target
# if the cwd IS the target's checkout. Compare SLUGS (case-insensitive via ns_slug_eq, GH_REPO
# cleared inside ns_repo_slug) — a cwd that resolves to a different repo must NOT have its local
# star attributed to the target. `|| true` keeps the slug derivation from aborting under `set -e`.
ns_h_cwd_is_target=1
if [ -n "$target_repo" ]; then
  ns_h_cwd_slug="$(ns_repo_slug "$PWD" || true)"
  if [ -n "$ns_h_cwd_slug" ] && ns_slug_eq "$ns_h_cwd_slug" "$target_repo"; then
    ns_h_cwd_is_target=1
  else
    ns_h_cwd_is_target=0
  fi
fi

# FIX E — drive (h)'s verdict off the COMMITTED star (the same source the gate authorizes on),
# NOT the resolver's working-tree LOCAL/UNSET result. ns_resolve stats the WORKING-TREE file, so a
# committed-but-worktree-deleted star reads UNSET there while the gate still authorizes off HEAD —
# doctor must not disagree. So we check COMMITTED existence directly (git cat-file -e HEAD:<relpath>)
# and diagnose the committed content when present; the resolver's kind only tells us WHICH source
# applies (Fabrica-self root NORTH_STAR.md vs. a normal target's .fabrica/north-star.md) and gives
# us the EMPTY/NOREPO cases. The working-tree copy is a SUPPLEMENTARY head-vs-worktree note only.
toplevel="$(ns_git_toplevel "$PWD" || true)"
if [ "$ns_h_kind" = "FABRICA_SELF" ]; then
  committed_relpath="NORTH_STAR.md"
else
  committed_relpath=".fabrica/north-star.md"
fi

# ANCHOR RESOLUTION (#102) — diagnose the SAME committed source the gate authorizes on: the
# gh-BOUND remote's DEFAULT branch, FETCHED FRESH, not raw local HEAD. So doctor's pass/warn
# tracks the gate's authorize/FAIL. doctor is a DIAGNOSTIC (may run local-only / with no comment
# target), so — unlike the gate — a missing gh repo OR no matching remote OR a failed fetch is NOT
# a hard fail: it falls back to the VISIBLE local-default/HEAD anchor and LOGS the line (never
# silent). We fetch into a private per-run ref and clean it up. `anchor_commit` is the commit-ish
# the committed reads below resolve against (a full SHA when fetched/local-HEAD, or `HEAD`).
doctor_anchor_ref=""
cleanup_doctor_anchor_ref() {
  [ -n "$doctor_anchor_ref" ] || return 0
  git update-ref -d "$doctor_anchor_ref" 2>/dev/null || true
  doctor_anchor_ref=""
}
trap cleanup_doctor_anchor_ref EXIT

anchor_commit="HEAD"
anchor_source="local HEAD"
if [ -n "$toplevel" ] && [ "$ghr_lib_ok" -eq 1 ]; then
  # Resolve the gh repo from the cwd (clear GH_REPO so it reflects the actual checkout).
  ns_h_gh_repo="$(env -u GH_REPO gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -n "$ns_h_gh_repo" ]; then
    ns_h_gh_id="$(ghr_gh_repo_id "$ns_h_gh_repo" || true)"
    # Run the remote helpers FROM the git top-level (a subdir invocation still resolves the repo's
    # remotes) via a subshell that `cd`s in; the helpers themselves degrade to empty output, so we
    # capture stdout regardless. `|| true` guards the whole substitution under `set -e`.
    ns_h_remote="$( { cd "$toplevel" && ghr_select_remote "$ns_h_gh_id"; } 2>/dev/null || true )"
    # EFFECTIVE-URL IDENTITY GATE (#102 fix A), mirroring the gate: if a `url.<other>.insteadOf`
    # rewrite redirects the selected remote's FETCH to a DIFFERENT repo identity than gh's, the gate
    # FAILs. doctor only diagnoses, so it WARNs and falls back to the visible local-HEAD anchor
    # (never fetching from the substituted repo). Suppress the helper's own stderr; emit a WARN.
    if [ -n "$ns_h_remote" ] \
       && ! ( cd "$toplevel" && ghr_assert_effective_identity "$ns_h_remote" "$ns_h_gh_id" ) 2>/dev/null; then
      report_warn "(h) remote '${ns_h_remote}' has an insteadOf rewrite redirecting its fetch to a DIFFERENT repo identity than gh's (${ns_h_gh_id}) — the gate FAILs on this; diagnosing against LOCAL HEAD instead. Remove the cross-repo insteadOf rewrite before enabling proactive mode"
      ns_h_remote=""
    fi
    if [ -n "$ns_h_remote" ]; then
      ns_h_default="$( { cd "$toplevel" && ghr_remote_default_branch "$ns_h_remote"; } 2>/dev/null || true )"
      if [ -n "$ns_h_default" ]; then
        doctor_anchor_ref="refs/doctor/$$/anchor"
        ns_h_fetched="$( { cd "$toplevel" && ghr_fetch_default_commit "$ns_h_remote" "$ns_h_default" "$doctor_anchor_ref"; } 2>/dev/null || true )"
        if [ -n "$ns_h_fetched" ]; then
          anchor_commit="$ns_h_fetched"
          anchor_source="the gh-bound remote '${ns_h_remote}' default branch '${ns_h_default}' (fetched fresh)"
        else
          doctor_anchor_ref=""
          report_warn "(h) could not fetch remote '${ns_h_remote}' default branch '${ns_h_default}' — diagnosing against LOCAL HEAD instead (the gate anchors to the fetched default-branch commit; confirm network access)"
        fi
      fi
    fi
  fi
fi
# Log the anchor source so it is never silent (matches the gate's fetched anchor, or names the
# visible local fallback). Emitted as an informational line ahead of the (h) verdict.
echo "info: (h) north-star anchor: ${anchor_source}"

# Committed existence + content at the ANCHOR commit (the gate's authoritative source). `|| true`
# so a not-committed path (git exits non-zero) flows through rather than aborting under `set -e`.
committed_present=0
committed_star=""
if [ -n "$toplevel" ] && git -C "$toplevel" cat-file -e "${anchor_commit}:$committed_relpath" 2>/dev/null; then
  committed_present=1
  committed_star="$(git -C "$toplevel" show "${anchor_commit}:$committed_relpath" 2>/dev/null || true)"
fi

if [ -n "$target_repo" ] && [ "$ns_h_cwd_is_target" -ne 1 ]; then
  report_warn "(h) north star not checked for $target_repo — the cwd (${ns_h_cwd_slug:-<no repo>}) is not $target_repo's checkout; run doctor from the target's clone to check its .fabrica/north-star.md"
elif [ -n "$toplevel" ] && ! ns_committed_is_regular_file "$toplevel" "$anchor_commit" "$committed_relpath" && [ "$committed_present" -eq 1 ]; then
  # SYMLINK guard (round-2 FIX 4), symmetric with the gate: a committed north star stored as a
  # SYMLINK makes `git show HEAD:<path>` return the link's target-path string, not content — the
  # gate FAILs on this, so doctor diagnoses it as a WARN (a readiness gap) rather than reading the
  # meaningless path string as if it were the star. Only fires when the entry exists but is a
  # symlink (regular blobs pass the guard and fall through to the normal diagnosis below).
  report_warn "(h) the target's committed north star ($committed_relpath) is a SYMLINK — the gate requires a regular file (a symlink makes the gate read the link's target-path string, not the star's content); replace it with a regular file and commit before enabling proactive mode"
elif [ "$committed_present" -eq 1 ]; then
  # A committed star at HEAD — the gate's authoritative source. Diagnose IT (not the working tree).
  # Supplementary head-vs-worktree note: surface when the on-disk copy differs from the committed
  # version (an uncommitted edit the gate would ignore) — advisory only.
  head_note=""
  # Drive this off $committed_relpath (the exact path the gate reads) — NOT a hardcoded
  # .fabrica-relative path — so a Fabrica-self checkout (committed_relpath = NORTH_STAR.md)
  # gets the same "gate reads the committed version" note on an uncommitted ROOT edit. The
  # gate reads the ANCHOR commit's $committed_relpath and ignores the working tree, so a
  # dirty/divergent working-tree copy must not read as a silent clean pass here. We diff the
  # working tree against the SAME anchor commit doctor diagnosed (the gh-bound default-branch
  # commit when fetched, else local HEAD) so the note tracks the gate's actual source.
  if [ -n "$toplevel" ] \
     && ! git -C "$toplevel" diff --quiet "$anchor_commit" -- "$committed_relpath" 2>/dev/null; then
    head_note=" (note: the working-tree copy differs from the anchored committed version the gate reads)"
  fi
  # Isolate the active-entry heading from the COMMITTED content (shared region helper), to WARN on
  # a missing `status: active` entry; the marker check goes through the shared insensitive matcher.
  active_entry_line="$(printf '%s' "$committed_star" | ns_active_region - | head -n1 || true)"
  if [ -z "$active_entry_line" ]; then
    report_warn "(h) the target's committed north star ($committed_relpath) has no 'status: active' entry — set an active north star before enabling proactive mode$head_note"
  elif printf '%s' "$committed_star" | ns_has_shipped_default_marker -; then
    report_warn "(h) the target's committed north star ($committed_relpath) still carries the shipped Fabrica-self default (marker '$NS_SHIPPED_DEFAULT_TOKEN' on the active entry) — replace it with your own direction (and remove the marker) before enabling proactive mode$head_note"
  else
    report 0 "(h) the target's committed north star ($committed_relpath) is set and not the shipped default$head_note"
  fi
elif [ "$ns_h_kind" = "LOCAL" ]; then
  # A working-tree-only star (resolver saw the on-disk file) that is NOT committed at the anchored
  # source: the gate reads the anchored committed state and would treat it as UNSET. WARN (doctor
  # only diagnoses). This also fires when the star is committed on a NON-default branch but not on
  # the anchored (gh-bound default) branch — the gate would not authorize off it either.
  report_warn "(h) the target's north star (.fabrica/north-star.md) is not committed at the anchored source (${anchor_source}) — the gate reads that committed state and would treat it as UNSET; commit your north star to the default branch before enabling proactive mode"
else
  # No committed star and no working-tree star. UNSET (non-empty target), EMPTY (commit-less), or
  # NOREPO (cwd not a git work tree) — WARN (not FAIL): the gate FAILs, doctor only flags the gap.
  case "$ns_h_kind" in
    UNSET) report_warn "(h) no north star set for the target — .fabrica/north-star.md is absent; set + commit one before enabling proactive mode (manager-review.sh's gate FAILs without it)" ;;
    EMPTY) report_warn "(h) target repo has no commits yet — no north star expected; set + commit .fabrica/north-star.md before enabling proactive mode" ;;
    FABRICA_SELF) report_warn "(h) the Fabrica control-plane root NORTH_STAR.md is not committed at the anchored source (${anchor_source}) — commit it before enabling proactive mode" ;;
    *)     report_warn "(h) could not resolve a north star from the cwd (resolver: ${ns_h_kind:-none}) — run doctor from the target repo's checkout to check its .fabrica/north-star.md" ;;
  esac
fi

fi  # end ns_lib_ok guard (FIX D)

# (g) optional loop-label check --------------------------------------------------
# Delegate to setup-target-repo.sh --check, which is read-only and reports per-label
# matches/differs/missing. We only surface a single pass/fail line here; its detailed
# output goes to the user's terminal so they can act on any drift.
if [ -n "$target_repo" ]; then
  setup_script="$repo_root/scripts/setup-target-repo.sh"
  if [ ! -x "$setup_script" ]; then
    report 1 "(g) loop labels on $target_repo ($setup_script not executable/found)"
  elif "$setup_script" --check "$target_repo"; then
    report 0 "(g) loop labels on $target_repo present and matching"
  else
    report 1 "(g) loop labels on $target_repo missing or drifted (see --check output above)"
  fi
fi

# (i) target repo has PR-triggered CI (the hard merge gate) -----------------------
# A green doctor on a real repo must not mean "no hard gate." But the gate that's
# actually enforced is merge-pr.sh's `gh pr checks`, which surfaces ANY PR check —
# GitHub Actions AND external CI (CircleCI/Buildkite/Jenkins) wired in as required
# status checks. If none is detectable we WARN (not FAIL) — the merge gate is the
# real enforcement, so doctor flags the risk (confirm the repo runs checks on PRs)
# rather than blocking a setup that may be fine (external CI, or CI that hasn't run yet).
#
# We detect via the OBSERVED checks on recent PRs (ground truth), not by scanning
# workflow files. Reading `.github/workflows` for a `pull_request` trigger is a
# heuristic with an endless tail of edge cases — disabled/ignored files (`ci.yml.disabled`),
# `.github/workflows` listing non-active YAML, format variants — and it false-passes when
# an inactive workflow merely mentions the trigger. Observed PR checks have no such
# false pass: a disabled workflow produces no checks. This signal covers GitHub Actions
# AND external CI uniformly (anything that posts a check-run/status on a PR head).
#
# It must be PR-specific: probing the default branch's HEAD would false-pass a repo
# whose CI runs only on pushes to the default branch and NOT on PRs — exactly the repo
# with no gate for merge-pr.sh. So we list recent PRs and inspect the head SHA of each
# that has one, stopping at the first with any check-run/status. We tolerate the API
# calls' error/empty cases (no PRs, no checks, 404, 403) without aborting under `set -e`
# (each call is `|| true`, defaulting the count to 0); the PR list is buffered into a
# variable and looped via a here-string (no `… | grep` pipe).
#
# It must ALSO be recency-scoped (issue #66): counting check-runs across ALL PRs
# (`--state all`) false-passes a repo that HAD CI but since removed it — old closed PRs
# still carry historical check-runs, overstating readiness. So we restrict the signal to
# PRs updated within a RECENCY WINDOW (90 days — long enough to cover a repo with slow but
# real PR activity, short enough that CI removed months ago no longer counts) by asking
# `gh pr list` for each PR's `updatedAt` and skipping any older than the cutoff. Ancient
# checks from since-removed CI therefore no longer register as "PR CI present." If nothing
# recent qualifies we fall through to the same WARN (no hard FAIL) as before.
#
# DEFERRED ENHANCEMENT (follow-up issue): enumerating the *active* Actions workflows via
# the Actions API (`repos/<repo>/actions/workflows`, which reports each workflow's
# state) would let doctor pass a freshly-set-up repo that has a valid PR workflow but no
# PRs yet — without re-introducing the file-scan's false passes.
if [ -n "$target_repo" ]; then
  ci_seen=0

  # Recency window: only PRs updated within the last N days count, so stale check-runs
  # from since-removed CI (on old closed PRs) don't false-pass. 90 days balances catching
  # slow-but-real PR activity against not honoring CI that was removed months ago. The
  # cutoff comparison runs inside jq (fromdateiso8601 vs now - window) to stay portable
  # across BSD/GNU `date`.
  #
  # ORDER BY UPDATED TIME BEFORE LIMITING: `gh pr list` defaults to ordering by CREATION
  # time, so `--limit 5` alone fetches the 5 newest-CREATED PRs. A long-lived PR updated
  # within the window (and showing CI) but with >5 newer-created PRs would then never enter
  # the fetched set, and the recency filter would wrongly report "no recent PR-triggered CI."
  # We instead ask for PRs ordered most-recently-UPDATED first (`--search "sort:updated-desc"`)
  # so the `--limit` window is the N most-recently-updated PRs — exactly the ones the recency
  # filter is meant to see. The 90-day `updatedAt` `select` stays as the correctness backstop
  # (independent of ordering), and if nothing recent qualifies we still WARN (never hard FAIL).
  ci_recency_days=90
  pr_head_shas="$(gh pr list --repo "$target_repo" --state all \
    --search "sort:updated-desc" --limit 5 \
    --json headRefOid,updatedAt \
    --jq "[.[] | select((.updatedAt | fromdateiso8601) > (now - ($ci_recency_days * 86400)))] | .[].headRefOid" \
    2>/dev/null || true)"
  while IFS= read -r pr_sha; do
    [ -n "$pr_sha" ] || continue
    check_runs="$(gh api "repos/$target_repo/commits/$pr_sha/check-runs" \
      --jq '.total_count' 2>/dev/null || true)"
    statuses="$(gh api "repos/$target_repo/commits/$pr_sha/status" \
      --jq '.statuses | length' 2>/dev/null || true)"
    if [ "${check_runs:-0}" -gt 0 ] 2>/dev/null || [ "${statuses:-0}" -gt 0 ] 2>/dev/null; then
      ci_seen=1
      break
    fi
  done <<< "$pr_head_shas"

  if [ "$ci_seen" -eq 1 ]; then
    report 0 "(i) PR-triggered CI detected on $target_repo (checks observed on a PR updated within ${ci_recency_days}d)"
  else
    report_warn "(i) no recent PR-triggered CI detected on $target_repo — CI is the hard merge gate; confirm the repo runs checks on PRs (within the last ${ci_recency_days}d; Actions workflow or external CI as required status checks)"
  fi
fi

# (j) target repo's CLAUDE.md "Stack & commands" override (ADVISORY) ---------------
# A target CLAUDE.md is an OPTIONAL command-source override, NOT a prerequisite: the
# coder auto-discovers install/test/build commands from the repo's CI workflows and
# standard manifests, and only uses a CLAUDE.md "Stack & commands" section (with
# filled-in commands) to pin or disambiguate a non-standard toolchain. So this check is
# purely informational — it reports whether such an override is present and filled in,
# and WARNs (never FAILs) when it is absent, still carries `<cmd>` placeholders, or lacks
# the section. The placeholder check alone is not enough: an unrelated CLAUDE.md (or one
# whose commands section was deleted) has no `<cmd>` yet also no override commands, so it
# would falsely pass — hence we also require evidence of the section heading. None of
# these is a blocker; auto-discovery covers the common case.
if [ -n "$target_repo" ]; then
  if ! claude_md="$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$target_repo/contents/CLAUDE.md" 2>/dev/null)"; then
    report_warn "(j) advisory: $target_repo has no CLAUDE.md command override — fine; the coder auto-discovers commands from CI + manifests. Add a 'Stack & commands' section only to pin/disambiguate a non-standard toolchain"
  elif printf '%s' "$claude_md" | grep -qF -- '<cmd>'; then
    report_warn "(j) advisory: $target_repo CLAUDE.md still has '<cmd>' placeholders — its 'Stack & commands' section is not an effective override (the coder auto-discovers from CI + manifests instead); fill it in only if you need to pin a non-standard toolchain"
  elif ! printf '%s' "$claude_md" | grep -qiE 'Stack & commands'; then
    report_warn "(j) advisory: $target_repo CLAUDE.md has no 'Stack & commands' section — fine; the coder auto-discovers commands from CI + manifests. Add one only to override/disambiguate a non-standard toolchain"
  else
    report 0 "(j) $target_repo CLAUDE.md has a filled-in 'Stack & commands' override (optional; no '<cmd>' placeholders)"
  fi
fi

# Final summary ------------------------------------------------------------------
# Exit non-zero ONLY when a check failed — warnings are advisory and never flip the
# exit code, so doctor stays usable as a CI/pre-flight gate without false reds.
echo "doctor: $passed passed, $warned warned, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
