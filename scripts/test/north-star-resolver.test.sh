#!/usr/bin/env bash
set -euo pipefail

# north-star-resolver.test.sh — bash asserts for the per-target north-star RESOLVER
# (scripts/lib/north-star.sh), issue #97 / PR #99, renamed for the ystack product name.
#
# This suite covers the resolver lib in isolation (the consumers — doctor.sh,
# setup-target-repo.sh, manager-review.sh — are asserted end-to-end in
# scripts/test/north-star-gate.test.sh). OFFLINE and hermetic (no gh/network): the tests stub
# `ns_repo_slug` for deterministic repo identity, and the GH_REPO test runs the real helper
# against a FAKE `gh` on PATH. Every case builds throwaway git repos in temp dirs.
#
# Resolver (scripts/lib/north-star.sh):
#   (a) a non-control-plane target's local `.ystack/north-star.md` resolves LOCAL.
#   (a2) [rename fallback] a target still on the LEGACY `.fabrica/north-star.md` (no `.ystack/`)
#       still resolves LOCAL at the legacy path — old targets keep working.
#   (a3) [rename precedence] when BOTH `.ystack/` and `.fabrica/` stars exist, the canonical
#       `.ystack/north-star.md` wins.
#   (b) a SUBDIRECTORY invocation still resolves the top-level `.ystack/north-star.md`.
#   (c) ystack-self by PATH identity (target toplevel == ns_ystack_root) falls back to root
#       NORTH_STAR.md (#98a: PATH-only, no slug).
#   (c-spoof) [P1 SECURITY, #98a] a target whose SLUG spoofs the control plane's own but whose
#       PATH is NOT ystack_root is NOT YSTACK_SELF — the attacker-settable slug fallback is
#       dropped → UNSET.
#   (c-prec) [#98a] the ystack-self PATH identity has PRECEDENCE over the LOCAL branch, so a stray
#       committed per-target star (canonical or legacy) in the control-plane checkout can't shadow
#       the root star.
#   (c-committed) [round-2 regression] committed root NORTH_STAR.md whose worktree copy is DELETED
#       still resolves YSTACK_SELF (classification never stats the working tree).
#   (c-no-committed-root) [P2, round-3] the control-plane checkout with NO committed NORTH_STAR.md
#       and a STRAY committed `.ystack/north-star.md` still classifies YSTACK_SELF (not LOCAL):
#       classification is identity-only and UNCONDITIONAL, so the per-target star can never shadow
#       ystack-self; AUTHORIZATION (root actually committed) is the gate's job (it FAILs on the
#       missing root).
#   (c-worktree) [P2, round-3] a LINKED WORKTREE of the control plane (shares the main checkout's
#       git common-dir) classifies YSTACK_SELF — the common case (yshifu runs from
#       `.claude/worktrees/*`); the old strict top-level PATH compare misclassified it as external.
#   (c-worktree-neg) [P2, round-3] a genuinely SEPARATE external repo (different git common-dir) is
#       NOT falsely classified ystack-self by the widened identity check → still UNSET.
#   (c') a NON-control-plane repo with no local star does NOT inherit the root fallback (PATH
#       identity, not "file exists") → UNSET.
#   (m) [FIX A] the shared shipped-default marker matcher is active-region-SCOPED and
#       whitespace/case-insensitive: every spacing/casing/reflow-split variant on the active
#       heading matches, while a marker only in prose (correctly-replaced star) does not.
#   (m2) [rename fallback] the LEGACY marker token (`fabrica-shipped-default`) still counts as the
#       marker — an old un-replaced placeholder keeps failing; a legacy prose-only mention still
#       does not.
#   (d) a doctor-style cwd/slug MISMATCH does NOT read the local file (the resolver reports
#       the local star only for the matching repo; a mismatched cwd is handled by doctor.sh
#       fetching remote — asserted here at the slug-comparison level the caller relies on).
#   (e) a non-empty target with NEITHER resolves to UNSET (manager-review FAILs on this;
#       doctor WARNs) — and an EMPTY (commit-less) target is the benign EMPTY case, not UNSET;
#       a non-repo path is NOREPO.
#   (f) `ns_repo_slug` clears a set GH_REPO so the slug reflects the repo at <dir>.
#   (f2) `ns_slug_eq` compares slugs CASE-INSENSITIVELY (acme/myrepo == Acme/MyRepo), keeps
#       genuinely different repos different (P2, round-2).
#   (g) relative-source + cd-away still resolves YSTACK_SELF, and a decoy cwd NORTH_STAR.md is
#       not mistaken for the control plane's root — the __ns_self absolutize-at-source-time fix
#       (P1, round-3).
#   (h) offline (gh stubbed to fail) still resolves ystack-self via the gh-free PATH identity
#       check (P2, round-3).
#   (i) `ns_repo_slug` neutralizes a set CDPATH — no wrong-dir landing, no leaked path on stdout
#       (P3, round-3).
#   (j) `ns_repo_slug ""` returns non-zero/empty — an empty arg never falls through to the cwd's
#       slug (P3, round-3).
#   (k) `ns_ystack_root` under `set -euo pipefail` from a deleted sourced tree yields rc 0, empty
#       stdout, and no stderr leak — matching the sibling value-helpers (P3, round-3).
#   (q) [P1, round-3 SIGPIPE] ns_has_shipped_default_marker DRAINS stdin: a LARGE committed star
#       (placeholder marker in the active entry + tens of KB of body after the next heading, big
#       enough to fill the pipe buffer) still reports "marker present" under `set -o pipefail` —
#       the old `exit`-early awk SIGPIPE'd the upstream printf (141), which pipefail turned into a
#       FALSE "no marker" → placeholder-FAIL bypass. The fix drains to EOF so the verdict holds.
#
# Cases (g)–(k) were surfaced by an adversarial audit; each reproduces a bug the prior suite
# MASKED because it sourced via an ABSOLUTE path and never cd'd away / never stubbed gh-missing.
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

