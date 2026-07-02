#!/usr/bin/env bash
set -euo pipefail

# north-star-resolver.test.sh — bash asserts for the per-target north-star resolver
# (scripts/lib/north-star.sh) AND the setup-target-repo.sh seeding path (issue #97 / PR #99).
# OFFLINE and hermetic (no gh/network): the resolver tests stub `ns_repo_slug` for deterministic
# repo identity; the setup tests run the real script against a FAKE `gh` on PATH. Every case
# builds throwaway git repos in temp dirs.
#
# Resolver (scripts/lib/north-star.sh):
#   (a) `.fabrica/north-star.md` is chosen over the root fallback when both exist.
#   (b) a SUBDIRECTORY invocation still resolves the top-level `.fabrica/north-star.md`.
#   (c) Fabrica-self (repo slug == Fabrica's own) falls back to root NORTH_STAR.md.
#   (d) a doctor-style cwd/slug MISMATCH does NOT read the local file (the resolver reports
#       the local star only for the matching repo; a mismatched cwd is handled by doctor.sh
#       fetching remote — asserted here at the slug-comparison level the caller relies on).
#   (e) a non-empty target with NEITHER resolves to UNSET (manager-review FAILs on this;
#       doctor WARNs) — and an EMPTY (commit-less) target is the benign EMPTY case, not UNSET.
#   (f) `ns_repo_slug` clears a set GH_REPO so the slug reflects the repo at <dir>.
#
# setup-target-repo.sh (real script vs. a fake gh):
#   (g) seeds .fabrica/north-star.md when the cwd IS the target; content matches the shipped
#       template; a second run is idempotent (never clobbers an existing star).
#   (h) SKIPS the seed when the cwd slug != target arg (never writes into an unrelated repo).
#   (i) --check reports a MISSING .fabrica/north-star.md as drift (exit non-zero) so Faber's
#       "mutate only on drift" bootstrap re-runs the mutating path and seeds it — while --check
#       itself stays read-only (it does not seed).
#
# Note: manager-review.sh is intentionally NOT asserted here — PR #99 reverts it to the approved
# control-plane NORTH_STAR.md source (the gate+persona source-switch is deferred to #98).
#
# Run: scripts/test/north-star-resolver.test.sh   (exits non-zero on the first failed assert)

# Locate the resolver relative to THIS test file (repo-root/scripts/test/… -> …/scripts/lib).
test_dir="$(cd "$(dirname "$0")" && pwd -P)"
lib="$test_dir/../lib/north-star.sh"
if [ ! -f "$lib" ]; then
  echo "FAIL: resolver not found at $lib" >&2
  exit 1
fi
# shellcheck source=scripts/lib/north-star.sh
. "$lib"

fabrica_root="$(cd "$test_dir/../.." && pwd -P)"

# Make each throwaway repo look like a real one to git, without touching global config.
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# All temp repos live under one dir, cleaned on exit.
tmproot="$(mktemp -d)"
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

passed=0
failed=0
assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1))
    echo "pass: $1"
  else
    failed=$((failed + 1))
    echo "FAIL: $1"
    echo "      expected: [$2]"
    echo "      actual:   [$3]"
  fi
}

# make_repo <name> — init a git repo with one commit; echo its path.
make_repo() {
  local path="$tmproot/$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" commit -q --allow-empty -m "init"
  echo "$path"
}

# --- (a) local .fabrica/north-star.md wins over the root fallback ------------------
# A non-Fabrica target with BOTH a local star AND (hypothetically) a root fallback must pick
# the local one. We stub ns_repo_slug so this repo is NOT Fabrica (identity check would fail),
# proving the LOCAL branch is what wins — not the fallback.
test_local_wins() {
  local repo; repo="$(make_repo "target-a")"
  mkdir -p "$repo/.fabrica"
  echo "local star A" > "$repo/.fabrica/north-star.md"
  ns_repo_slug() { echo "someone/target-a"; }   # not Fabrica
  # Canonicalize the expected path through git's own top-level (macOS resolves /var ->
  # /private/var); the resolver returns the canonical top-level, so compare like-for-like.
  local expect; expect="$(ns_git_toplevel "$repo")/.fabrica/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(a) kind is LOCAL when .fabrica/north-star.md exists" "LOCAL" "$kind"
  assert_eq "(a) resolved path is the local star" "$expect" "$path"
  unset -f ns_repo_slug
}

