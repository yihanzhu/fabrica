#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — read-only restore self-check for Fabrica.
#
# RESTORE.md only proves a rebuild by running a full live loop; this answers the
# faster question "is the team reconstructable from HERE?" — a restorer can have
# every file back yet still be blocked on a missing credential, an uninstalled
# /faber command, or absent loop labels. doctor surfaces those gaps in seconds.
#
# It is STRICTLY READ-ONLY: it never creates, edits, or deletes anything (and the
# optional label check delegates to setup-target-repo.sh's --check mode, which is
# itself read-only). Every check prints a single `pass:`/`fail:` line; the script
# exits non-zero if ANY check fails, so it is usable as a CI/pre-flight gate.
#
# Checks:
#   (a) ~/.claude/commands/faber.md exists AND contains THIS clone's resolved
#       control-plane path — i.e. /faber points at this clone (same path
#       derivation install.sh uses).
#   (b) gh is present and authenticated.
#   (c) claude (Claude Code CLI) is on PATH — the team runs in a Claude Code session.
#   (d) codex is on PATH.
#   (e) jq is on PATH — required by scripts/merge-pr.sh to parse gh's CI-check JSON.
#   (f) every file in ci/required-files.txt is present on disk (the manifest is
#       read live — the list is never duplicated here).
#   (g) optional <owner>/<repo> arg → delegate to setup-target-repo.sh --check to
#       verify the loop labels exist and match.
#
# Usage:
#   scripts/doctor.sh                 run checks (a)-(e) against this clone
#   scripts/doctor.sh <owner>/<repo>  also run check (f) for that repo's labels

usage() {
  echo "usage: $0 [<owner>/<repo>]" >&2
  echo "  read-only restore self-check: /faber install, gh auth, claude/codex/jq on PATH," >&2
  echo "  and restore-critical files. Prints a pass/fail line per check and exits non-zero" >&2
  echo "  if any fail. Pass <owner>/<repo> to also verify that repo's loop labels." >&2
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
failed=0

# Record a check result and print one aligned pass/fail line. First arg: 0 = pass,
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
# The whole team runs inside a Claude Code session (QUICKSTART step 6 = run /faber),
# so a green doctor must not imply readiness when claude is unavailable. `command -v
# claude` is the probe; a hard fail keeps this consistent with the gh/codex checks.
if command -v claude >/dev/null 2>&1; then
  report 0 "(c) claude (Claude Code CLI) on PATH"
else
  report 1 "(c) claude NOT on PATH — install Claude Code; the team runs in a Claude Code session"
fi

# (d) codex on PATH ---------------------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  report 0 "(d) codex on PATH"
else
  report 1 "(d) codex NOT on PATH — install the Codex CLI and sign in"
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

# Final summary ------------------------------------------------------------------
echo "doctor: $passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