# --- (a) local .ystack/north-star.md wins over the root fallback ------------------
# A non-control-plane target with a local star must resolve LOCAL. Identity is PATH-based, so we
# stub ns_ystack_root to a NON-matching path (this throwaway repo is not the control plane),
# proving the LOCAL branch — not the ystack-self fallback — is what wins.
test_local_wins() {
  local repo; repo="$(make_repo "target-a")"
  mkdir -p "$repo/.ystack"
  echo "local star A" > "$repo/.ystack/north-star.md"
  ns_ystack_root() { echo "$tmproot/not-the-ystack-root"; }   # not ystack-self (PATH differs)
  # Canonicalize the expected path through git's own top-level (macOS resolves /var ->
  # /private/var); the resolver returns the canonical top-level, so compare like-for-like.
  local expect; expect="$(ns_git_toplevel "$repo")/.ystack/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(a) kind is LOCAL when .ystack/north-star.md exists" "LOCAL" "$kind"
  assert_eq "(a) resolved path is the local star" "$expect" "$path"
  unset -f ns_ystack_root
}

# --- (a2) LEGACY .fabrica/north-star.md still resolves LOCAL (rename fallback) -----
# A target that has not renamed yet only has the legacy `.fabrica/north-star.md`. It must still
# resolve LOCAL at that legacy path — the rename must not break existing targets.
test_local_legacy_fallback() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "target-legacy")"
  mkdir -p "$repo/.fabrica"
  echo "legacy local star" > "$repo/.fabrica/north-star.md"
  ns_ystack_root() { echo "$tmproot/not-the-ystack-root"; }   # not ystack-self (PATH differs)
  local expect; expect="$(ns_git_toplevel "$repo")/.fabrica/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(a2) legacy-only target (.fabrica, no .ystack) still resolves LOCAL" "LOCAL" "$kind"
  assert_eq "(a2) resolved path is the LEGACY .fabrica/north-star.md" "$expect" "$path"
  unset -f ns_ystack_root
}

# --- (a3) when BOTH stars exist, the canonical .ystack path wins -------------------
# A target mid-rename may briefly carry both files. The canonical `.ystack/north-star.md` must
# win, so the renamed file is the one that steers.
test_local_canonical_wins_over_legacy() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "target-both")"
  mkdir -p "$repo/.ystack" "$repo/.fabrica"
  echo "canonical star" > "$repo/.ystack/north-star.md"
  echo "legacy star" > "$repo/.fabrica/north-star.md"
  ns_ystack_root() { echo "$tmproot/not-the-ystack-root"; }   # not ystack-self (PATH differs)
  local expect; expect="$(ns_git_toplevel "$repo")/.ystack/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(a3) both stars present → LOCAL" "LOCAL" "$kind"
  assert_eq "(a3) the canonical .ystack/north-star.md wins over the legacy file" "$expect" "$path"
  unset -f ns_ystack_root
}

# --- (b) subdirectory invocation resolves the top-level file ----------------------
# Regression guard: run the resolver from a NESTED dir; it must walk up to the git top-level's
# .ystack/north-star.md, not fail or read $PWD literally.
test_subdir_resolves_toplevel() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "target-b")"
  mkdir -p "$repo/.ystack"
  echo "local star B" > "$repo/.ystack/north-star.md"
  mkdir -p "$repo/deeply/nested/dir"
  ns_ystack_root() { echo "$tmproot/not-the-ystack-root"; }   # not ystack-self (PATH differs)
  local expect; expect="$(ns_git_toplevel "$repo")/.ystack/north-star.md"
  local out kind path
  out="$(ns_resolve "$repo/deeply/nested/dir")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(b) subdir invocation resolves LOCAL" "LOCAL" "$kind"
  assert_eq "(b) subdir invocation resolves the TOP-LEVEL star" "$expect" "$path"
  unset -f ns_ystack_root
}

# --- (c) ystack-self identity → root NORTH_STAR.md fallback (PATH-only, #98a) ------
# A repo with NO local per-target star whose PATH is the control plane's own root must fall back
# to the control-plane root NORTH_STAR.md. Identity is decided by PATH (the target's git
# top-level == ns_ystack_root), NOT a slug (see (c-spoof) below). We stub ns_ystack_root to the
# target's OWN canonical top-level so the path check matches, and place a throwaway
# NORTH_STAR.md there.
test_ystack_self_fallback() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "ystack-clone")"
  # No per-target star here — force the identity/fallback path.
  local top; top="$(ns_git_toplevel "$repo")"   # canonical top-level (matches what ns_resolve derives)
  # Commit the root star (the normal control-plane state). CLASSIFICATION is PATH-only
  # (round-3 [P2]) and does NOT require a committed root — see (c-no-committed-root) for the
  # uncommitted case — but this test asserts the ordinary path with a committed root present.
  echo "root ystack star" > "$top/NORTH_STAR.md"
  git -C "$top" add NORTH_STAR.md
  git -C "$top" commit -q -m "root star"
  ns_ystack_root() { echo "$top"; }             # PATH identity: target toplevel == control-plane root
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c) ystack-self PATH identity falls back to YSTACK_SELF" "YSTACK_SELF" "$kind"
  assert_eq "(c) fallback path is root NORTH_STAR.md" "$top/NORTH_STAR.md" "$path"
  unset -f ns_ystack_root
}

# --- (c-spoof) SLUG-SPOOF must NOT be YSTACK_SELF [P1 SECURITY, #98a] --------------
# The old resolver had a slug-based self fallback: target slug == the control plane's slug →
# self. The slug derives from the git REMOTE URL, which ANY clone owner can set, so a hostile
# target pointing origin at the control plane's slug would be authorized against its root star,
# bypassing its own star AND the placeholder-FAIL. #98a DROPS the slug fallback: identity is
# PATH-only. Here the target's slug EQUALS the control plane's own, but its PATH is NOT
# ystack_root — so it must resolve as its OWN repo (UNSET, no local star), NEVER YSTACK_SELF.
test_slug_spoof_not_ystack_self() {
  # Re-source in case an earlier test's `unset -f` removed a helper we rely on.
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "slug-spoof-target")"   # non-empty, NO local star
  local fake_root="$tmproot/real-ystack-root"
  mkdir -p "$fake_root"
  echo "ystack root star" > "$fake_root/NORTH_STAR.md"
  # Attacker sets the target's slug to match the control plane's own — but the PATH differs.
  # These two slug stubs are deliberately NEVER invoked by ns_resolve: that is the FIX — the
  # resolver no longer consults ANY slug for identity, so the spoofed slug can't authorize.
  # (Intentionally uninvoked; they model the attacker-controlled slug the resolver now ignores.
  # Shellcheck flags them as SC2317 on 0.9.0 and SC2329 on 0.11.0 — disable both so either
  # version stays clean.)
  # shellcheck disable=SC2317,SC2329
  ns_repo_slug()   { echo "yihanzhu/ystack"; }   # spoofed: same slug as the control plane (IGNORED now)
  # shellcheck disable=SC2317,SC2329
  ns_ystack_slug() { echo "yihanzhu/ystack"; }   # the control plane's own slug (IGNORED now)
  ns_ystack_root() { echo "$fake_root"; }         # PATH: control-plane root != the target's toplevel
  local out kind
  out="$(ns_resolve "$repo")"; kind="${out%% *}"
  assert_eq "(c-spoof) target whose SLUG spoofs the control plane but whose PATH differs → NOT YSTACK_SELF (UNSET)" "UNSET" "$kind"
  unset -f ns_repo_slug ns_ystack_slug ns_ystack_root
}