# --- (b) subdirectory invocation resolves the top-level file ----------------------
# Regression guard: run the resolver from a NESTED dir; it must walk up to the git top-level's
# .fabrica/north-star.md, not fail or read $PWD literally.
test_subdir_resolves_toplevel() {
  local repo; repo="$(make_repo "target-b")"
  mkdir -p "$repo/.fabrica"
  echo "local star B" > "$repo/.fabrica/north-star.md"
  mkdir -p "$repo/deeply/nested/dir"
  ns_repo_slug() { echo "someone/target-b"; }   # not Fabrica
  local expect; expect="$(ns_git_toplevel "$repo")/.fabrica/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo/deeply/nested/dir")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(b) subdir invocation resolves LOCAL" "LOCAL" "$kind"
  assert_eq "(b) subdir invocation resolves the TOP-LEVEL star" "$expect" "$path"
  unset -f ns_repo_slug
}

# --- (c) Fabrica-self identity → root NORTH_STAR.md fallback -----------------------
# A repo with NO local .fabrica/north-star.md whose slug equals Fabrica's own must fall back
# to the control-plane root NORTH_STAR.md. We stub the slug helpers so the identity match is
# deterministic and offline, and point the fabrica-root/root-star at a throwaway root file so
# the assert doesn't depend on the live repo's NORTH_STAR.md contents.
test_fabrica_self_fallback() {
  local repo; repo="$(make_repo "fabrica-clone")"
  # No .fabrica/north-star.md here — force the fallback path.
  local fake_root="$tmproot/fake-fabrica-root"
  mkdir -p "$fake_root"
  echo "root fabrica star" > "$fake_root/NORTH_STAR.md"
  ns_repo_slug() { echo "acme/fabrica"; }        # both target + fabrica resolve to this
  ns_fabrica_slug() { echo "acme/fabrica"; }     # identity match
  ns_fabrica_root() { echo "$fake_root"; }       # root NORTH_STAR.md lives here
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c) Fabrica-self identity falls back to FABRICA_SELF" "FABRICA_SELF" "$kind"
  assert_eq "(c) fallback path is root NORTH_STAR.md" "$fake_root/NORTH_STAR.md" "$path"
  unset -f ns_repo_slug ns_fabrica_slug ns_fabrica_root
}

# A NON-Fabrica repo with no local star must NOT inherit the root fallback (identity, not
# "file exists"): the fallback is skipped and, being non-empty, it resolves to UNSET.
test_non_fabrica_no_fallback() {
  local repo; repo="$(make_repo "external-target")"
  local fake_root="$tmproot/fake-fabrica-root2"
  mkdir -p "$fake_root"
  echo "root fabrica star" > "$fake_root/NORTH_STAR.md"
  ns_repo_slug() { echo "someone/external"; }    # target is NOT fabrica
  ns_fabrica_slug() { echo "acme/fabrica"; }     # fabrica is a different slug
  ns_fabrica_root() { echo "$fake_root"; }
  local out kind
  out="$(ns_resolve "$repo")"; kind="${out%% *}"
  assert_eq "(c') non-Fabrica repo with no local star does NOT use root fallback (UNSET)" "UNSET" "$kind"
  unset -f ns_repo_slug ns_fabrica_slug ns_fabrica_root
}

# --- (d) doctor-style cwd/slug mismatch does NOT read the local file --------------
# doctor.sh reads a LOCAL star only when the cwd's resolved slug matches the <owner>/<repo>
# argument; on a mismatch it must fetch remote instead of misattributing the cwd's star. We
# assert the decision the caller makes on the resolver's slug output: a cwd resolving to slug
# X must NOT be treated as target Y even though a local .fabrica/north-star.md exists.
test_doctor_slug_mismatch() {
  local repo; repo="$(make_repo "some-checkout")"
  mkdir -p "$repo/.fabrica"
  echo "some other repo's star" > "$repo/.fabrica/north-star.md"
  ns_repo_slug() { echo "someone/some-checkout"; }
  local cwd_slug target_arg use_local
  cwd_slug="$(ns_repo_slug "$repo")"
  target_arg="owner/DIFFERENT-repo"
  # This mirrors doctor.sh's guard: use the local file ONLY on an exact slug match.
  if [ -n "$cwd_slug" ] && [ "$cwd_slug" = "$target_arg" ]; then use_local="yes"; else use_local="no"; fi
  assert_eq "(d) cwd/slug mismatch → do NOT read the local file" "no" "$use_local"
  # And the positive control: a matching slug WOULD use the local file.
  target_arg="someone/some-checkout"
  if [ -n "$cwd_slug" ] && [ "$cwd_slug" = "$target_arg" ]; then use_local="yes"; else use_local="no"; fi
  assert_eq "(d) cwd/slug match → DO read the local file" "yes" "$use_local"
  unset -f ns_repo_slug
}

