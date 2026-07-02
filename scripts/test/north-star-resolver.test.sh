#!/usr/bin/env bash
set -euo pipefail

# north-star-resolver.test.sh — bash asserts for the per-target north-star RESOLVER
# (scripts/lib/north-star.sh), issue #97 / PR #99.
#
# PR #99 ships the resolver as a DORMANT foundation: the lib and the adopter template exist,
# but NO script consumer reads them yet (doctor.sh / setup-target-repo.sh / manager-review.sh
# all still use the control-plane NORTH_STAR.md). The consumer flip lands atomically in #98/98a.
# So this suite covers ONLY the resolver lib in isolation — there are no setup- or doctor-
# integration tests here, because there is no integrated behavior to assert yet.
#
# OFFLINE and hermetic (no gh/network): the tests stub `ns_repo_slug` for deterministic repo
# identity, and the GH_REPO test runs the real helper against a FAKE `gh` on PATH. Every case
# builds throwaway git repos in temp dirs.
#
# Resolver (scripts/lib/north-star.sh):
#   (a) `.fabrica/north-star.md` is chosen over the root fallback when both exist.
#   (b) a SUBDIRECTORY invocation still resolves the top-level `.fabrica/north-star.md`.
#   (c) Fabrica-self (repo slug == Fabrica's own) falls back to root NORTH_STAR.md.
#   (c2) Fabrica-self identity survives a CASING-ONLY slug difference (routes through
#       ns_slug_eq) → still FABRICA_SELF, not UNSET (P2, round-3).
#   (c') a NON-Fabrica repo with no local star does NOT inherit the root fallback (identity,
#       not "file exists") → UNSET.
#   (d) a doctor-style cwd/slug MISMATCH does NOT read the local file (the resolver reports
#       the local star only for the matching repo; a mismatched cwd is handled by doctor.sh
#       fetching remote — asserted here at the slug-comparison level the caller relies on).
#   (e) a non-empty target with NEITHER resolves to UNSET (manager-review FAILs on this;
#       doctor WARNs) — and an EMPTY (commit-less) target is the benign EMPTY case, not UNSET;
#       a non-repo path is NOREPO.
#   (f) `ns_repo_slug` clears a set GH_REPO so the slug reflects the repo at <dir>.
#   (f2) `ns_slug_eq` compares slugs CASE-INSENSITIVELY (acme/myrepo == Acme/MyRepo), keeps
#       genuinely different repos different (P2, round-2).
#   (g) relative-source + cd-away still resolves FABRICA_SELF, and a decoy cwd NORTH_STAR.md is
#       not mistaken for Fabrica's root — the __ns_self absolutize-at-source-time fix (P1, round-3).
#   (h) offline (gh stubbed to fail) still resolves Fabrica-self via the gh-free PATH identity
#       check (P2, round-3).
#   (i) `ns_repo_slug` neutralizes a set CDPATH — no wrong-dir landing, no leaked path on stdout
#       (P3, round-3).
#   (j) `ns_repo_slug ""` returns non-zero/empty — an empty arg never falls through to the cwd's
#       slug (P3, round-3).
#   (k) `ns_fabrica_root` under `set -euo pipefail` from a deleted sourced tree yields rc 0, empty
#       stdout, and no stderr leak — matching the sibling value-helpers (P3, round-3).
#
# Cases (g)–(k) were surfaced by an adversarial audit; each reproduces a bug the prior suite
# MASKED because it sourced via an ABSOLUTE path and never cd'd away / never stubbed gh-missing.
#
# Note: doctor.sh, setup-target-repo.sh, and manager-review.sh are intentionally NOT asserted
# here — PR #99 leaves all three on the control-plane NORTH_STAR.md source (consumers switch to
# this resolver atomically in #98/98a, and their integration tests land with that switch).
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