# --- (c-prec) ystack-self PATH identity has PRECEDENCE over a stray LOCAL star [#98a] ---
# A stray committed per-target star accidentally sitting in the control-plane checkout must NOT
# shadow the control plane's own root star: the PATH identity is checked BEFORE the LOCAL branch,
# so the control-plane checkout still resolves YSTACK_SELF (root NORTH_STAR.md), not LOCAL. We
# plant BOTH the canonical `.ystack/` and the legacy `.fabrica/` stray stars — neither may shadow.
test_ystack_self_precedence_over_local() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "ystack-self-with-stray-local")"
  local top; top="$(ns_git_toplevel "$repo")"
  # Commit the root star (the normal state) PLUS stray local stars also committed inside the
  # control-plane checkout — which must NOT shadow the root star (PATH identity has precedence).
  echo "ystack root star" > "$top/NORTH_STAR.md"
  mkdir -p "$top/.ystack" "$top/.fabrica"
  echo "stray canonical local star that must not shadow root" > "$top/.ystack/north-star.md"
  echo "stray legacy local star that must not shadow root" > "$top/.fabrica/north-star.md"
  git -C "$top" add NORTH_STAR.md .ystack/north-star.md .fabrica/north-star.md
  git -C "$top" commit -q -m "root star + stray locals"
  ns_ystack_root() { echo "$top"; }               # PATH identity: this IS the control-plane root
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c-prec) stray per-target stars in ystack-self do NOT shadow root → YSTACK_SELF" "YSTACK_SELF" "$kind"
  assert_eq "(c-prec) YSTACK_SELF path is the ROOT NORTH_STAR.md (not a stray local star)" "$top/NORTH_STAR.md" "$path"
  unset -f ns_ystack_root
}

# --- (c-committed) YSTACK_SELF even if the worktree copy is DELETED (committed root present) ---
# Classification is PATH-only (round-3 [P2]) — it does not stat the working tree at all — so a
# control plane whose NORTH_STAR.md is COMMITTED but whose working-tree copy was deleted STILL
# resolves YSTACK_SELF. This is the case the gate authorizes: path→YSTACK_SELF here, and the
# gate's `git show HEAD:NORTH_STAR.md` succeeds off the committed blob. (Regression from round-2
# FIX 1; still green under the path-only classification.)
test_ystack_self_committed_worktree_deleted() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "ystack-self-committed-del")"
  local top; top="$(ns_git_toplevel "$repo")"
  echo "committed ystack root star" > "$top/NORTH_STAR.md"
  git -C "$top" add NORTH_STAR.md
  git -C "$top" commit -q -m "commit root star"
  rm -f "$top/NORTH_STAR.md"                        # worktree copy gone; HEAD still has it
  ns_ystack_root() { echo "$top"; }                 # PATH identity: this IS the control-plane root
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c-committed) committed NORTH_STAR.md, worktree copy DELETED → still YSTACK_SELF (not UNSET)" "YSTACK_SELF" "$kind"
  assert_eq "(c-committed) YSTACK_SELF path is the root NORTH_STAR.md" "$top/NORTH_STAR.md" "$path"
  unset -f ns_ystack_root
}

# --- (c-no-committed-root) PATH identity classifies YSTACK_SELF even with NO committed root [P2, round-3] ---
# The core round-3 [P2] fix: CLASSIFICATION is PATH-only and UNCONDITIONAL — it must NOT be gated
# on whether NORTH_STAR.md is committed. Here the cwd IS the control-plane checkout but
# NORTH_STAR.md is NOT committed, AND a stray `.ystack/north-star.md` IS committed. Round-2's
# committed-existence gate would have fallen THROUGH to the LOCAL branch and authorized off the
# stray per-target star. The resolver must instead classify YSTACK_SELF (root NORTH_STAR.md), so
# the per-target star can NEVER shadow ystack-self; the AUTHORIZATION (root actually committed)
# is then the gate's job (it FAILs cleanly on the missing committed root — asserted in the gate
# suite).
test_ystack_self_no_committed_root_ignores_stray_local() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "ystack-self-no-committed-root")"
  local top; top="$(ns_git_toplevel "$repo")"
  # NO NORTH_STAR.md committed (and none in the worktree). A STRAY .ystack/north-star.md IS committed.
  mkdir -p "$top/.ystack"
  echo "stray local star that must NOT be authorized as ystack-self" > "$top/.ystack/north-star.md"
  git -C "$top" add .ystack/north-star.md
  git -C "$top" commit -q -m "stray local star, no root star"
  ns_ystack_root() { echo "$top"; }                 # PATH identity: this IS the control-plane root
  local out kind path
  out="$(ns_resolve "$repo")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c-no-committed-root) no committed root + stray committed .ystack → still YSTACK_SELF (not LOCAL)" "YSTACK_SELF" "$kind"
  assert_eq "(c-no-committed-root) YSTACK_SELF path is the root NORTH_STAR.md (not the stray local star)" "$top/NORTH_STAR.md" "$path"
  unset -f ns_ystack_root
}