# --- (e) non-empty target with neither → UNSET; empty target → EMPTY --------------
test_unset_and_empty() {
  # Non-empty repo (has a commit), no local star, not Fabrica → UNSET.
  local repo; repo="$(make_repo "target-e")"
  ns_repo_slug() { echo "someone/target-e"; }
  ns_fabrica_slug() { echo "acme/fabrica"; }
  local out kind
  out="$(ns_resolve "$repo")"; kind="${out%% *}"
  assert_eq "(e) non-empty target, no star → UNSET (manager-review FAIL / doctor WARN)" "UNSET" "$kind"
  unset -f ns_repo_slug ns_fabrica_slug

  # Empty repo (git init, NO commits), no local star → EMPTY (benign, not UNSET).
  local empty="$tmproot/target-empty"
  mkdir -p "$empty"
  git -C "$empty" init -q
  ns_repo_slug() { echo "someone/target-empty"; }
  ns_fabrica_slug() { echo "acme/fabrica"; }
  out="$(ns_resolve "$empty")"; kind="${out%% *}"
  assert_eq "(e) empty (commit-less) target → EMPTY, not UNSET" "EMPTY" "$kind"
  unset -f ns_repo_slug ns_fabrica_slug

  # A path that is not a git repo at all → NOREPO.
  local nonrepo="$tmproot/not-a-repo"
  mkdir -p "$nonrepo"
  out="$(ns_resolve "$nonrepo")"; kind="${out%% *}"
  assert_eq "(e) non-repo path → NOREPO" "NOREPO" "$kind"
}

# --- (f) resolver slug derivation ignores a set GH_REPO (P2 regression) -----------
# `gh repo view` honors an exported GH_REPO over the repo at the cwd, so if ns_repo_slug did
# not clear it, a set GH_REPO would make the helper print the ENV repo's slug instead of the
# repo at <dir> — spoofing doctor.sh's cwd/slug match into reading the wrong local star. This
# uses the REAL ns_repo_slug (not the stub) against a fake `gh` on PATH that reports whether
# GH_REPO was set in its own environment when invoked. Hermetic and offline (no network/auth).
test_slug_ignores_gh_repo() {
  # Restore the REAL ns_repo_slug — earlier tests `unset -f` their stub, which removes the
  # sourced function too. This test exercises the real derivation, so re-source the lib.
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "gh-repo-spoof")"
  local fakebin="$tmproot/fakebin-gh"
  mkdir -p "$fakebin"
  # Fake gh: if GH_REPO is set in ITS environment, print the env slug (the spoof); otherwise
  # print a fixed real slug for the repo at cwd. ns_repo_slug must clear GH_REPO so this fake
  # never sees it — proving the slug reflects the repo at <dir>, not the env override.
  cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_REPO:-}" ]; then
  echo "spoofed/${GH_REPO}"
else
  echo "real/at-cwd"
fi
GH
  chmod +x "$fakebin/gh"
  local out
  # Prepend the fake gh to PATH and export a GH_REPO that WOULD spoof the slug if not cleared.
  # Set the env in a subshell (a `VAR=val funcname` prefix can't invoke a shell function), so
  # the export is scoped to this call and does not leak into later tests.
  # shellcheck disable=SC2030,SC2031  # PATH is scoped to this $()-subshell on purpose (no leak).
  out="$( export PATH="$fakebin:$PATH" GH_REPO="attacker/other-repo"; ns_repo_slug "$repo" )"
  assert_eq "(f) ns_repo_slug ignores a set GH_REPO (slug reflects the repo at <dir>)" "real/at-cwd" "$out"
}