# --- (c2) Fabrica-self identity survives a CASING-ONLY slug difference (P2, round-3) --
# GitHub owner/repo slugs are case-insensitive, so a Fabrica clone whose target slug differs
# from Fabrica's own only in casing (yihanzhu/Fabrica vs yihanzhu/fabrica) is STILL Fabrica.
# ns_resolve's identity check routes through ns_slug_eq, so the casing-only difference must
# still fall back to the root NORTH_STAR.md — not skip to UNSET.
test_fabrica_self_case_insensitive() {
  local repo; repo="$(make_repo "fabrica-clone-cased")"
  # No .fabrica/north-star.md here — force the identity/fallback path.
  local fake_root="$tmproot/fake-fabrica-root-cased"
  mkdir -p "$fake_root"
  echo "root fabrica star" > "$fake_root/NORTH_STAR.md"
  ns_repo_slug() { echo "yihanzhu/Fabrica"; }    # target slug: canonical casing
  ns_fabrica_slug() { echo "yihanzhu/fabrica"; } # fabrica's own slug: lowercase — same repo
  ns_fabrica_root() { echo "$fake_root"; }
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c2) casing-only self slug still matches Fabrica → FABRICA_SELF (not UNSET)" "FABRICA_SELF" "$kind"
  assert_eq "(c2) casing-only self fallback path is root NORTH_STAR.md" "$fake_root/NORTH_STAR.md" "$path"
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

