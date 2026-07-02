#!/usr/bin/env bash
set -euo pipefail

# Resolve THIS script's own directory (following symlinks) so we can source the shared
# north-star resolver from a fixed, install-location-independent path (it lives at
# <control-plane>/scripts/lib/north-star.sh alongside doctor.sh). Deriving from $0 (not the
# cwd) means it is found whether doctor is run from a target subdir or via a PATH symlink.
#
# We compute the path here but DEFER the actual `source` until AFTER the required-files
# manifest check (f) below — detecting a missing restore-critical file (this resolver lib IS
# one; it's in ci/required-files.txt) is doctor's whole job, so a missing lib must be REPORTED
# as a failure and let the summary print, not hard-exit at the `source` under `set -euo
# pipefail` before check (f) even runs. See the "(defer the resolver source)" block below.
_dr_self="$0"
while [ -L "$_dr_self" ]; do
  _dr_link="$(readlink "$_dr_self")"
  case "$_dr_link" in
    /*) _dr_self="$_dr_link" ;;
    *)  _dr_self="$(dirname "$_dr_self")/$_dr_link" ;;
  esac
done
_dr_dir="$(cd "$(dirname "$_dr_self")" && pwd -P)"
ns_lib="$_dr_dir/lib/north-star.sh"

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
# (the hard merge gate) and reports (advisory only) whether a CLAUDE.md "Stack &
# commands" override is present (commands are auto-discovered, so it is optional).
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
#   (h) the TARGET's north star (`.fabrica/north-star.md`) ACTIVE entry is not still the
#       shipped Fabrica-self default (WARN). Resolved per issue #97: with no <owner>/<repo>
#       arg, against THIS clone (Fabrica-self falls back to root NORTH_STAR.md); with an arg,
#       the target's `.fabrica/north-star.md` — the LOCAL file only when the cwd's slug matches
#       the arg, else FETCHED REMOTE via `gh api …/contents/.fabrica/north-star.md`. Detected by
#       a stable MARKER (`<!-- fabrica-shipped-default -->`) on the shipped-default entry, NOT
#       by grepping for a north-star phrase — so no north-star transition needs a doctor edit
#       (the marker rides along to the new default; adopters remove it when they set their own
#       star). Detection is SCOPED to the active-entry heading line (where the marker rides) and
#       matched in its HTML-comment form, so the star's own explanatory mentions of the token
#       don't keep it warning after an adopter strips the real marker. Also WARNs on UNSET (no
#       star resolved) or no `status: active` entry — all warning-level (never a hard fail).
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

# (defer the resolver source) -----------------------------------------------------
# Now — AFTER (f) has already reported any missing restore-critical file — source the shared
# north-star resolver, which check (h) needs. Guard the source so a MISSING lib (e.g. an
# incomplete restore) doesn't hard-exit doctor at the `.` under `set -euo pipefail` before the
# summary prints: instead we record it as a check failure and let (h) degrade to a warn. (f)
# above already names the missing file specifically; this line keeps the exit code correct and
# doctor's normal flow intact. A lib that EXISTS but fails to source (syntax error) is a real
# breakage we surface the same way rather than aborting silently.
ns_lib_loaded=0
if [ -f "$ns_lib" ]; then
  # shellcheck source=scripts/lib/north-star.sh
  if . "$ns_lib"; then
    ns_lib_loaded=1
  else
    report 1 "(f) north-star resolver lib present but failed to source ($ns_lib)"
  fi
else
  report 1 "(f) north-star resolver lib missing ($ns_lib) — restore it (in ci/required-files.txt)"
fi

# (h) north star not still the shipped default -----------------------------------
# The shipped north star aims at Fabrica's OWN control-plane goal. If an adopter never
# replaces it, manager-review.sh debates proposals against the wrong goal. WARN (not
# FAIL): a stale north star doesn't block restore, but it must be replaced before proactive
# mode is meaningful for the adopter's repo.
#
# The north star is now PER-TARGET (issue #97): a target repo owns its star in
# `<repo-root>/.fabrica/north-star.md`, while Fabrica-self keeps its own root NORTH_STAR.md.
# So this check reads the TARGET's star, resolved as follows:
#   - No <owner>/<repo> arg → clone-local run: resolve against THIS clone (the shared resolver
#     falls back to Fabrica-self's root NORTH_STAR.md via the identity match).
#   - With a <owner>/<repo> arg → read the target's `.fabrica/north-star.md`, but use the LOCAL
#     file ONLY when the cwd's resolved repo slug MATCHES the argument (else the cwd is a
#     DIFFERENT checkout and its star must not be misattributed to the target). Otherwise FETCH
#     REMOTE via `gh api repos/<owner>/<repo>/contents/.fabrica/north-star.md` (base64 `.content`).
# On UNSET (a non-empty target with neither a local nor a remote star) → WARN, not FAIL:
# consistent with (h)'s warning-level — north-star state gates *proactive* mode, but
# user-directed work stays valid. Every gh/decode step is `|| true`-guarded so a 404 / empty
# repo / no-content case flows through to the WARN branch instead of aborting under `set -e`.
#
# Detection of the shipped default is MARKER-BASED, not phrase-based. The shipped-default entry
# carries a stable marker — `<!-- fabrica-shipped-default -->` — meaning "this is Fabrica's own
# shipped default." doctor greps for that marker, so a north-star transition never needs a
# matching edit here: the transition process carries the marker onto the new active/shipped
# default entry (documented in NORTH_STAR.md + manager/CLAUDE.md). An adopter who sets their
# own north star REMOVES the marker, and the warning clears. (Previously this grepped the
# active entry for the literal shipped phrase, which coupled doctor to every north-star rename.)
#
# Detection is SCOPED to the ACTIVE ENTRY, not the whole file, and matches the marker in its
# HTML-COMMENT form (`<!-- fabrica-shipped-default -->`) — two safeguards that keep the marker
# mechanism clearable. The shipped north star's explanatory text ALSO names the token (the
# "Shipped-default marker" note, and the active line's own "remove the `fabrica-shipped-default`
# marker" instruction), so a whole-file grep for the bare token would keep matching that doc
# text even after an adopter strips the real marker — warning forever, never clearing. So we
# isolate the active-entry heading line (the one carrying `status: active`, where the marker
# rides) and test only THAT line, and only for the comment form. After an adopter removes the
# `<!-- ... -->` marker from their active heading, (h) clears even if surrounding prose still
# mentions the token.
#
# We still WARN when there is no `status: active` entry at all (a malformed/active-less file):
# that's an independent readiness gap regardless of the marker.
shipped_default_marker='<!-- fabrica-shipped-default -->'

# Load the target's north-star CONTENT into $ns_content (empty = UNSET / unresolved). We work
# on content, not a fixed file path, because the star may come from a local file OR a remote
# fetch. $ns_source is a human-readable label for the report line, $ns_missing signals UNSET.
ns_content=""
ns_source=".fabrica/north-star.md"
ns_missing=0
if [ "$ns_lib_loaded" -ne 1 ]; then
  # The resolver lib didn't load (missing/failed source — already reported as a (f) failure
  # above). Without ns_resolve/ns_repo_slug we can't resolve the star, so (h) can only note
  # that and WARN. Guarding here keeps the calls below from hitting an undefined function and
  # aborting under `set -euo pipefail` — doctor's summary must still print.
  ns_source="north-star resolver lib unavailable"
  ns_missing=1
elif [ -z "$target_repo" ]; then
  # Clone-local run: resolve against this clone (Fabrica-self falls back to root NORTH_STAR.md).
  ns_result="$(ns_resolve "$repo_root")"
  ns_kind="${ns_result%% *}"
  ns_star_path="${ns_result#"$ns_kind"}"; ns_star_path="${ns_star_path# }"
  case "$ns_kind" in
    LOCAL) ns_source=".fabrica/north-star.md"; ns_content="$(cat "$ns_star_path" 2>/dev/null || true)" ;;
    FABRICA_SELF) ns_source="NORTH_STAR.md (Fabrica-self)"; ns_content="$(cat "$ns_star_path" 2>/dev/null || true)" ;;
    *) ns_missing=1 ;;
  esac
else
  # Target-repo run: use the LOCAL file only if the cwd's slug matches the target argument;
  # otherwise the cwd is a different checkout — fetch the target's star from the remote. The
  # match is CASE-INSENSITIVE (ns_slug_eq, not a bare `=`): GitHub slugs are case-insensitive,
  # so `acme/myrepo` (arg) and gh's canonical `Acme/MyRepo` (cwd) are the same target and must
  # read the local star, not fall through to a remote fetch.
  cwd_slug="$(ns_repo_slug "$PWD")"
  if [ -n "$cwd_slug" ] && ns_slug_eq "$cwd_slug" "$target_repo"; then
    ns_result="$(ns_resolve "$PWD")"
    ns_kind="${ns_result%% *}"
    ns_star_path="${ns_result#"$ns_kind"}"; ns_star_path="${ns_star_path# }"
    case "$ns_kind" in
      LOCAL) ns_source=".fabrica/north-star.md (local $target_repo checkout)"; ns_content="$(cat "$ns_star_path" 2>/dev/null || true)" ;;
      FABRICA_SELF) ns_source="NORTH_STAR.md (Fabrica-self)"; ns_content="$(cat "$ns_star_path" 2>/dev/null || true)" ;;
      *) ns_missing=1 ;;
    esac
  else
    # Remote fetch: GET the file's contents and base64-decode `.content`. gh returns non-zero
    # (and no output) on a 404 (no `.fabrica/north-star.md`), which the `|| true` swallows so
    # an absent star becomes the WARN path, not a hard abort. `base64 -d` decodes GitHub's
    # base64-with-newlines `.content` on both GNU and BSD `base64`.
    ns_source=".fabrica/north-star.md (remote $target_repo)"
    ns_b64="$(gh api "repos/$target_repo/contents/.fabrica/north-star.md" --jq '.content' 2>/dev/null || true)"
    if [ -n "$ns_b64" ]; then
      ns_content="$(printf '%s' "$ns_b64" | base64 -d 2>/dev/null || true)"
    fi
    [ -z "$ns_content" ] && ns_missing=1
  fi
fi

# Isolate the active-entry heading line (first line carrying `status: active`); the marker, by
# convention, rides on that heading. Scoping detection here — not the whole content — is what
# stops the explanatory doc text (which names the token) from warning forever.
# `|| true`: grep exits non-zero when there is no `status: active` line, which under
# `set -euo pipefail` (pipefail) would abort the script before the no-active WARN branch.
active_entry_line=""
if [ "$ns_missing" -eq 0 ] && [ -n "$ns_content" ]; then
  active_entry_line="$(printf '%s' "$ns_content" | grep -iE 'status:[^A-Za-z]*\**active\**' | head -n1 || true)"
fi
if [ "$ns_missing" -ne 0 ] || [ -z "$ns_content" ]; then
  report_warn "(h) no north star resolved for the target ($ns_source) — set + approve a north star in .fabrica/north-star.md before enabling proactive mode"
elif [ -z "$active_entry_line" ]; then
  report_warn "(h) north star ($ns_source) has no 'status: active' entry — set an active north star before enabling proactive mode"
elif printf '%s' "$active_entry_line" | grep -qF -- "$shipped_default_marker"; then
  report_warn "(h) north star ($ns_source) still carries the shipped Fabrica-self default (marker '$shipped_default_marker' present) — replace it with your own direction (and remove the marker) before enabling proactive mode"
else
  report 0 "(h) north star ($ns_source) active entry is not the shipped default"
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
