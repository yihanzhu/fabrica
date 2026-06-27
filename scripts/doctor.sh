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
# (not merely on PATH), warns when NORTH_STAR.md is still the shipped Fabrica-self
# default, and — in the target-repo path — checks the target has PR-triggered CI
# (the hard merge gate) and a filled-in CLAUDE.md.
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
#   (h) NORTH_STAR.md is not still the shipped Fabrica-self default (WARN).
#   (g) optional <owner>/<repo> arg → delegate to setup-target-repo.sh --check to
#       verify the loop labels exist and match.
#   (i) [target-repo path] the target has PR-triggered CI (the hard merge gate) — FAIL
#       if none is detectable.
#   (j) [target-repo path] the target's CLAUDE.md is present and filled in (no `<cmd>`
#       placeholders) — WARN otherwise.
#
# Usage:
#   scripts/doctor.sh                 run the clone-local checks against this clone
#   scripts/doctor.sh <owner>/<repo>  also run the target-repo checks for that repo

usage() {
  echo "usage: $0 [<owner>/<repo>]" >&2
  echo "  read-only restore self-check: /faber install, gh auth, claude/codex (auth)/jq on" >&2
  echo "  PATH, restore-critical files, and NORTH_STAR not still the shipped default. Prints" >&2
  echo "  a pass/warn/fail line per check; exits non-zero only on a fail (warnings never do)." >&2
  echo "  Pass <owner>/<repo> to also verify that repo's loop labels, PR-triggered CI, and" >&2
  echo "  a filled-in CLAUDE.md." >&2
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

# (h) NORTH_STAR.md not still the shipped default --------------------------------
# The shipped NORTH_STAR.md aims at Fabrica's OWN control-plane goal ("Frictionless
# first-run"). If an adopter never replaces it, manager-review.sh debates proposals
# against the wrong goal. WARN (not FAIL): a stale north star doesn't block restore,
# but it must be replaced before proactive mode is meaningful for the adopter's repo.
north_star="$repo_root/NORTH_STAR.md"
if [ ! -f "$north_star" ]; then
  report 1 "(h) NORTH_STAR.md present ($north_star missing — restore it; it gates proactive mode)"
elif grep -qF -- 'Frictionless first-run' "$north_star"; then
  report_warn "(h) NORTH_STAR.md is still the shipped Fabrica-self default ('Frictionless first-run') — replace it with your own direction before enabling proactive mode"
else
  report 0 "(h) NORTH_STAR.md replaced (not the shipped default)"
fi

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
# A green doctor on a real repo must not mean "no hard gate." Branch protection's
# required_status_checks is the ideal signal but is unavailable on free/private repos
# (gh returns 403), so we don't depend on it. Instead we enumerate the target's
# workflow files and check whether ANY declares a `pull_request` trigger — the thing
# that makes CI run on a PR and become a merge gate. No PR-triggered workflow → FAIL.
if [ -n "$target_repo" ]; then
  ci_seen=0
  if ! workflow_paths="$(gh api "repos/$target_repo/contents/.github/workflows" \
      --jq '.[] | select(.type=="file") | .path' 2>/dev/null)"; then
    report 1 "(i) PR-triggered CI on $target_repo (no .github/workflows — the hard merge gate is absent)"
  else
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      if gh api -H "Accept: application/vnd.github.raw" "repos/$target_repo/contents/$wf" 2>/dev/null \
          | grep -qE '^[[:space:]]*pull_request:?([[:space:]]|$)'; then
        ci_seen=1
        break
      fi
    done <<< "$workflow_paths"
    if [ "$ci_seen" -eq 1 ]; then
      report 0 "(i) PR-triggered CI present on $target_repo"
    else
      report 1 "(i) no PR-triggered CI on $target_repo — workflows exist but none triggers on pull_request; the hard merge gate is absent"
    fi
  fi
fi

# (j) target repo's CLAUDE.md is present and filled in ----------------------------
# The coder reads the target CLAUDE.md's "Stack & commands" to discover install/test/
# build commands. A missing CLAUDE.md (for a code repo) or one still carrying the
# template's `<cmd>` placeholders means the coder can't discover real commands. WARN
# (not FAIL): a doc repo legitimately has no commands, so this is a heads-up, not a block.
if [ -n "$target_repo" ]; then
  if ! claude_md="$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$target_repo/contents/CLAUDE.md" 2>/dev/null)"; then
    report_warn "(j) $target_repo has no CLAUDE.md — a code repo needs one with a 'Stack & commands' section so the coder can discover install/test/build commands"
  elif printf '%s' "$claude_md" | grep -qF -- '<cmd>'; then
    report_warn "(j) $target_repo CLAUDE.md still has '<cmd>' placeholders — fill in the 'Stack & commands' section before running the loop"
  else
    report 0 "(j) $target_repo CLAUDE.md present and filled in (no '<cmd>' placeholders)"
  fi
fi

# Final summary ------------------------------------------------------------------
# Exit non-zero ONLY when a check failed — warnings are advisory and never flip the
# exit code, so doctor stays usable as a CI/pre-flight gate without false reds.
echo "doctor: $passed passed, $warned warned, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