# --- (e2) ns_resolve is errexit-safe from a non-git dir (P2, round-3) --------------
# Regression guard for the [P2]: ns_resolve's `toplevel="$(ns_git_toplevel …)"` used to run an
# UNGUARDED `git rev-parse --show-toplevel`, which exits non-zero outside a work tree. Under a
# `set -e` consumer calling `ns_resolve` as a simple command (as this repo's scripts do — all
# use `set -euo pipefail`), that abort fires BEFORE the documented NOREPO branch, so the caller
# dies with the git exit status instead of seeing NOREPO. (The existing (e) assert wraps the
# call in `out="$(ns_resolve …)"`, whose command-substitution nesting masks the abort — so it
# did NOT catch this.) Here we invoke ns_resolve as a TOP-LEVEL command inside a fresh
# `bash -c 'set -euo pipefail; …'` subshell and assert it both PRINTS NOREPO and EXITS 0.
test_resolve_errexit_safe_non_git() {
  local nonrepo="$tmproot/errexit-non-git"
  mkdir -p "$nonrepo"
  # Run in a clean subshell that sources the lib fresh and calls ns_resolve as a simple command
  # under errexit — the unguarded lib aborts here (empty output, rc=128).
  local out rc
  out="$(bash -c '
    set -euo pipefail
    . "$1"
    ns_resolve "$2"
  ' _ "$lib" "$nonrepo" 2>/dev/null)" && rc=0 || rc=$?
  assert_eq "(e2) ns_resolve under set -e from a non-git dir prints NOREPO" "NOREPO" "$out"
  assert_eq "(e2) ns_resolve under set -e from a non-git dir does NOT abort (exit 0)" "0" "$rc"
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

# --- (f2) ns_slug_eq compares slugs CASE-INSENSITIVELY (P2, round-2) ---------------
# GitHub owner/repo names are case-insensitive, so a user-typed `acme/myrepo` and gh's
# canonical `Acme/MyRepo` name the SAME repo. The #98/98a consumer flip will route each slug
# compare through ns_slug_eq (not a bare `=`), so a case mismatch must NOT be treated as a
# different target. Also assert genuinely different slugs stay unequal, and that two empty
# slugs are NOT relied upon (callers still guard on non-emptiness so an unresolved cwd never
# matches).
test_slug_eq_case_insensitive() {
  # Re-source the lib in case an earlier test's `unset -f` stub removed a helper.
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local same="no"; if ns_slug_eq "acme/myrepo" "Acme/MyRepo"; then same="yes"; fi
  assert_eq "(f2) ns_slug_eq treats acme/myrepo and Acme/MyRepo as the SAME repo" "yes" "$same"
  local same2="no"; if ns_slug_eq "ACME/MYREPO" "acme/myrepo"; then same2="yes"; fi
  assert_eq "(f2) ns_slug_eq is fully case-insensitive on both sides" "yes" "$same2"
  local diff="same"; if ns_slug_eq "acme/myrepo" "acme/other"; then diff="same"; else diff="different"; fi
  assert_eq "(f2) ns_slug_eq keeps genuinely different repos DIFFERENT" "different" "$diff"
  local both_empty="same"; if ns_slug_eq "" ""; then both_empty="same"; else both_empty="different"; fi
  # ns_slug_eq("","") is technically "equal", but callers guard on [ -n "$slug" ] first, so an
  # empty cwd slug never reaches the compare. We assert the compare itself here for clarity.
  assert_eq "(f2) ns_slug_eq of two empty strings is equal (callers guard non-emptiness)" "same" "$both_empty"
}

# --- (g) relative-source + cd-away still resolves the control plane (P1, round-3) --
# The pre-fix ns_fabrica_root re-read `${BASH_SOURCE[0]}` lazily. When a consumer sources the lib
# via a RELATIVE path (`. scripts/lib/north-star.sh`) and then cd's into a target, that relative
# self-path resolves against the caller's NEW cwd → the control-plane root derives wrong/empty →
# Fabrica-self mis-resolves to UNSET (or a decoy `<cwd>/NORTH_STAR.md` is misread as Fabrica's).
# Fix 1 absolutizes __ns_self ONCE at source time, so a later cd can't move the root.
# This suite's OTHER tests mask this: they source via an ABSOLUTE $lib and never cd away. Here we
# reproduce the real consumer shape — source relatively from the repo root, cd to /, then resolve
# the repo root itself (which IS the control plane) — and assert FABRICA_SELF, not UNSET. The
# path-identity check (Fix 2) makes this gh-free. A separate DECOY assert proves a cd'd-to dir
# that merely CONTAINS a NORTH_STAR.md is not mistaken for Fabrica's root.
test_relative_source_cd_away() {
  # $repo_root: the control plane this test file lives in (repo-root/scripts/test → up two).
  local repo_root; repo_root="$(cd "$test_dir/../.." && pwd -P)"
  local out kind rc
  out="$(bash -c '
    set -euo pipefail
    cd "$1"
    . scripts/lib/north-star.sh   # RELATIVE source, as a real consumer would
    cd /                          # …then cd far away; the pre-fix root derivation breaks here
    ns_resolve "$2"
  ' _ "$repo_root" "$repo_root" 2>/dev/null)" && rc=0 || rc=$?
  kind="${out%% *}"
  assert_eq "(g) relative-source + cd-away still resolves FABRICA_SELF (not UNSET)" "FABRICA_SELF" "$kind"
  assert_eq "(g) relative-source + cd-away does not abort under set -e (exit 0)" "0" "$rc"

  # Decoy: cd into a NON-Fabrica dir that happens to hold a NORTH_STAR.md, sourced relatively,
  # then resolve a plain external target. The resolver must NOT treat the decoy cwd as Fabrica's
  # root (which pre-fix could happen when the relative self-path collapsed to $PWD). With gh
  # unavailable (stubbed to fail) the external target has no slug and no path match → UNSET.
  local decoy; decoy="$tmproot/decoy-cwd"
  mkdir -p "$decoy"
  echo "decoy root star" > "$decoy/NORTH_STAR.md"
  local ext; ext="$(make_repo "relsrc-external")"
  local fakebin; fakebin="$tmproot/relsrc-fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  local dout dkind
  dout="$(bash -c '
    set -euo pipefail
    export PATH="$3:$PATH"
    cd "$1"
    . scripts/lib/north-star.sh
    cd "$4"                       # cwd now holds a decoy NORTH_STAR.md
    ns_resolve "$2"
  ' _ "$repo_root" "$ext" "$fakebin" "$decoy" 2>/dev/null)"
  dkind="${dout%% *}"
  assert_eq "(g) decoy cwd NORTH_STAR.md is NOT read as Fabrica's root (external → UNSET)" "UNSET" "$dkind"
}

# --- (h) offline resolve of the control plane is truly gh-FREE via the PATH short-circuit (P2) ---
# When gh is unavailable/unauthenticated, ns_repo_slug/ns_fabrica_slug return empty, so the
# slug-based identity match can't fire. The gh-free PATH identity (target toplevel ==
# ns_fabrica_root) resolves Fabrica-self offline — AND, per the round-3 [P2], it must SHORT-CIRCUIT
# before any slug derivation, so resolving the shipped control-plane checkout never calls `gh` at
# all. We stub a `gh` on PATH that RECORDS every invocation (and fails), resolve the real control-
# plane root (its git toplevel equals ns_fabrica_root), and assert FABRICA_SELF with the gh-call
# count at ZERO — proving the path check answered without touching gh.
test_offline_fabrica_self_via_path() {
  local repo_root; repo_root="$(cd "$test_dir/../.." && pwd -P)"
  local fakebin; fakebin="$tmproot/offline-fakebin"
  mkdir -p "$fakebin"
  local ghlog="$tmproot/offline-gh-invocations.log"
  : > "$ghlog"
  # Fake gh: append a marker on EVERY invocation, then fail. If the path check short-circuits, this
  # is never run and the log stays empty; if any slug derivation fires, the log gains a line.
  cat >"$fakebin/gh" <<GH
#!/usr/bin/env bash
echo "gh-called" >> "$ghlog"
exit 1
GH
  chmod +x "$fakebin/gh"
  local out kind rc
  out="$(bash -c '
    set -euo pipefail
    export PATH="$2:$PATH"
    . "$1/scripts/lib/north-star.sh"
    ns_resolve "$1"
  ' _ "$repo_root" "$fakebin" 2>/dev/null)" && rc=0 || rc=$?
  kind="${out%% *}"
  assert_eq "(h) offline (gh unavailable) still resolves FABRICA_SELF via the path check" "FABRICA_SELF" "$kind"
  assert_eq "(h) offline resolve does not abort under set -e (exit 0)" "0" "$rc"
  # The load-bearing round-3 [P2] assert: the path short-circuit means gh was NEVER invoked.
  local ghcalls; ghcalls="$(wc -l < "$ghlog" | tr -d ' ')"
  assert_eq "(h) control-plane self-resolve is gh-FREE — path check short-circuits (0 gh calls)" "0" "$ghcalls"
}

# --- (i) ns_repo_slug neutralizes CDPATH (no wrong-dir landing / no path leak) (P3) ---
# With CDPATH set, a bare `cd <relative>` can resolve <dir> against a CDPATH entry (landing in the
# WRONG directory) AND echo the chosen path to stdout — which would be captured as part of the
# slug. Fix 3 does `( unset CDPATH; cd -P -- "$dir" … )`. We set CDPATH to a dir containing a
# `child` sibling, run ns_repo_slug with the relative arg `child` from a cwd that also has `child`,
# and use a fake gh that prints a FIXED slug — so the ONLY way the output changes is a leaked cd
# path prefix. Assert the output is EXACTLY the slug (no extra path line).
test_slug_ignores_cdpath() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"   # restore the real ns_repo_slug (earlier tests unset -f their stub)
  local base; base="$tmproot/cdpath-base"
  mkdir -p "$base/here/child" "$base/elsewhere/child"
  local fakebin; fakebin="$tmproot/cdpath-fakebin"
  mkdir -p "$fakebin"
  # Fixed slug regardless of cwd/env — the assertion catches a leaked path line, not a wrong slug.
  printf '#!/usr/bin/env bash\necho "fixed/slug"\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  local out
  # shellcheck disable=SC2030,SC2031  # PATH/CDPATH scoped to this $()-subshell on purpose (no leak).
  out="$( cd "$base/here"; export PATH="$fakebin:$PATH" CDPATH="$base/elsewhere"; ns_repo_slug "child" )"
  assert_eq "(i) ns_repo_slug with CDPATH set returns EXACTLY the slug (no leaked path)" "fixed/slug" "$out"
}