# --- (c-worktree) a LINKED WORKTREE of the control plane is YSTACK_SELF [P2, round-3] ---
# The [P2] fix: yshifu operates from a linked worktree (`.claude/worktrees/*`) of the
# control-plane repo. A linked worktree's `git rev-parse --show-toplevel` is the WORKTREE path,
# NOT the main checkout, so the old strict `toplevel == ystack_root` compare FALSELY FAILed →
# the control plane's own worktree was misclassified as an EXTERNAL target (skipping the root
# NORTH_STAR.md). A linked worktree SHARES its parent repo's git COMMON-DIR, so classifying by
# common-dir makes the worktree resolve as ystack-self. Here we build a real control-plane clone
# (committed root star), add a linked worktree with `git worktree add`, stub ns_ystack_root to
# the MAIN checkout, and assert the worktree resolves YSTACK_SELF (root NORTH_STAR.md), NOT
# UNSET/LOCAL.
test_ystack_self_linked_worktree() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local main; main="$(make_repo "ystack-wt-main")"
  local top; top="$(ns_git_toplevel "$main")"     # git-canonical main checkout top-level
  echo "root ystack star" > "$top/NORTH_STAR.md"
  git -C "$top" add NORTH_STAR.md
  git -C "$top" commit -q -m "root star"
  # A linked worktree of the SAME repo — the shape yshifu runs from (.claude/worktrees/*).
  local wt="$top/.claude/worktrees/feature"
  git -C "$top" worktree add -q --detach "$wt" HEAD 2>/dev/null
  # ns_ystack_root points at the MAIN checkout (as it would when the lib ships there). The
  # worktree's top-level differs, but its git common-dir is the MAIN checkout's — so the
  # common-dir identity check must classify it ystack-self.
  ns_ystack_root() { echo "$top"; }
  local out kind path
  out="$(ns_resolve "$wt")"
  kind="${out%% *}"; path="${out#"$kind"}"; path="${path# }"
  assert_eq "(c-worktree) linked worktree of the control-plane repo → YSTACK_SELF (not external)" "YSTACK_SELF" "$kind"
  assert_eq "(c-worktree) YSTACK_SELF path is the MAIN checkout's root NORTH_STAR.md" "$top/NORTH_STAR.md" "$path"
  unset -f ns_ystack_root
  git -C "$top" worktree remove --force "$wt" 2>/dev/null || true
}

# --- (c-worktree-neg) a SEPARATE external repo (different common-dir) is NOT falsely self [P2] ---
# The negative guard for the common-dir identity: a genuinely separate repo has its OWN git
# common-dir, so it must NOT be classified ystack-self even though the fix widened the identity
# check. Here ystack_root points at one repo; the target is a DIFFERENT repo with no local star →
# its common-dir differs → NOT YSTACK_SELF → UNSET (non-empty target). This proves the widened
# check did not over-match.
test_ystack_self_worktree_negative_separate_repo() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local cp; cp="$(make_repo "wt-neg-ystack")"
  local cptop; cptop="$(ns_git_toplevel "$cp")"
  echo "root ystack star" > "$cptop/NORTH_STAR.md"
  git -C "$cptop" add NORTH_STAR.md
  git -C "$cptop" commit -q -m "root star"
  local ext; ext="$(make_repo "wt-neg-external")"   # a genuinely separate repo, no local star
  ns_ystack_root() { echo "$cptop"; }               # the control plane is a DIFFERENT repo than the target
  local out kind
  out="$(ns_resolve "$ext")"; kind="${out%% *}"
  assert_eq "(c-worktree-neg) separate repo (different git common-dir) → NOT YSTACK_SELF (UNSET)" "UNSET" "$kind"
  unset -f ns_ystack_root
}

# A NON-control-plane repo with no local star must NOT inherit the root fallback (PATH identity,
# not "file exists"): its top-level != ystack_root, so the fallback is skipped and, being
# non-empty, it resolves to UNSET.
test_non_ystack_no_fallback() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "external-target")"
  local fake_root="$tmproot/fake-ystack-root2"
  mkdir -p "$fake_root"
  echo "root ystack star" > "$fake_root/NORTH_STAR.md"
  ns_ystack_root() { echo "$fake_root"; }          # control-plane root != the target's toplevel (PATH differs)
  local out kind
  out="$(ns_resolve "$repo")"; kind="${out%% *}"
  assert_eq "(c') non-control-plane repo with no local star does NOT use root fallback (UNSET)" "UNSET" "$kind"
  unset -f ns_ystack_root
}

# --- (d) doctor-style cwd/slug mismatch does NOT read the local file --------------
# doctor.sh reads a LOCAL star only when the cwd's resolved slug matches the <owner>/<repo>
# argument; on a mismatch it must fetch remote instead of misattributing the cwd's star. We
# assert the decision the caller makes on the resolver's slug output: a cwd resolving to slug
# X must NOT be treated as target Y even though a local .ystack/north-star.md exists.
test_doctor_slug_mismatch() {
  local repo; repo="$(make_repo "some-checkout")"
  mkdir -p "$repo/.ystack"
  echo "some other repo's star" > "$repo/.ystack/north-star.md"
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
  # Re-source so the real ns_ystack_root is present (identity is PATH-based); stub it to a
  # non-matching path so these throwaway repos are never mistaken for ystack-self.
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  ns_ystack_root() { echo "$tmproot/not-the-ystack-root"; }

  # Non-empty repo (has a commit), no local star, not the control plane → UNSET.
  local repo; repo="$(make_repo "target-e")"
  local out kind
  out="$(ns_resolve "$repo")"; kind="${out%% *}"
  assert_eq "(e) non-empty target, no star → UNSET (manager-review FAIL / doctor WARN)" "UNSET" "$kind"

  # Empty repo (git init, NO commits), no local star → EMPTY (benign, not UNSET).
  local empty="$tmproot/target-empty"
  mkdir -p "$empty"
  git -C "$empty" init -q
  out="$(ns_resolve "$empty")"; kind="${out%% *}"
  assert_eq "(e) empty (commit-less) target → EMPTY, not UNSET" "EMPTY" "$kind"
  unset -f ns_ystack_root

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
# canonical `Acme/MyRepo` name the SAME repo. The consumers route each slug compare through
# ns_slug_eq (not a bare `=`), so a case mismatch must NOT be treated as a different target.
# Also assert genuinely different slugs stay unequal, and that two empty slugs are NOT relied
# upon (callers still guard on non-emptiness so an unresolved cwd never matches).
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
# The pre-fix root helper re-read `${BASH_SOURCE[0]}` lazily. When a consumer sources the lib
# via a RELATIVE path (`. scripts/lib/north-star.sh`) and then cd's into a target, that relative
# self-path resolves against the caller's NEW cwd → the control-plane root derives wrong/empty →
# ystack-self mis-resolves to UNSET (or a decoy `<cwd>/NORTH_STAR.md` is misread as the control
# plane's). Fix 1 absolutizes __ns_self ONCE at source time, so a later cd can't move the root.
# This suite's OTHER tests mask this: they source via an ABSOLUTE $lib and never cd away. Here we
# reproduce the real consumer shape — source relatively from the repo root, cd to /, then resolve
# the repo root itself (which IS the control plane) — and assert YSTACK_SELF, not UNSET. The
# path-identity check (Fix 2) makes this gh-free. A separate DECOY assert proves a cd'd-to dir
# that merely CONTAINS a NORTH_STAR.md is not mistaken for the control plane's root.
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
  assert_eq "(g) relative-source + cd-away still resolves YSTACK_SELF (not UNSET)" "YSTACK_SELF" "$kind"
  assert_eq "(g) relative-source + cd-away does not abort under set -e (exit 0)" "0" "$rc"

  # Decoy: cd into a NON-control-plane dir that happens to hold a NORTH_STAR.md, sourced
  # relatively, then resolve a plain external target. The resolver must NOT treat the decoy cwd
  # as the control plane's root (which pre-fix could happen when the relative self-path collapsed
  # to $PWD). With gh unavailable (stubbed to fail) the external target has no slug and no path
  # match → UNSET.
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
  assert_eq "(g) decoy cwd NORTH_STAR.md is NOT read as the control plane's root (external → UNSET)" "UNSET" "$dkind"
}

