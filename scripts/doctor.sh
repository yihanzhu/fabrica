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
#   (h) NORTH_STAR.md's ACTIVE entry is not still the shipped Fabrica-self default
#       (WARN). Scoped to the `status: active` designation, so a kept historical log
#       entry doesn't keep warning once the active star is replaced. Also WARNs if there
#       is no `status: active` entry at all (a malformed/active-less file).
#   (g) optional <owner>/<repo> arg → delegate to setup-target-repo.sh --check to
#       verify the loop labels exist and match.
#   (i) [target-repo path] the target has PR-triggered CI (the hard merge gate).
#       Detected from the OBSERVED checks on recent PRs (ground truth): check-runs /
#       commit statuses on a recent PR's HEAD. This covers GitHub Actions AND external
#       CI (CircleCI/Buildkite/Jenkins) uniformly — anything that posts a check on a PR
#       head — with no false pass from disabled/inactive workflow files. It is
#       PR-SPECIFIC: a repo whose CI runs only on pushes to the default branch — never on
#       PRs — has no gate for merge-pr.sh, so doctor must NOT count default-branch checks.
#       No checks (or no PRs) → WARN, not FAIL: merge-pr.sh's `gh pr checks` is the real
#       enforcement, so doctor flags the risk rather than hard-failing a valid
#       external-CI repo (or one with no PRs yet). Enumerating *active* Actions workflows
#       via the Actions API is a deferred enhancement (a follow-up issue).
#   (j) [target-repo path] the target's CLAUDE.md is present and filled in: it exists,
#       has no `<cmd>` placeholders, AND has a `Stack & commands` section — WARN otherwise.
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
#
# Scope this to the ACTIVE entry only, not the whole file. NORTH_STAR.md instructs
# keeping a historical log ("## North-star log"), so once an adopter promotes their own
# active star the shipped name legitimately survives in the log — grepping the whole
# file would keep warning forever. The active north star is designated by a `status:
# active` marker on its heading line (the `status:` field, distinct from the log's
# descriptive `*active; ...*` prose), so we isolate THAT line and only warn if it still
# carries the shipped default name. Replace the active star and the warning clears even
# if the old name remains logged.
north_star="$repo_root/NORTH_STAR.md"
if [ ! -f "$north_star" ]; then
  report 1 "(h) NORTH_STAR.md present ($north_star missing — restore it; it gates proactive mode)"
else
  active_designation="$(grep -iE 'status:[^A-Za-z]*\**active\**' "$north_star" || true)"
  if [ -z "$active_designation" ]; then
    report_warn "(h) NORTH_STAR.md has no 'status: active' entry — set an active north star before enabling proactive mode"
  elif printf '%s\n' "$active_designation" | grep -qF -- 'Frictionless first-run'; then
    report_warn "(h) NORTH_STAR.md's active entry is still the shipped Fabrica-self default ('Frictionless first-run') — replace it with your own direction before enabling proactive mode"
  else
    report 0 "(h) NORTH_STAR.md's active entry is not the shipped default"
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
# DEFERRED ENHANCEMENT (follow-up issue): enumerating the *active* Actions workflows via
# the Actions API (`repos/<repo>/actions/workflows`, which reports each workflow's
# state) would let doctor pass a freshly-set-up repo that has a valid PR workflow but no
# PRs yet — without re-introducing the file-scan's false passes.
if [ -n "$target_repo" ]; then
  ci_seen=0

  pr_head_shas="$(gh pr list --repo "$target_repo" --state all --limit 5 \
    --json headRefOid --jq '.[].headRefOid' 2>/dev/null || true)"
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
    report 0 "(i) PR-triggered CI detected on $target_repo (checks observed on a recent PR)"
  else
    report_warn "(i) no PR-triggered CI detected on $target_repo — CI is the hard merge gate; confirm the repo runs checks on PRs (Actions workflow or external CI as required status checks)"
  fi
fi

# (j) target repo's CLAUDE.md is present and filled in ----------------------------
# The coder reads the target CLAUDE.md's "Stack & commands" to discover install/test/
# build commands. A missing CLAUDE.md (for a code repo), one still carrying the
# template's `<cmd>` placeholders, or one lacking a "Stack & commands" section entirely
# means the coder can't discover real commands. The placeholder check alone is not
# enough: an unrelated CLAUDE.md (or one whose commands section was deleted) has no
# `<cmd>` yet also no authoritative commands, so it would falsely pass — hence we also
# require evidence of the section heading. WARN (not FAIL): a doc repo legitimately has
# no commands, so this is a heads-up, not a block.
if [ -n "$target_repo" ]; then
  if ! claude_md="$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$target_repo/contents/CLAUDE.md" 2>/dev/null)"; then
    report_warn "(j) $target_repo has no CLAUDE.md — a code repo needs one with a 'Stack & commands' section so the coder can discover install/test/build commands"
  elif printf '%s' "$claude_md" | grep -qF -- '<cmd>'; then
    report_warn "(j) $target_repo CLAUDE.md still has '<cmd>' placeholders — fill in the 'Stack & commands' section before running the loop"
  elif ! printf '%s' "$claude_md" | grep -qiE 'Stack & commands'; then
    report_warn "(j) $target_repo CLAUDE.md has no 'Stack & commands' section — add one with install/test/build commands so the coder can discover them"
  else
    report 0 "(j) $target_repo CLAUDE.md present and filled in ('Stack & commands' section, no '<cmd>' placeholders)"
  fi
fi

# Final summary ------------------------------------------------------------------
# Exit non-zero ONLY when a check failed — warnings are advisory and never flip the
# exit code, so doctor stays usable as a CI/pre-flight gate without false reds.
echo "doctor: $passed passed, $warned warned, $failed failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