# --- setup-target-repo.sh: seeding + cwd-guard + --check drift (issues #97 / PR #99) ---
# These exercise the REAL setup-target-repo.sh end-to-end against a FAKE `gh` on PATH, so they
# stay hermetic (no network/auth) while covering the integrated behavior: the cwd-guard (seed
# ONLY when the cwd slug equals the target arg), idempotency, and --check reporting a missing
# .fabrica/north-star.md as drift so Faber's "mutate only on drift" bootstrap re-seeds it.
#
# make_fake_gh <dir> — install a fake `gh` under <dir>/gh that:
#   * `gh repo view <slug>` (access preflight) → exit 0
#   * `gh repo view --json nameWithOwner ...` (cwd-slug probe) → prints $FAKE_CWD_SLUG
#   * `gh label list ...` → prints the 8 canonical labels as name<TAB>color<TAB>desc TSV,
#     so --check sees every label MATCHING (isolating the north-star file as the only drift)
#   * `gh label create/edit ...` → exit 0 (created)
# The canonical label TSV mirrors setup-target-repo.sh's `labels=(…)`; if that array drifts,
# the --check "all labels match" precondition here breaks loudly — a useful coupling signal.
make_fake_gh() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
# Minimal fake gh for the setup-target-repo.sh tests. Dispatches on the subcommand.
sub="${1:-}"; shift || true
case "$sub" in
  repo)
    # "repo view ..." — two shapes: bare access check, or the --json nameWithOwner slug probe.
    if printf '%s\n' "$@" | grep -q -- '--json'; then
      echo "${FAKE_CWD_SLUG:-}"
    fi
    exit 0
    ;;
  label)
    action="${1:-}"; shift || true
    case "$action" in
      list)
        # Emit the canonical labels as matching TSV (name<TAB>color<TAB>description).
        printf '%s\t%s\t%s\n' "debating" "fbca04" "Issue under manager-debate; not yet approved"
        printf '%s\t%s\t%s\n' "ready" "0e8a16" "Cleared to run (user approval OR consensus); Faber's cue to spawn the coder"
        printf '%s\t%s\t%s\n' "round-0" "c5def5" "Review-loop counter: initial PR"
        printf '%s\t%s\t%s\n' "round-1" "7fb3e0" "Review-loop counter: revision 1"
        printf '%s\t%s\t%s\n' "round-2" "4a90d9" "Review-loop counter: revision 2"
        printf '%s\t%s\t%s\n' "round-3" "1f6fc0" "Review-loop counter: revision 3 (cap)"
        printf '%s\t%s\t%s\n' "needs-human" "d93f0b" "Escalation: round cap hit, ambiguous spec, oversized PR, or failure"
        printf '%s\t%s\t%s\n' "merge-ready" "5319e7" "Current head passed Codex review; auto-merged in-session if low-risk, else awaiting your merge"
        exit 0
        ;;
      create|edit) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$dir/gh"
}

# run_setup [--check] — run the REAL setup-target-repo.sh with the fake gh on PATH, from the
# CURRENT cwd (set by the caller), against target arg "$SETUP_TARGET". $FAKE_CWD_SLUG controls
# what the cwd-slug probe reports. Echoes combined stdout+stderr; returns the script's exit code.
run_setup() {
  local script="$fabrica_root/scripts/setup-target-repo.sh"
  # PATH here is a per-COMMAND env prefix scoped to this single `bash` invocation (it does not
  # persist), which is exactly what we want — prepend the fake gh only for the script under test.
  # shellcheck disable=SC2030,SC2031  # intentional single-command PATH prefix, not a leaked mod.
  PATH="$fake_gh_dir:$PATH" bash "$script" "$@" "$SETUP_TARGET" 2>&1
}

# --- (g) seed when cwd IS the target; content matches template; idempotent ---------
test_setup_seeds_when_cwd_is_target() {
  local target; target="$(make_repo "setup-seed-target")"
  local seeded="$target/.fabrica/north-star.md"
  SETUP_TARGET="acme/setup-seed-target"
  FAKE_CWD_SLUG="acme/setup-seed-target"   # cwd IS the target
  export SETUP_TARGET FAKE_CWD_SLUG
  # Absent → seeded from the template.
  ( cd "$target" && run_setup >/dev/null )
  local exists="no"; [ -f "$seeded" ] && exists="yes"
  assert_eq "(g) setup seeds .fabrica/north-star.md when cwd is the target" "yes" "$exists"
  # Content matches the shipped template byte-for-byte.
  local same="no"
  if cmp -s "$seeded" "$fabrica_root/templates/.fabrica/north-star.md"; then same="yes"; fi
  assert_eq "(g) seeded file matches the shipped template" "yes" "$same"
  # Idempotent: a second run must NOT clobber a target that already set its own goal.
  echo "MY OWN GOAL" > "$seeded"
  ( cd "$target" && run_setup >/dev/null )
  assert_eq "(g) second run does NOT overwrite an existing north star" "MY OWN GOAL" "$(cat "$seeded")"
  unset SETUP_TARGET FAKE_CWD_SLUG
}