# --- (h) offline resolve of the control plane is truly gh-FREE via the PATH short-circuit (P2) ---
# When gh is unavailable/unauthenticated, ns_repo_slug/ns_ystack_slug return empty, so a
# slug-based identity match can't fire. The gh-free PATH identity (target toplevel ==
# ns_ystack_root) resolves ystack-self offline — AND, per the round-3 [P2], it must SHORT-CIRCUIT
# before any slug derivation, so resolving the shipped control-plane checkout never calls `gh` at
# all. We stub a `gh` on PATH that RECORDS every invocation (and fails), resolve the real
# control-plane root (its git toplevel equals ns_ystack_root), and assert YSTACK_SELF with the
# gh-call count at ZERO — proving the path check answered without touching gh.
test_offline_ystack_self_via_path() {
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
  assert_eq "(h) offline (gh unavailable) still resolves YSTACK_SELF via the path check" "YSTACK_SELF" "$kind"
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
  local fakebin="$tmproot/emptyarg-fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\necho "cwd/should-not-appear"\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  local out rc
  # shellcheck disable=SC2030,SC2031  # PATH scoped to this $()-subshell on purpose (no leak).
  out="$( export PATH="$fakebin:$PATH"; ns_repo_slug "" )" && rc=0 || rc=$?
  assert_eq "(j) ns_repo_slug \"\" returns empty (does NOT query the cwd's slug)" "" "$out"
  assert_eq "(j) ns_repo_slug \"\" returns non-zero" "1" "$rc"
}

# --- (k) ns_ystack_root under set -e from a deleted sourced tree → rc 0, empty (P3) --
# ns_ystack_root's final `( cd … && pwd -P )` lacked `2>/dev/null`/`|| true` (unlike its sibling
# value-helpers). If the sourced tree is deleted out from under a long-running `set -euo pipefail`
# consumer, the `cd` fails, aborting the caller AND leaking a `cd: … No such file` warning. Fix 5
# adds `2>/dev/null` + `|| true`. We source a COPY of the lib in a temp tree, delete the tree, then
# call ns_ystack_root as a TOP-LEVEL command under set -e; assert rc 0, empty stdout, empty stderr.
test_ystack_root_errexit_deleted_tree() {
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
    ns_ystack_root              # TOP-LEVEL command — a $() wrapper could mask the abort
  ' _ "$sandbox" 2>"$err")" && rc=0 || rc=$?
  assert_eq "(k) ns_ystack_root under set -e from a deleted tree does NOT abort (exit 0)" "0" "$rc"
  assert_eq "(k) ns_ystack_root under set -e from a deleted tree prints nothing" "" "$out"
  assert_eq "(k) ns_ystack_root under set -e from a deleted tree leaks no stderr" "" "$(cat "$err")"
}

# --- (n) ystack-self path compare is CASE-CANONICAL: both operands git-derived [FIX 3, round-2] ---
# ns_resolve's ystack-self identity test is `toplevel == ystack_root`. `toplevel` is
# git-canonical (`git rev-parse --show-toplevel`) but pre-fix `ystack_root` was a `pwd -P`
# (case-PRESERVING) — so on a case-insensitive filesystem a case-variant path made the two differ
# only in case → the control plane's own debate FAILed / setup polluted the control plane. Round-2
# canonicalizes ystack_root through git too. We assert the load-bearing INVARIANT (portable on
# both case-sensitive Linux CI and case-insensitive macOS): ns_ystack_root's output equals git's
# own top-level for that root — i.e. both sides of the identity compare are produced the SAME way.
# On a case-INSENSITIVE filesystem we ALSO source the lib via an UPPER-cased path component and
# confirm ns_ystack_root STILL returns the git-canonical (lower) casing (so the compare holds) —
# the exact regression; on a case-sensitive FS that variant path can't exist, so we skip it.
test_ystack_root_case_canonical() {
  # A throwaway "control-plane" clone that ships a copy of the lib at scripts/lib/north-star.sh.
  local cp; cp="$tmproot/case-cp"
  mkdir -p "$cp/scripts/lib"
  cp "$lib" "$cp/scripts/lib/north-star.sh"
  git -C "$cp" init -q
  git -C "$cp" commit -q --allow-empty -m "cp init"
  # Git-canonical top-level of this clone — what ns_git_toplevel yields for the identity compare.
  local canonical; canonical="$(git -C "$cp" rev-parse --show-toplevel)"

  # Invariant (portable): sourcing the lib via its REAL path, ns_ystack_root == the git-canonical
  # top-level, so `toplevel == ystack_root` is a like-for-like compare.
  local got; got="$(bash -c '. "$1/scripts/lib/north-star.sh"; ns_ystack_root' _ "$cp")"
  assert_eq "(n) ns_ystack_root is git-canonical (== git rev-parse --show-toplevel)" "$canonical" "$got"

  # Case-variant probe — only where the filesystem is case-insensitive (macOS): reach the SAME
  # clone through an upper-cased path component and confirm ns_ystack_root still returns the
  # git-canonical casing (NOT the upper-cased pwd), so the identity compare does not falsely differ.
  local probe; probe="$tmproot/CaseProbe"
  touch "$probe" 2>/dev/null || true
  if [ -e "$tmproot/caseprobe" ]; then
    rm -f "$probe"
    # Build an upper-cased spelling of the clone path's last component and source through it.
    local upper; upper="$tmproot/CASE-CP"
    # $upper and $cp are the SAME directory on a case-insensitive FS; source via the upper spelling.
    local got_upper; got_upper="$(bash -c '. "$1/scripts/lib/north-star.sh"; ns_ystack_root' _ "$upper")"
    assert_eq "(n) case-variant source path → ns_ystack_root still git-canonical (compare holds)" "$canonical" "$got_upper"
  else
    rm -f "$probe"
    passed=$((passed + 1))
    echo "pass: (n) case-variant probe skipped (case-sensitive filesystem — regression cannot occur here)"
  fi
}