# --- (j) ns_repo_slug rejects an empty arg (does NOT query the cwd) (P3) -----------
# An empty <dir> made `cd ""` a silent no-op, so gh ran in the caller's INHERITED cwd and returned
# the WRONG repo's slug instead of nothing. Fix 4 guards with `[ -n "$dir" ] || return 1`. We stub
# a fake gh that WOULD print a cwd slug if reached; assert ns_repo_slug "" returns non-zero and
# empty — proving the empty arg never falls through to a gh query.
test_slug_empty_arg() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"   # restore the real ns_repo_slug
  local fakebin; fakebin="$tmproot/emptyarg-fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\necho "cwd/should-not-appear"\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  local out rc
  # shellcheck disable=SC2030,SC2031  # PATH scoped to this $()-subshell on purpose (no leak).
  out="$( export PATH="$fakebin:$PATH"; ns_repo_slug "" )" && rc=0 || rc=$?
  assert_eq "(j) ns_repo_slug \"\" returns empty (does NOT query the cwd's slug)" "" "$out"
  assert_eq "(j) ns_repo_slug \"\" returns non-zero" "1" "$rc"
}

# --- (k) ns_fabrica_root under set -e from a deleted sourced tree → rc 0, empty (P3) --
# ns_fabrica_root's final `( cd … && pwd -P )` lacked `2>/dev/null`/`|| true` (unlike its sibling
# value-helpers). If the sourced tree is deleted out from under a long-running `set -euo pipefail`
# consumer, the `cd` fails, aborting the caller AND leaking a `cd: … No such file` warning. Fix 5
# adds `2>/dev/null` + `|| true`. We source a COPY of the lib in a temp tree, delete the tree, then
# call ns_fabrica_root as a TOP-LEVEL command under set -e; assert rc 0, empty stdout, empty stderr.
test_fabrica_root_errexit_deleted_tree() {
  local sandbox; sandbox="$tmproot/deleted-tree-sandbox"
  mkdir -p "$sandbox/scripts/lib"
  cp "$lib" "$sandbox/scripts/lib/north-star.sh"
  local out rc err
  # Capture stdout and stderr separately: assert no stderr leak AND rc 0 AND empty stdout.
  err="$tmproot/deleted-tree-stderr.log"
  out="$(bash -c '
    set -euo pipefail
    . "$1/scripts/lib/north-star.sh"
    rm -rf "$1"                 # yank the sourced tree out from under us
    ns_fabrica_root             # TOP-LEVEL command — a $() wrapper could mask the abort
  ' _ "$sandbox" 2>"$err")" && rc=0 || rc=$?
  assert_eq "(k) ns_fabrica_root under set -e from a deleted tree does NOT abort (exit 0)" "0" "$rc"
  assert_eq "(k) ns_fabrica_root under set -e from a deleted tree prints nothing" "" "$out"
  assert_eq "(k) ns_fabrica_root under set -e from a deleted tree leaks no stderr" "" "$(cat "$err")"
}

echo "== north-star resolver tests =="
test_local_wins
test_subdir_resolves_toplevel
test_fabrica_self_fallback
test_fabrica_self_case_insensitive
test_non_fabrica_no_fallback
test_doctor_slug_mismatch
test_unset_and_empty
test_resolve_errexit_safe_non_git
test_slug_ignores_gh_repo
test_slug_eq_case_insensitive
test_relative_source_cd_away
test_offline_fabrica_self_via_path
test_slug_ignores_cdpath
test_slug_empty_arg
test_fabrica_root_errexit_deleted_tree

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