# --- (h) seeding is SKIPPED when the cwd slug != target arg (Task 2 cwd-guard) ------
# The cwd is a DIFFERENT repo than the target; the seed must NOT write into it.
test_setup_skips_seed_when_cwd_not_target() {
  local wrongcwd; wrongcwd="$(make_repo "unrelated-checkout")"
  local wrong_star="$wrongcwd/.fabrica/north-star.md"
  SETUP_TARGET="acme/the-real-target"
  FAKE_CWD_SLUG="someone/unrelated-checkout"   # cwd is NOT the target
  export SETUP_TARGET FAKE_CWD_SLUG
  local out; out="$( cd "$wrongcwd" && run_setup )"
  local wrote="no"; [ -f "$wrong_star" ] && wrote="yes"
  assert_eq "(h) no north star written into a non-target cwd" "no" "$wrote"
  # And the skip note names the mismatch so the operator understands why.
  local noted="no"
  if printf '%s' "$out" | grep -q "cwd is not the target checkout"; then noted="yes"; fi
  assert_eq "(h) skip note explains the cwd is not the target checkout" "yes" "$noted"
  unset SETUP_TARGET FAKE_CWD_SLUG
}

# --- (i) --check reports "needs setup" when labels match but the star file is missing (Task 3) ---
# Faber's bootstrap mutates ONLY on drift, so a target with matching labels but no
# .fabrica/north-star.md must make --check exit NON-ZERO (drift) — otherwise the seed (which
# runs only in the mutating path) is never reached and the file is never seeded.
test_check_reports_missing_north_star_as_drift() {
  local target; target="$(make_repo "check-drift-target")"
  # No .fabrica/north-star.md here — labels all match (fake gh), file is the only drift.
  SETUP_TARGET="acme/check-drift-target"
  FAKE_CWD_SLUG="acme/check-drift-target"   # cwd IS the target, so --check can see its tree
  export SETUP_TARGET FAKE_CWD_SLUG
  local out rc
  set +e
  out="$( cd "$target" && run_setup --check )"; rc=$?
  set -e
  assert_eq "(i) --check exits non-zero (drift) when .fabrica/north-star.md is missing" "1" "$rc"
  local flagged="no"
  if printf '%s' "$out" | grep -q "north star: missing"; then flagged="yes"; fi
  assert_eq "(i) --check names the missing north-star file as drift" "yes" "$flagged"
  # And --check MUST stay read-only: it must not have seeded the file itself.
  local seeded_by_check="no"; [ -f "$target/.fabrica/north-star.md" ] && seeded_by_check="yes"
  assert_eq "(i) --check stays read-only (does NOT seed the file itself)" "no" "$seeded_by_check"
  # Positive control: once a star exists, matching labels + present file ⇒ --check is clean.
  mkdir -p "$target/.fabrica"; echo "a goal" > "$target/.fabrica/north-star.md"
  set +e
  ( cd "$target" && run_setup --check >/dev/null ); rc=$?
  set -e
  assert_eq "(i) --check is clean (exit 0) once labels match AND the star file is present" "0" "$rc"
  unset SETUP_TARGET FAKE_CWD_SLUG
}

# Install the fake gh once, shared by the setup tests above.
fake_gh_dir="$tmproot/fake-gh-setup"
make_fake_gh "$fake_gh_dir"

echo "== north-star resolver tests =="
echo "(fabrica root under test: $fabrica_root)"
test_local_wins
test_subdir_resolves_toplevel
test_fabrica_self_fallback
test_non_fabrica_no_fallback
test_doctor_slug_mismatch
test_unset_and_empty
test_slug_ignores_gh_repo
test_setup_seeds_when_cwd_is_target
test_setup_skips_seed_when_cwd_not_target
test_check_reports_missing_north_star_as_drift

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