# --- (o) ns_committed_is_regular_file resolves the pathspec from the git TOP-LEVEL [FIX 1, round-3] ---
# <relpath> is ROOT-relative, but pre-fix the helper ran `git -C "$dir" ls-tree "$commit" -- "$relpath"`
# with dir=$PWD. When the gate is invoked from a SUBDIRECTORY of the target (documented as supported),
# the ls-tree pathspec was interpreted relative to the subdir → the mode lookup returned EMPTY for a
# valid regular committed file → the round-2 symlink guard FALSELY reported "not a regular file". The
# fix resolves <dir> to its git top-level before ls-tree, so the root-relative pathspec is correct
# from ANY subdir. We assert: a regular committed star is recognized (rc 0) from BOTH the top-level
# AND a nested subdir; and a committed SYMLINK is still rejected (rc non-zero) from a subdir too.
test_committed_regular_file_from_subdir() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local repo; repo="$(make_repo "committed-regfile-subdir")"
  mkdir -p "$repo/.ystack"
  printf '### Ship v2 · status: **active** — real goal\nbody\n' > "$repo/.ystack/north-star.md"
  git -C "$repo" add .ystack/north-star.md
  git -C "$repo" commit -q -m "commit regular star"
  local sub="$repo/deeply/nested/dir"
  mkdir -p "$sub"

  # (o-i) From the TOP-LEVEL: a regular committed file is recognized (rc 0) — baseline.
  local rc; if ns_committed_is_regular_file "$repo" "HEAD" ".ystack/north-star.md"; then rc=0; else rc=1; fi
  assert_eq "(o) regular committed star from the TOP-LEVEL → regular file (rc 0)" "0" "$rc"

  # (o-ii) From a SUBDIRECTORY: the root-relative pathspec must still resolve (the FIX) — rc 0.
  if ns_committed_is_regular_file "$sub" "HEAD" ".ystack/north-star.md"; then rc=0; else rc=1; fi
  assert_eq "(o) regular committed star from a SUBDIR → regular file (rc 0), not falsely rejected" "0" "$rc"

  # (o-iii) A committed SYMLINK is still rejected (rc non-zero) even when checked from a SUBDIR.
  local symrepo; symrepo="$(make_repo "committed-symlink-subdir")"
  mkdir -p "$symrepo/.ystack"
  printf '### decoy · status: **active** — content\nbody\n' > "$symrepo/.ystack/decoy.md"
  ( cd "$symrepo/.ystack" && ln -s "decoy.md" "north-star.md" )
  git -C "$symrepo" add -A
  git -C "$symrepo" commit -q -m "commit symlink star"
  local symsub="$symrepo/nested/here"
  mkdir -p "$symsub"
  if ns_committed_is_regular_file "$symsub" "HEAD" ".ystack/north-star.md"; then rc=0; else rc=1; fi
  assert_eq "(o) committed SYMLINK from a SUBDIR → still rejected (rc non-zero)" "1" "$rc"
}

# --- (p) ns_active_region starts ONLY on a HEADING line carrying the active marker [FIX 2, round-3] ---
# Pre-fix, the region opened on ANY line containing `status: active`. A north-star file with PROSE or
# front-matter mentioning `status: active` BEFORE the real active heading would start the region there
# and END it at the next heading — so the shipped-default marker on the ACTUAL placeholder heading fell
# OUTSIDE the region and was never scanned → placeholder bypass (gate proceeds against a template). The
# fix anchors the region-start to a Markdown HEADING line (`^#{1,6}[[:space:]]`) that ALSO carries the
# marker. We assert: a prose `status: active` mention before the real (marked) active heading is STILL
# detected as a placeholder; and a normal single-heading active entry still works both ways.
test_active_region_heading_anchored() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  local _m
  _m() { if printf '%s' "$1" | ns_has_shipped_default_marker -; then echo yes; else echo no; fi; }

  # (p-i) Prose line mentioning `status: active` BEFORE the real active heading that carries the
  # marker → still a placeholder (the marker on the true active heading is scanned, not skipped).
  assert_eq "(p) prose 'status: active' before the marked active HEADING → still placeholder (match)" "yes" \
    "$(printf 'Front-matter: default status: active until you set one.\n\n### Placeholder · status: **active** · <!-- ystack-shipped-default --> shipped default\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"

  # (p-ii) The active region STARTS on the heading, not the prose line: the first region line is the
  # HEADING (proving the prose `status: active` did not open the region early).
  local first; first="$(printf 'Front-matter: default status: active until you set one.\n\n### Placeholder · status: **active** · <!-- ystack-shipped-default --> shipped\nbody\n' | ns_active_region - | head -n1)"
  assert_eq "(p) active region starts on the HEADING, not the earlier prose 'status: active' line" \
    "### Placeholder · status: **active** · <!-- ystack-shipped-default --> shipped" "$first"

  # (p-iii) A normal single-heading active entry (no marker) is NOT a placeholder — still works.
  assert_eq "(p) normal single-heading active entry (no marker) → not a placeholder (no match)" "no" \
    "$(_m '### Ship v2 by Q3 · status: **active** — our real approved goal')"
  # (p-iv) …and the same heading WITH the marker IS a placeholder — the anchored start still catches it.
  assert_eq "(p) single-heading active entry WITH the marker → placeholder (match)" "yes" \
    "$(_m '### Placeholder · status: **active** · <!-- ystack-shipped-default --> shipped')"
}

# --- (m) shared shipped-default marker matcher: scoped + whitespace/case-insensitive (FIX A) ---
# ns_has_shipped_default_marker underpins BOTH the gate's placeholder-FAIL and doctor (h)'s WARN,
# so the two never disagree. Two bugs the adversarial sweep found, asserted together:
#   - FALSE-PASS: a byte-exact `grep -F` on `<!-- ystack-shipped-default -->` lets a spacing/
#     casing/reflow-split variant of the marker slip through and wrongly AUTHORIZE. The helper
#     strips whitespace + lowercases the active region, so EVERY variant matches.
#   - FALSE-FAIL: a whole-file grep trips on the marker's mentions in the template PROSE, wrongly
#     FAILing a correctly-replaced star. The helper SCOPES to the active-entry region, so a star
#     whose active heading is clean (marker only in prose) does NOT match.
test_marker_matcher_variants() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  # Helper: run the matcher on a here-doc'd document via stdin; echo "yes"/"no".
  _marker() { if printf '%s' "$1" | ns_has_shipped_default_marker -; then echo yes; else echo no; fi; }

  # Un-replaced placeholder variants on the ACTIVE heading → MUST match (FALSE-PASS guard).
  assert_eq "(m) byte-exact marker on active heading → matches" "yes" \
    "$(_marker '### Goal · status: **active** · <!-- ystack-shipped-default --> shipped')"
  assert_eq "(m) NO-SPACE marker variant → matches" "yes" \
    "$(_marker '### Goal status: active <!--ystack-shipped-default-->')"
  assert_eq "(m) UPPERCASE marker variant → matches" "yes" \
    "$(_marker '### Goal status: active <!-- YSTACK-SHIPPED-DEFAULT -->')"
  assert_eq "(m) PADDED marker variant → matches" "yes" \
    "$(_marker '### Goal status: active <!--    ystack-shipped-default    -->')"
  assert_eq "(m) TAB-separated marker variant → matches" "yes" \
    "$(printf '### Goal status: active\t<!--\tystack-shipped-default\t-->' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"
  assert_eq "(m) MULTILINE-SPLIT marker (on the line below the active heading) → matches" "yes" \
    "$(printf '### Goal status: **active**\n<!-- ystack-shipped-default -->\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"

  # Correctly-replaced star: marker only in PROSE, cleared from the active heading → MUST NOT match.
  assert_eq "(m) correctly-replaced star (marker only in prose, active heading clean) → no match" "no" \
    "$(printf 'Intro prose names <!-- ystack-shipped-default --> as a token.\n\n### Ship v2 · status: **active** — our real goal\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"
  # FIX 2 (round-2): a DELIMITER-FREE prose mention of the token INSIDE the active region — the
  # operator removed the real `<!-- … -->` comment but the region still SAYS "ystack-shipped-default"
  # in prose. Round-1's bare-token match false-FAILed this valid star; the comment-form match must
  # NOT treat a delimiter-free prose token as the marker → no match (PROCEED).
  assert_eq "(m) FIX 2: bare-token PROSE in the ACTIVE region (no <!-- -->) → NOT the marker (no match)" "no" \
    "$(printf '### Ship v2 · status: **active** — our real goal; we removed the ystack-shipped-default marker.\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"
  # FIX 2 counterpart: a comment carrying EXTRA interior text still matches (it is the comment form).
  assert_eq "(m) FIX 2: comment with extra interior text (<!-- ystack-shipped-default: keep -->) → matches" "yes" \
    "$(_marker '### Goal · status: **active** · <!-- ystack-shipped-default: keep until you replace it --> shipped')"
  # FIX 2 boundary guard: the token sitting BETWEEN two unrelated comments (prose) → NOT the marker.
  assert_eq "(m) FIX 2: token between two unrelated comments (prose, not inside one) → no match" "no" \
    "$(_marker '### Goal · status: **active** · <!--a--> ystack-shipped-default <!--b-->')"
  # No active heading at all (e.g. the entry is `achieved`) → MUST NOT match (region is empty).
  assert_eq "(m) marker on a NON-active (achieved) heading → no match (not the active entry)" "no" \
    "$(_marker '### Goal status: achieved <!-- ystack-shipped-default -->')"
  # The shipped TEMPLATE (a real placeholder) → MUST match; a real file, not a synthetic string.
  # The template ships at templates/.ystack/ after the rename; accept the legacy templates/.fabrica/
  # location too while the move lands in this same PR (the marker check accepts both markers).
  local tmpl="$test_dir/../../templates/.ystack/north-star.md"
  [ -f "$tmpl" ] || tmpl="$test_dir/../../templates/.fabrica/north-star.md"
  assert_eq "(m) shipped template north-star.md (placeholder) → matches" "yes" \
    "$(if ns_has_shipped_default_marker "$tmpl"; then echo yes; else echo no; fi)"
}

# --- (m2) the LEGACY marker token still counts as the marker (rename fallback) -----
# Targets that adopted the pre-rename template still carry `fabrica-shipped-default`. An old
# un-replaced placeholder must keep FAILing the gate, so the matcher accepts the legacy token in
# the comment form — with the same active-region scoping and prose rules as the canonical one.
test_marker_legacy_token() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  _lmarker() { if printf '%s' "$1" | ns_has_shipped_default_marker -; then echo yes; else echo no; fi; }

  assert_eq "(m2) byte-exact LEGACY marker on active heading → matches" "yes" \
    "$(_lmarker '### Goal · status: **active** · <!-- fabrica-shipped-default --> shipped')"
  assert_eq "(m2) NO-SPACE + UPPERCASE LEGACY marker variant → matches" "yes" \
    "$(_lmarker '### Goal status: active <!--FABRICA-SHIPPED-DEFAULT-->')"
  assert_eq "(m2) MULTILINE-SPLIT LEGACY marker (line below the active heading) → matches" "yes" \
    "$(printf '### Goal status: **active**\n<!-- fabrica-shipped-default -->\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"
  # A correctly-replaced star that only MENTIONS the legacy token in prose must NOT match.
  assert_eq "(m2) LEGACY token only in prose (active heading clean) → no match" "no" \
    "$(printf 'Intro prose names <!-- fabrica-shipped-default --> as a token.\n\n### Ship v2 · status: **active** — our real goal\nbody\n' | { if ns_has_shipped_default_marker -; then echo yes; else echo no; fi; })"
  # A delimiter-free legacy prose token inside the active region is NOT the marker either.
  assert_eq "(m2) bare LEGACY token PROSE in the ACTIVE region (no <!-- -->) → no match" "no" \
    "$(_lmarker '### Ship v2 · status: **active** — we removed the fabrica-shipped-default marker.')"
  # The legacy marker on a NON-active heading is outside the region → no match.
  assert_eq "(m2) LEGACY marker on a NON-active (achieved) heading → no match" "no" \
    "$(_lmarker '### Goal status: achieved <!-- fabrica-shipped-default -->')"
}

# --- (q) LARGE star: the matcher DRAINS stdin, no SIGPIPE placeholder-bypass [P1, round-3] ------
# The callers run `printf '%s' "$north_star" | ns_has_shipped_default_marker -` UNDER `set -o
# pipefail`. Pre-fix, ns_active_region's awk `exit`ed as soon as the active region ended (the next
# heading/rule). For a large committed star — placeholder marker in the active entry PLUS tens of
# KB of body after the next heading, enough to fill the ~64KB pipe buffer — that early `exit`
# closed awk's stdin while `printf` still had bytes to write, so `printf` died with SIGPIPE (141).
# Under `pipefail` the 141 became the WHOLE pipeline's status, so `if ns_has_shipped_default_marker`
# read FALSE even though the marker matched → the gate PROCEEDS against an un-replaced placeholder
# and doctor MISSES the WARN (a placeholder-FAIL bypass). The fix makes the awk read every line to
# EOF (latch the region closed, keep reading, emit nothing further) so no early close → no SIGPIPE
# → the verdict holds. We assert on a ~250KB document that the marker is STILL reported present
# (the same-shape small document is already covered by (m)/(p)); this case reproduces the bug
# pre-fix (the standalone repro showed rc=141, "marker MISSED") and is closed here.
test_marker_large_star_drains_stdin() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$lib"
  # Build a big star: placeholder marker on the ACTIVE entry, a NEXT heading, then ~250KB of body
  # after it (well past the pipe buffer, so a pre-fix early `exit` would SIGPIPE the upstream printf).
  local big
  big="$(
    printf '### Goal · status: **active** · <!-- ystack-shipped-default --> shipped default\n'
    printf 'a body line inside the active region\n'
    printf '### Next section (content AFTER the active region — must not be scanned, must be DRAINED)\n'
    local i
    for i in $(seq 1 4000); do
      printf 'filler line %05d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
    done
  )"
  # Guard: assert the document really is large enough to matter (tens of KB past the buffer).
  local bytes; bytes="$(printf '%s' "$big" | wc -c | tr -d '[:space:]')"
  if [ "$bytes" -lt 100000 ]; then
    failed=$((failed + 1))
    echo "FAIL: (q) test fixture too small ($bytes bytes) to exercise the pipe buffer"
  fi
  # Run EXACTLY as the callers do: piped into the matcher as the LAST stage under `pipefail`, in an
  # `if` condition. On the pre-fix code this pipeline's status is 141 (printf SIGPIPE) → "no". The
  # subshell sets `pipefail` to mirror the callers precisely (the runner already has it, but pin it).
  local verdict
  verdict="$(set -o pipefail; if printf '%s' "$big" | ns_has_shipped_default_marker -; then echo yes; else echo "no($?)"; fi)"
  assert_eq "(q) large placeholder star ($bytes B) still MATCHES under pipefail (no SIGPIPE bypass)" "yes" "$verdict"

  # And a large CORRECTLY-REPLACED star (marker only in prose before the active heading, huge body
  # after) must still report NO match — draining doesn't over-match. `no` (not `no(141)`).
  local big_clean
  big_clean="$(
    printf 'Intro prose names <!-- ystack-shipped-default --> as a token (outside any active heading).\n\n'
    printf '### Ship v2 by Q3 · status: **active** — our real approved goal\n'
    printf 'a body line inside the active region\n'
    printf '### Next section\n'
    local i
    for i in $(seq 1 4000); do
      printf 'filler line %05d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
    done
  )"
  local verdict_clean
  verdict_clean="$(set -o pipefail; if printf '%s' "$big_clean" | ns_has_shipped_default_marker -; then echo yes; else echo "no($?)"; fi)"
  assert_eq "(q) large correctly-replaced star (marker only in prose) still NO match (clean rc, no SIGPIPE)" "no(1)" "$verdict_clean"
}

echo "== north-star resolver tests =="
test_local_wins
test_local_legacy_fallback
test_local_canonical_wins_over_legacy
test_subdir_resolves_toplevel
test_ystack_self_fallback
test_slug_spoof_not_ystack_self
test_ystack_self_precedence_over_local
test_ystack_self_committed_worktree_deleted
test_ystack_self_no_committed_root_ignores_stray_local
test_ystack_self_linked_worktree
test_ystack_self_worktree_negative_separate_repo
test_non_ystack_no_fallback
test_doctor_slug_mismatch
test_unset_and_empty
test_resolve_errexit_safe_non_git
test_slug_ignores_gh_repo
test_slug_eq_case_insensitive
test_relative_source_cd_away
test_offline_ystack_self_via_path
test_slug_ignores_cdpath
test_slug_empty_arg
test_ystack_root_errexit_deleted_tree
test_ystack_root_case_canonical
test_committed_regular_file_from_subdir
test_active_region_heading_anchored
test_marker_matcher_variants
test_marker_legacy_token
test_marker_large_star_drains_stdin

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
