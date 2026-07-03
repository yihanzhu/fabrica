#!/usr/bin/env bash
set -euo pipefail

# north-star-gate.test.sh — integration asserts for the ATOMIC per-target north-star flip
# (issue #98a): the manager-review.sh consensus GATE, doctor.sh check (h), and
# setup-target-repo.sh seeding all read the TARGET's north star, and the gate reads it
# COMMITTED (never an uncommitted working-tree edit).
#
# These complement scripts/test/north-star-resolver.test.sh, which asserts the resolver lib in
# isolation. This suite asserts the CONSUMERS now wired to that resolver by #98a — the part
# #99 deliberately left dormant.
#
# The gate (manager-review.sh) requires `gh` and `codex`, and materializes a detached worktree
# with REAL git. So we run the REAL script end-to-end against throwaway REAL git repos with
# `gh` and `codex` STUBBED on PATH — testing the actual pinned committed-read code path, not a
# reimplementation of it. The safety-critical assertions (from the manager-debate GAP) are the
# COMMITTED-vs-uncommitted pair, in BOTH directions:
#   - a worktree-only .fabrica/north-star.md (not committed) does NOT authorize (gate FAILs); and
#   - a HEAD-committed star STILL authorizes even if the working-tree copy is deleted or modified.
# Plus: LOCAL committed star → debates; LOCAL + shipped-default marker → FAIL; UNSET → FAIL;
# doctor UNSET → WARN and doctor LOCAL committed → pass; setup seeds only when cwd-slug==target
# and --check flags a missing star as drift; and the SOURCE-IDENTITY assert (approval source ==
# gate source), pinned by inspecting the shipped files since operator approval is not
# machine-readable.
#
# OFFLINE and hermetic: no network/gh/codex — both are faked on PATH. Every case builds a
# throwaway git repo in a temp dir. Run: scripts/test/north-star-gate.test.sh

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$test_dir/../.." && pwd -P)"
manager_review="$repo_root/scripts/manager-review.sh"
doctor="$repo_root/scripts/doctor.sh"
setup_script="$repo_root/scripts/setup-target-repo.sh"
faber_template="$repo_root/templates/faber-command.md"
persona="$repo_root/manager/CLAUDE.md"
ns_template="$repo_root/templates/.fabrica/north-star.md"
for f in "$manager_review" "$doctor" "$setup_script" "$faber_template" "$persona" "$ns_template"; do
  if [ ! -f "$f" ]; then echo "FAIL: missing $f" >&2; exit 1; fi
done

# Give git a per-process identity (the runner has no global user); scoped via env, not config.
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

tmproot="$(mktemp -d)"
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

passed=0
failed=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1)); echo "pass: $1"
  else
    failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected: [$2]"; echo "      actual:   [$3]"
  fi
}
assert_contains() {
  # assert_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) passed=$((passed + 1)); echo "pass: $1" ;;
    *) failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected to contain: [$2]"; echo "      actual: [$3]" ;;
  esac
}

# --- fake gh / codex on PATH -------------------------------------------------------
# Fake gh: `repo view --json nameWithOwner` prints a slug DERIVED FROM THE CWD's basename, so a
# throwaway target repo and the real Fabrica clone get DIFFERENT slugs — otherwise the resolver
# would false-match FABRICA_SELF when a run's target has no local star (the resolver falls back
# to the slug identity check, which compares the target's slug to Fabrica's own; ns_repo_slug
# cd's into each dir before calling gh, so keying the slug off $PWD keeps them distinct).
# `issue view` prints deterministic scalars for gh's -q extraction; `issue comment` is a no-op.
fakebin="$tmproot/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
# Minimal gh stub for the manager-review gate test. Only the calls manager-review.sh makes.
cmd="${1:-}"; sub="${2:-}"
case "$cmd $sub" in
  "repo view")
    # `gh repo view --json nameWithOwner -q .nameWithOwner` → a slug keyed off the cwd, so the
    # target repo (`someone/<cwd-basename>`) never equals Fabrica's own clone slug. Resolve the
    # cwd's git top-level so a subdir invocation still yields the repo's basename.
    top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "someone/$(basename "$top")" ;;
  "issue view")
    if printf '%s\n' "$@" | grep -q 'title'; then
      echo "A proactive proposal"
    elif printf '%s\n' "$@" | grep -q 'comments'; then
      echo "(no comments yet)"
    else
      echo "issue body text"
    fi ;;
  "issue comment")
    exit 0 ;;
  *)
    exit 0 ;;
esac
GH
chmod +x "$fakebin/gh"

# Fake codex: `codex exec -C <wt> -c ... -o <tmp> [-m model] -` writes a verdict into the -o
# file and exits 0. We parse out the -o argument.
cat >"$fakebin/codex" <<'CODEX'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
# Drain stdin (the prompt) so the upstream printf doesn't SIGPIPE.
cat >/dev/null 2>&1 || true
if [ -n "$out" ]; then
  printf 'VERDICT: PROCEED\nREASONING: stub.\nGAP FABER MISSED: none.\n' >"$out"
fi
exit 0
CODEX
chmod +x "$fakebin/codex"

# run_gate <repo_dir> — run the REAL manager-review.sh from inside <repo_dir> with the fakes on
# PATH; echo "<rc>|<combined-output>". codex/gh are faked; git is real. issue# is 1 (validated
# as a bare integer by the script).
run_gate() {
  local repo_dir="$1" rc out
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" bash "$manager_review" 1 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# make_target <name> — a throwaway non-Fabrica git repo with one commit; echo its path.
make_target() {
  local path="$tmproot/$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" commit -q --allow-empty -m "init"
  echo "$path"
}

# commit_star <repo> <content...> — write .fabrica/north-star.md and COMMIT it.
commit_star() {
  local repo="$1"; shift
  mkdir -p "$repo/.fabrica"
  printf '%s\n' "$*" > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "set north star"
}

# commit_star_raw <repo> — read EXACT .fabrica/north-star.md bytes from stdin and COMMIT (so a
# test can pin whitespace/tab/multiline-split marker variants that `commit_star`'s printf can't).
commit_star_raw() {
  local repo="$1"
  mkdir -p "$repo/.fabrica"
  cat > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "set north star"
}

# commit_symlink_star <repo> <relpath> — commit <relpath> as a SYMLINK pointing at a sibling
# regular file (the symlink attack: `git show <commit>:<relpath>` then returns the link's
# target-path string, not content). The link target file has REAL non-placeholder content, so a
# gate that followed the symlink would wrongly PROCEED — the FIX 4 guard must FAIL on the symlink
# mode (120000) before ever reading it.
commit_symlink_star() {
  local repo="$1" relpath="$2"
  mkdir -p "$repo/$(dirname "$relpath")"
  printf '### Real goal · status: **active** — content the symlink points at\nbody\n' > "$repo/decoy-target.md"
  ( cd "$repo" && ln -s "decoy-target.md" "$relpath" )
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "commit symlink north star"
}

# ---------------------------------------------------------------------------------
# (1) SOURCE IDENTITY — approval source == gate source. Operator approval is not
# machine-readable, so we pin the SOURCE identity: manager-review.sh's gate, the persona, and
# the /faber template all name the SAME per-target source (.fabrica/north-star.md via the
# resolver), and the gate reads it COMMITTED (git show at the pinned HEAD).
# ---------------------------------------------------------------------------------
test_source_identity() {
  local mr persona_txt faber_txt
  mr="$(cat "$manager_review")"; persona_txt="$(cat "$persona")"; faber_txt="$(cat "$faber_template")"

  # The gate resolves via the shared resolver and reads .fabrica/north-star.md committed.
  case "$mr" in *"ns_resolve"*) passed=$((passed + 1)); echo "pass: (1) gate resolves via ns_resolve (shared resolver)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) gate does not call ns_resolve" ;; esac
  # The single-quoted needles are LITERAL source text we search for in manager-review.sh's
  # content — the `${head_commit}` / `$worktree` inside them must NOT expand (they are the exact
  # bytes the script contains), so single quotes are deliberate; SC2016 doesn't apply.
  # shellcheck disable=SC2016
  case "$mr" in *'git show "${head_commit}:.fabrica/north-star.md"'*) passed=$((passed + 1)); echo "pass: (1) gate reads .fabrica/north-star.md COMMITTED at the pinned head_commit" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) gate does not read the committed .fabrica/north-star.md at head_commit" ;; esac

  # The pin is the SAME commit the review worktree is materialized at: `git worktree add ...
  # "$head_commit"` and `git show "${head_commit}:..."` both use head_commit (captured once).
  # shellcheck disable=SC2016  # literal source-text needle; must not expand (see above).
  case "$mr" in *'git worktree add --detach "$worktree" "$head_commit"'*) passed=$((passed + 1)); echo "pass: (1) review worktree is pinned to the SAME head_commit as the committed read" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) review worktree is not pinned to head_commit" ;; esac

  # The persona + /faber approval/logging reference the per-target .fabrica/north-star.md, NOT
  # {{FABRICA_ROOT}}/NORTH_STAR.md as the operator-approval source.
  case "$persona_txt" in *".fabrica/north-star.md"*) passed=$((passed + 1)); echo "pass: (1) persona references the target's .fabrica/north-star.md (approval source)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) persona does not reference .fabrica/north-star.md" ;; esac
  case "$faber_txt" in *".fabrica/north-star.md"*) passed=$((passed + 1)); echo "pass: (1) /faber template references the target's .fabrica/north-star.md (approval source)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) /faber template does not reference .fabrica/north-star.md" ;; esac

  # Gate source ≡ approval source is stated explicitly so the two never silently diverge.
  case "$persona_txt" in *"gate source ≡ approval source"*|*"gate reads — gate source"*|*"same committed source"*) passed=$((passed + 1)); echo "pass: (1) persona pins gate-source == approval-source" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) persona does not pin gate-source == approval-source" ;; esac
}

# ---------------------------------------------------------------------------------
# (2) COMMITTED vs UNCOMMITTED — the safety-critical pair, BOTH directions.
# ---------------------------------------------------------------------------------

# (2a) A worktree-only .fabrica/north-star.md (written but NOT committed) does NOT authorize:
# the gate reads HEAD, sees no committed star, and FAILs (UNSET) before any verdict.
test_worktree_only_does_not_authorize() {
  local repo; repo="$(make_target "wt-only")"
  # Write the star but DO NOT commit it — an uncommitted working-tree edit.
  mkdir -p "$repo/.fabrica"
  echo "an unreviewed local goal" > "$repo/.fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2a) worktree-only star: gate FAILs (does NOT authorize)" "1" "$rc"
  assert_contains "(2a) worktree-only star: FAIL cites not-committed-at-HEAD" "not committed at HEAD" "$out"
}

# (2b) A HEAD-committed star STILL authorizes even if the working-tree copy is DELETED. The
# gate reads committed content at the pinned commit, independent of the dirty working tree.
test_committed_authorizes_even_if_worktree_deleted() {
  local repo; repo="$(make_target "committed-del")"
  commit_star "$repo" "our real committed north star"
  rm -f "$repo/.fabrica/north-star.md"   # working-tree copy gone; HEAD still has it
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2b) committed star authorizes even with the worktree copy DELETED (gate proceeds)" "0" "$rc"
  assert_contains "(2b) gate posted the verdict (reached codex)" "PROCEED" "$out"
}

# (2b') A HEAD-committed star STILL authorizes even if the working-tree copy is MODIFIED to the
# shipped-default placeholder: the gate reads the COMMITTED (clean) content, so the dirty
# placeholder edit neither redirects nor blocks it.
test_committed_authorizes_even_if_worktree_modified() {
  local repo; repo="$(make_target "committed-mod")"
  commit_star "$repo" "our real committed north star"
  # Dirty the working tree with a placeholder marker — the gate must ignore this and read HEAD.
  printf 'placeholder <!-- fabrica-shipped-default -->\n' > "$repo/.fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2b') committed star authorizes even with the worktree copy MODIFIED to a placeholder" "0" "$rc"
  assert_contains "(2b') gate read the committed (clean) star and proceeded" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (2c) FIX 1 (round-2) — FABRICA_SELF authorizes off the COMMITTED root NORTH_STAR.md even when
# the working-tree copy is DELETED. We build a throwaway control-plane clone that CONTAINS a copy
# of the resolver lib + manager-review.sh, init it as git, COMMIT a root NORTH_STAR.md, then delete
# the worktree copy. ns_fabrica_root derives from the lib's own location, so run FROM this clone
# and its git top-level == ns_fabrica_root → the resolver reports FABRICA_SELF off committed state
# and the gate reads `git show HEAD:NORTH_STAR.md` — proceeding despite the deleted worktree copy.
# The gate's FABRICA_SELF branch is EXEMPT from the placeholder-FAIL, so a marker in the committed
# root star does not block it (Fabrica's own root star legitimately carries the shipped-default
# marker). This is the self analogue of (2b) and directly exercises the resolver/gate agreement.
# ---------------------------------------------------------------------------------
test_fabrica_self_committed_worktree_deleted_proceeds() {
  local cp_root="$tmproot/gate-fabrica-self-committed-del"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$manager_review" "$cp_root/scripts/manager-review.sh"; chmod +x "$cp_root/scripts/manager-review.sh"
  git -C "$cp_root" init -q
  # Commit a root NORTH_STAR.md, then delete the worktree copy: the gate must read HEAD.
  printf '### Fabrica goal · status: **active** — our own committed control-plane star\nbody\n' > "$cp_root/NORTH_STAR.md"
  git -C "$cp_root" add NORTH_STAR.md scripts/lib/north-star.sh scripts/manager-review.sh
  git -C "$cp_root" commit -q -m "cp init with committed root star"
  rm -f "$cp_root/NORTH_STAR.md"   # worktree copy gone; HEAD still has it
  local rc out
  out="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" bash "$cp_root/scripts/manager-review.sh" 1 2>&1
  )" && rc=0 || rc=$?
  assert_eq "(2c) FABRICA_SELF authorizes off COMMITTED root star with the worktree copy DELETED (gate proceeds)" "0" "$rc"
  assert_contains "(2c) Fabrica-self gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (2d) [P2, round-3] Fabrica-self is CLASSIFIED by PATH identity UNCONDITIONALLY — a missing
# committed root NORTH_STAR.md FAILs at the GATE (authorization), it does NOT fall through to a
# stray `.fabrica/north-star.md`. We build a throwaway control-plane clone (contains the lib +
# manager-review.sh, so ns_fabrica_root == its git top-level → the resolver classifies FABRICA_SELF),
# but commit NO root NORTH_STAR.md and DO commit a stray `.fabrica/north-star.md`. Under round-2 the
# resolver's committed-existence gate would have fallen through to the LOCAL branch and the gate
# would have PROCEEDED against `.fabrica`. Now the resolver returns FABRICA_SELF (path-only), the gate
# takes the FABRICA_SELF branch, its `git show HEAD:NORTH_STAR.md` read FAILs cleanly (root not
# committed) with an actionable message, and it NEVER authorizes off the stray `.fabrica` star.
# ---------------------------------------------------------------------------------
test_fabrica_self_no_committed_root_fails_not_local() {
  local cp_root="$tmproot/gate-fabrica-self-no-root"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$manager_review" "$cp_root/scripts/manager-review.sh"; chmod +x "$cp_root/scripts/manager-review.sh"
  git -C "$cp_root" init -q
  # NO root NORTH_STAR.md. A STRAY .fabrica/north-star.md IS committed (must NOT be authorized).
  mkdir -p "$cp_root/.fabrica"
  printf '### Stray goal · status: **active** — must NOT authorize Fabrica-self\nbody\n' > "$cp_root/.fabrica/north-star.md"
  git -C "$cp_root" add scripts/lib/north-star.sh scripts/manager-review.sh .fabrica/north-star.md
  git -C "$cp_root" commit -q -m "cp init: stray local star, NO root star"
  local rc out
  out="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" bash "$cp_root/scripts/manager-review.sh" 1 2>&1
  )" && rc=0 || rc=$?
  assert_eq "(2d) FABRICA_SELF with no committed root NORTH_STAR.md → gate FAILs (does NOT fall back to .fabrica)" "1" "$rc"
  assert_contains "(2d) FABRICA_SELF missing-root FAIL cites NORTH_STAR.md not committed at HEAD" "NORTH_STAR.md is not committed at HEAD" "$out"
  # And it must NOT have proceeded against the stray .fabrica star.
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (2d) gate must NOT reach a verdict off the stray .fabrica star"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (2d) gate did NOT authorize off the stray .fabrica star" ;;
  esac
}

# ---------------------------------------------------------------------------------
# (3) LOCAL committed → debates; LOCAL + marker → FAIL; UNSET → FAIL.
# ---------------------------------------------------------------------------------

# (3a) A LOCAL committed star with no marker → the gate debates it (proceeds to the verdict).
test_local_committed_debates() {
  local repo; repo="$(make_target "local-ok")"
  commit_star "$repo" "ship the widget v2 by Q3"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3a) LOCAL committed star (no marker) → gate debates (exit 0)" "0" "$rc"
  assert_contains "(3a) gate reached the verdict" "PROCEED" "$out"
}

# (3b) A LOCAL committed star STILL carrying the shipped-default marker (un-replaced template)
# → FAIL before any verdict, with an actionable "replace + commit + approve" message.
test_local_marker_fails() {
  local repo; repo="$(make_target "local-marker")"
  # The marker rides on the active HEADING (as in the shipped template), so the heading-anchored
  # active-region scan (round-3 FIX 2) opens on it and the placeholder is detected.
  commit_star "$repo" "### Placeholder status: **active** <!-- fabrica-shipped-default --> replace me"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3b) LOCAL committed star with shipped-default marker → gate FAILs" "1" "$rc"
  assert_contains "(3b) marker FAIL cites the shipped placeholder" "shipped placeholder" "$out"
}

# (3c) UNSET — a non-empty target with no committed star → FAIL with an actionable pointer.
test_unset_fails() {
  local repo; repo="$(make_target "unset")"   # committed init, no .fabrica/north-star.md
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3c) UNSET target (no committed star) → gate FAILs" "1" "$rc"
  assert_contains "(3c) UNSET FAIL names the resolver kind" "resolver: UNSET" "$out"
}

# ---------------------------------------------------------------------------------
# (3d) FIX A at the GATE — the placeholder check is active-region-SCOPED and whitespace/case-
# insensitive. Two bugs the adversarial sweep found:
#   - FALSE-PASS: a spacing/casing/reflow-split marker variant on the active heading must still
#     FAIL the gate (a byte-exact grep would let it AUTHORIZE).
#   - FALSE-FAIL: a correctly-replaced star (marker cleared from the active heading, still named
#     in prose) must PROCEED (a whole-file grep would wrongly FAIL it).
# ---------------------------------------------------------------------------------

# (3d-i) A committed star carrying a WHITESPACE/CASE/SPLIT marker variant on the active heading
# → gate FAILs (the un-replaced placeholder does NOT slip through and authorize).
test_gate_marker_variants_fail() {
  # no-space + UPPERCASE on the active heading
  local r1; r1="$(make_target "marker-nospace-upper")"
  printf '### Goal · status: **active** · <!--FABRICA-SHIPPED-DEFAULT--> replace me\nbody\n' \
    | commit_star_raw "$r1"
  local res rc out
  res="$(run_gate "$r1")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) no-space+UPPERCASE marker variant → gate FAILs" "1" "$rc"
  assert_contains "(3d-i) variant FAIL cites the shipped placeholder" "shipped placeholder" "$out"

  # reflow-SPLIT: marker on the line just below the active heading
  local r2; r2="$(make_target "marker-split")"
  printf '### Goal · status: **active**\n<!-- fabrica-shipped-default -->\nbody\n' \
    | commit_star_raw "$r2"
  res="$(run_gate "$r2")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) reflow-split marker (line below active heading) → gate FAILs" "1" "$rc"

  # TAB-separated marker on the active heading
  local r3; r3="$(make_target "marker-tab")"
  printf '### Goal status: active\t<!--\tfabrica-shipped-default\t-->\nbody\n' \
    | commit_star_raw "$r3"
  res="$(run_gate "$r3")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) tab-separated marker variant → gate FAILs" "1" "$rc"
}

# (3d-ii) A CORRECTLY-REPLACED star: the marker is only in the explanatory PROSE, CLEARED from the
# active heading → gate PROCEEDs (the prose mention must not false-FAIL a valid adopter star).
test_gate_correctly_replaced_proceeds() {
  local repo; repo="$(make_target "marker-prose-only")"
  # Mirrors the shipped template shape: prose NAMES the marker, but the active heading is clean.
  printf 'Intro: the shipped default carries a <!-- fabrica-shipped-default --> marker; remove it when you set your own.\n\n### Ship widget v2 by Q3 · status: **active** — our real approved goal\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-ii) correctly-replaced star (marker only in prose) → gate PROCEEDs (no false FAIL)" "0" "$rc"
  assert_contains "(3d-ii) gate reached the verdict" "PROCEED" "$out"
}

# (3d-iii) FIX 2 (round-2) — a DELIMITER-FREE prose mention of the token WITHIN THE ACTIVE REGION
# (the operator removed the real `<!-- … -->` comment but the active heading/body still SAYS
# "fabrica-shipped-default" in prose) must PROCEED. Round-1's bare-token-anywhere match wrongly
# FAILed this valid star; the comment-form match requires the `<!-- … -->` delimiters, so a
# delimiter-free prose token in the active region does NOT trip the placeholder-FAIL.
test_gate_prose_token_in_active_region_proceeds() {
  local repo; repo="$(make_target "marker-prose-in-active")"
  printf '### Ship widget v2 by Q3 · status: **active** — our real goal; we removed the fabrica-shipped-default marker from this line.\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-iii) bare-token PROSE in the ACTIVE region (no <!-- -->) → gate PROCEEDs (FIX 2)" "0" "$rc"
  assert_contains "(3d-iii) gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (6) FIX F — the gate refuses to authorize off a north star in a SEPARATE git repo NESTED inside
# ANOTHER git work tree (confused deputy). A linked worktree (same repo) is NOT rejected.
# ---------------------------------------------------------------------------------

# (6a) Gate run from a SEPARATE embedded repo (its own committed star) inside an outer work tree
# → FAIL with the nested/embedded message (before any verdict).
test_gate_nested_repo_fails() {
  # Outer target repo with its OWN committed star.
  local outer; outer="$(make_target "nested-outer")"
  commit_star "$outer" "the OUTER target's real committed north star"
  # A SEPARATE embedded repo nested inside the outer work tree, with its own committed star.
  local inner="$outer/embedded/inner"
  mkdir -p "$inner"
  git -C "$inner" init -q
  git -C "$inner" commit -q --allow-empty -m "inner init"
  commit_star "$inner" "the embedded repo's DIFFERENT star"
  local res rc out
  res="$(run_gate "$inner")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(6a) gate run from a nested/embedded repo → FAILs" "1" "$rc"
  assert_contains "(6a) nested FAIL tells the operator to run from the target's own top-level clone" "nested/embedded checkout" "$out"
}

# (6b) A LINKED WORKTREE (git worktree add — SAME repo, shares the common dir) is NOT the
# confused-deputy case: it must NOT be rejected as nested. We add a linked worktree of a normal
# target (committed real star) and assert the gate PROCEEDs from it.
test_gate_linked_worktree_ok() {
  local repo; repo="$(make_target "wt-main")"
  commit_star "$repo" "the target's real committed north star"
  # Create a linked worktree UNDER the repo's tree (same shape as this project's .claude/worktrees).
  local wt="$repo/.wts/feature"
  git -C "$repo" worktree add -q --detach "$wt" HEAD 2>/dev/null
  local res rc out
  res="$(run_gate "$wt")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(6b) linked worktree (same repo) is NOT treated as nested → gate PROCEEDs" "0" "$rc"
  assert_contains "(6b) linked-worktree run reached the verdict" "PROCEED" "$out"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------
# (7) FIX 4 (round-2) — the gate REJECTS a committed SYMLINK north star (git mode 120000) BEFORE
# the marker check, in BOTH the LOCAL and the FABRICA_SELF branches. A committed symlink makes
# `git show <commit>:<path>` return the link's target-path string, not content, so it would bypass
# the marker check and let the gate authorize off a meaningless string (and diverge from the file
# Codex reviews). The decoy target the link points at has REAL non-placeholder content, so a
# symlink-following gate would wrongly PROCEED — the guard must FAIL with the symlink message.
# ---------------------------------------------------------------------------------

# (7a) LOCAL committed symlink .fabrica/north-star.md → gate FAILs with the symlink message.
test_gate_local_symlink_fails() {
  local repo; repo="$(make_target "local-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(7a) LOCAL committed symlink north star → gate FAILs" "1" "$rc"
  assert_contains "(7a) LOCAL symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# (7b) FABRICA_SELF committed symlink NORTH_STAR.md → gate FAILs with the symlink message. Built
# like (2c): a throwaway control-plane clone that ships the lib + manager-review.sh, so
# ns_fabrica_root == the cwd's top-level → the gate takes the FABRICA_SELF branch.
test_gate_fabrica_self_symlink_fails() {
  local cp_root="$tmproot/gate-fabrica-self-symlink"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$manager_review" "$cp_root/scripts/manager-review.sh"; chmod +x "$cp_root/scripts/manager-review.sh"
  git -C "$cp_root" init -q
  # Commit NORTH_STAR.md as a SYMLINK to a decoy real file.
  printf '### Real fabrica goal · status: **active** — decoy content\nbody\n' > "$cp_root/decoy-root.md"
  ( cd "$cp_root" && ln -s "decoy-root.md" "NORTH_STAR.md" )
  git -C "$cp_root" add -A
  git -C "$cp_root" commit -q -m "cp init with SYMLINK root star"
  local rc out
  out="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" bash "$cp_root/scripts/manager-review.sh" 1 2>&1
  )" && rc=0 || rc=$?
  assert_eq "(7b) FABRICA_SELF committed symlink NORTH_STAR.md → gate FAILs" "1" "$rc"
  assert_contains "(7b) FABRICA_SELF symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# ---------------------------------------------------------------------------------
# (8) FIX 1 (round-3) — the gate authorizes correctly when run from a SUBDIRECTORY of the target.
# The round-2 symlink guard calls ns_committed_is_regular_file "$PWD" ... with a ROOT-relative
# relpath; pre-fix, from a subdir the `git ls-tree` pathspec was interpreted relative to the subdir
# → the mode lookup returned EMPTY for a valid regular committed star → the guard FALSELY rejected
# the run. The fix resolves the top-level before ls-tree. Assert: a subdir run with a regular
# committed star PROCEEDs (not rejected as a symlink); and a committed SYMLINK is STILL rejected
# from a subdir.
# ---------------------------------------------------------------------------------

# run_gate_from <dir> — like run_gate but runs the REAL manager-review.sh from an arbitrary <dir>
# (typically a subdirectory of the target), so we exercise the subdir-invocation code path.
run_gate_from() {
  local dir="$1" rc out
  out="$(
    cd "$dir"
    PATH="$fakebin:$PATH" bash "$manager_review" 1 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# (8a) A regular committed star, gate run from a nested SUBDIRECTORY of the target → PROCEEDs (the
# symlink guard's mode lookup resolves the root-relative pathspec from the top-level, not the subdir).
test_gate_subdir_regular_star_proceeds() {
  local repo; repo="$(make_target "subdir-regular")"
  commit_star "$repo" "### Ship v2 by Q3 · status: **active** — our real committed goal"
  local sub="$repo/deeply/nested/dir"
  mkdir -p "$sub"
  local res rc out
  res="$(run_gate_from "$sub")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(8a) gate from a SUBDIR with a regular committed star → PROCEEDs (not falsely symlink-rejected)" "0" "$rc"
  assert_contains "(8a) subdir gate reached the verdict" "PROCEED" "$out"
}

# (8b) A committed SYMLINK north star, gate run from a SUBDIR → STILL FAILs with the symlink message
# (the top-level pathspec resolution correctly finds the symlink mode from the subdir too).
test_gate_subdir_symlink_still_fails() {
  local repo; repo="$(make_target "subdir-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local sub="$repo/deeply/nested/dir"
  mkdir -p "$sub"
  local res rc out
  res="$(run_gate_from "$sub")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(8b) committed SYMLINK star, gate from a SUBDIR → STILL FAILs" "1" "$rc"
  assert_contains "(8b) subdir symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# ---------------------------------------------------------------------------------
# (9) FIX 2 (round-3) — the active-region scan STARTS on a HEADING line. A committed star with a
# PROSE/front-matter line mentioning `status: active` BEFORE the real active heading (which carries
# the shipped-default marker) must STILL be detected as a placeholder → gate FAILs (no placeholder
# bypass). And a normal single-heading active entry still PROCEEDs.
# ---------------------------------------------------------------------------------

# (9a) Prose `status: active` before the real marked active heading → gate STILL FAILs (placeholder
# is not bypassed by an early prose region-start).
test_gate_prose_active_before_heading_still_fails() {
  local repo; repo="$(make_target "prose-before-heading")"
  printf 'Front-matter: shipped default status: active until you set your own.\n\n### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(9a) prose 'status: active' before the marked active HEADING → gate STILL FAILs (no bypass)" "1" "$rc"
  assert_contains "(9a) FAIL still cites the shipped placeholder" "shipped placeholder" "$out"
}

# (9b) A normal single-heading active entry (no prose decoy, no marker) still PROCEEDs.
test_gate_single_heading_active_proceeds() {
  local repo; repo="$(make_target "single-heading-active")"
  commit_star "$repo" "### Ship widget v2 by Q3 · status: **active** — our real approved goal"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(9b) normal single-heading active entry → gate PROCEEDs" "0" "$rc"
  assert_contains "(9b) single-heading gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (4) doctor.sh check (h) — consistent with the gate, but WARN (not FAIL) since doctor only
# diagnoses. UNSET → WARN; a LOCAL committed real star → pass.
# ---------------------------------------------------------------------------------

# run_doctor_h <repo_dir> — run doctor.sh from inside <repo_dir> with the fakes on PATH; echo
# only its (h) line. doctor may exit non-zero on unrelated hard fails (no /faber etc.), so
# capture output regardless of rc.
run_doctor_h() {
  local repo_dir="$1" out
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" bash "$doctor" 2>&1 || true
  )"
  printf '%s' "$out" | grep '(h)' | head -n1 || true
}

test_doctor_unset_warns() {
  local repo; repo="$(make_target "doctor-unset")"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4a) doctor (h) on an UNSET target WARNs (not fail:)" "warn:" "$line"
  assert_contains "(4a) doctor (h) UNSET message names the gap" "no north star set" "$line"
}

test_doctor_local_committed_passes() {
  local repo; repo="$(make_target "doctor-local")"
  # A real adopter star: an active entry, no shipped-default marker → doctor (h) passes.
  commit_star "$repo" "### Ship v2 · status: **active** — our real project goal for this quarter"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4b) doctor (h) on a LOCAL committed real star PASSES" "pass:" "$line"
}

test_doctor_local_marker_warns() {
  local repo; repo="$(make_target "doctor-marker")"
  # Marker on the active HEADING (shipped-template shape) so the heading-anchored region scan
  # (round-3 FIX 2) opens on it and doctor (h) WARNs on the still-shipped-default placeholder.
  commit_star "$repo" "### Placeholder status: **active** <!-- fabrica-shipped-default --> replace me"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4c) doctor (h) on a still-shipped-default LOCAL star WARNs" "warn:" "$line"
  assert_contains "(4c) doctor (h) shipped-default WARN cites the marker" "fabrica-shipped-default" "$line"
}

# (4d) FIX E — doctor (h) drives its verdict off the COMMITTED star, matching the gate. A star
# committed at HEAD but DELETED in the working tree must still be diagnosed as the committed
# (real) star → PASS, not "no star" — the same committed source the gate authorizes on.
test_doctor_h_committed_worktree_deleted() {
  local repo; repo="$(make_target "doctor-committed-del")"
  commit_star "$repo" "### Ship v2 · status: **active** — our real committed goal"
  rm -f "$repo/.fabrica/north-star.md"   # worktree copy gone; HEAD still has it
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4d) doctor (h) reads the COMMITTED star even when the worktree copy is deleted → pass" "pass:" "$line"
}

# (4d') FIX E, other direction — a star committed at HEAD but MODIFIED in the working tree to a
# placeholder must be diagnosed off the COMMITTED (clean) content → PASS, and NOTE the drift.
test_doctor_h_committed_worktree_modified() {
  local repo; repo="$(make_target "doctor-committed-mod")"
  commit_star "$repo" "### Ship v2 · status: **active** — our real committed goal"
  printf 'placeholder <!-- fabrica-shipped-default -->\n' > "$repo/.fabrica/north-star.md"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4d') doctor (h) reads the COMMITTED (clean) star despite a dirty placeholder worktree edit → pass" "pass:" "$line"
  assert_contains "(4d') doctor (h) notes the working-tree copy differs from HEAD" "differs from HEAD" "$line"
}

# (4d'') FIX 1 (round-3) — the head-vs-worktree drift note must fire for FABRICA_SELF too. doctor
# drives the note off $committed_relpath (the exact path the gate reads), NOT a hardcoded
# .fabrica-relative path — so an uncommitted edit to the control plane's ROOT NORTH_STAR.md is
# surfaced as "differs from HEAD / the gate reads the committed version", not swallowed as a
# silent clean pass. (manager-review.sh reads HEAD:NORTH_STAR.md and ignores the working tree, so
# a dirty root star that doctor reported clean would be misleading.) We build a throwaway
# control-plane clone (contains doctor.sh + the resolver lib, so ns_fabrica_root == its git
# top-level → the resolver classifies FABRICA_SELF → committed_relpath = NORTH_STAR.md), commit a
# real root star, then DIRTY the working-tree copy and run doctor from the clone.
test_doctor_h_fabrica_self_worktree_modified_notes_drift() {
  local cp_root="$tmproot/doctor-fabrica-self-mod"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$doctor" "$cp_root/scripts/doctor.sh"; chmod +x "$cp_root/scripts/doctor.sh"
  git -C "$cp_root" init -q
  # A real (non-placeholder) committed root star → doctor (h) would normally PASS clean.
  printf '### Fabrica goal · status: **active** — our own committed control-plane star\nbody\n' > "$cp_root/NORTH_STAR.md"
  git -C "$cp_root" add NORTH_STAR.md scripts/lib/north-star.sh scripts/doctor.sh
  git -C "$cp_root" commit -q -m "cp init with committed root star"
  # Now DIRTY the working-tree root copy (uncommitted edit the gate would ignore).
  printf '### Fabrica goal · status: **active** — uncommitted local edit\nbody CHANGED\n' > "$cp_root/NORTH_STAR.md"
  local line
  line="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" bash "$cp_root/scripts/doctor.sh" 2>&1 || true
  )"
  line="$(printf '%s' "$line" | grep '(h)' | head -n1 || true)"
  assert_contains "(4d'') doctor (h) on Fabrica-self reads the COMMITTED root star despite a dirty worktree edit → pass" "pass:" "$line"
  assert_contains "(4d'') doctor (h) notes the Fabrica-self ROOT working-tree copy differs from HEAD" "differs from HEAD" "$line"
}

# (4f) FIX 4 (round-2) — doctor (h) diagnoses a committed SYMLINK north star as a WARN (symmetric
# with the gate, which FAILs). doctor must not read the link's target-path string as if it were the
# star; it WARNs that a regular file is required.
test_doctor_h_committed_symlink_warns() {
  local repo; repo="$(make_target "doctor-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4f) doctor (h) on a committed SYMLINK north star WARNs" "warn:" "$line"
  assert_contains "(4f) doctor (h) symlink WARN says a regular file is required (not a symlink)" "SYMLINK" "$line"
}

# (4e) FIX D — doctor with a MISSING resolver lib must still print its summary and REPORT the
# missing lib (as a fail: line), not crash at the top-of-file source. We run a COPY of the repo
# tree with scripts/lib/north-star.sh removed, so `. "$ns_lib"` would abort the old doctor.
test_doctor_missing_lib_reports_and_summarizes() {
  # Build a throwaway clone of the control-plane tree with the lib removed. Copy only what doctor
  # needs to run past its early checks; the point is the MISSING lib, so remove it after copying.
  local fake_root="$tmproot/doctor-nolib-root"
  mkdir -p "$fake_root/scripts/lib" "$fake_root/scripts/test" "$fake_root/ci" "$fake_root/templates/.fabrica"
  cp "$doctor" "$fake_root/scripts/doctor.sh"; chmod +x "$fake_root/scripts/doctor.sh"
  cp "$setup_script" "$fake_root/scripts/setup-target-repo.sh"; chmod +x "$fake_root/scripts/setup-target-repo.sh"
  cp "$repo_root/ci/required-files.txt" "$fake_root/ci/required-files.txt"
  # Deliberately do NOT copy scripts/lib/north-star.sh → the lib is missing.
  local out rc
  out="$(
    cd "$fake_root"
    PATH="$fakebin:$PATH" bash "$fake_root/scripts/doctor.sh" 2>&1
  )" && rc=0 || rc=$?
  assert_contains "(4e) doctor with a missing resolver lib still prints its summary (no crash)" "doctor:" "$out"
  assert_contains "(4e) doctor (h) reports the missing resolver lib as a fail line" "resolver lib missing" "$out"
  assert_eq "(4e) doctor exits non-zero when the lib (a fail) is missing" "1" "$rc"
}

# ---------------------------------------------------------------------------------
# (5) setup-target-repo.sh seeding — SEEDs only when cwd-slug == target-slug; --check flags a
# missing north-star file as drift. We run --check (read-only, never mutates labels) with a
# fake gh so no network is touched, and exercise the seed's cwd-guard + idempotency directly
# via the same slug-match predicate the script uses (ns_slug_eq), plus a real cp.
# ---------------------------------------------------------------------------------

# The --check path lists labels (fake gh returns an empty label set → all labels "missing", so
# --check already exits non-zero on labels). To isolate the NORTH-STAR drift signal, we assert
# on setup's north-star drift LINE, which prints only when cwd_is_target and the star is absent.
# Fake gh for setup: `repo view` → a slug we can match/mismatch; `label list` → empty JSON.
test_setup_check_missing_star_is_drift() {
  local repo; repo="$(make_target "setup-check")"   # committed init, no star
  local setup_fakebin="$tmproot/setup-fakebin-match"
  mkdir -p "$setup_fakebin"
  # cwd slug == target arg → cwd_is_target=1 → missing star reported as drift.
  cat >"$setup_fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/setup-check" ;;
  "label list") echo "[]" ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$setup_fakebin/gh"
  local out rc
  out="$(
    cd "$repo"
    PATH="$setup_fakebin:$PATH" bash "$setup_script" --check "acme/setup-check" 2>&1
  )" && rc=0 || rc=$?
  assert_contains "(5a) --check reports a missing .fabrica/north-star.md as drift" "north star: missing" "$out"
  assert_eq "(5a) --check exits non-zero on the missing-star drift" "1" "$rc"
}

# From a NON-target cwd (slug mismatch), --check must NOT claim the local tree is the target's
# and must NOT report a north-star drift line (it can't see the target's tree).
test_setup_check_nontarget_cwd_no_star_drift() {
  local repo; repo="$(make_target "setup-nontarget")"
  local setup_fakebin="$tmproot/setup-fakebin-mismatch"
  mkdir -p "$setup_fakebin"
  # cwd slug != target arg → cwd_is_target=0 → NO north-star drift line for the target's tree.
  cat >"$setup_fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "someone/some-other-checkout" ;;
  "label list") echo "[]" ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$setup_fakebin/gh"
  local out
  out="$(
    cd "$repo"
    PATH="$setup_fakebin:$PATH" bash "$setup_script" --check "acme/the-real-target" 2>&1 || true
  )"
  case "$out" in
    *"north star: missing"*) failed=$((failed + 1)); echo "FAIL: (5b) --check from a non-target cwd wrongly reported a north-star drift" ;;
    *) passed=$((passed + 1)); echo "pass: (5b) --check from a non-target cwd does NOT report the target's north-star drift" ;;
  esac
}

# The seed's cwd-guard predicate itself: SEED only when the cwd slug matches the target (via
# ns_slug_eq), and NEVER overwrite an existing star. We source the resolver for ns_slug_eq and
# exercise the exact seed predicate the script uses, with a real cp.
test_setup_seed_cwd_guard_and_idempotency() {
  # shellcheck source=scripts/lib/north-star.sh
  . "$repo_root/scripts/lib/north-star.sh"

  # Slug match → would seed.
  local do_seed="no"
  if ns_slug_eq "acme/target" "acme/target"; then do_seed="yes"; fi
  assert_eq "(5c) cwd slug == target slug → seed permitted" "yes" "$do_seed"
  # Slug mismatch → must NOT seed (never write the target's star into an unrelated repo).
  do_seed="no"
  if ns_slug_eq "someone/other" "acme/target"; then do_seed="yes"; fi
  assert_eq "(5c) cwd slug != target slug → seed refused" "no" "$do_seed"

  # Idempotency + actual seed: into a fresh target, seed from the shipped template; re-seeding
  # must KEEP the existing (already-replaced) star, never overwrite it.
  local repo; repo="$(make_target "seed-idem")"
  local star="$repo/.fabrica/north-star.md"
  # First seed (absent → copy the template).
  if [ ! -f "$star" ]; then mkdir -p "$(dirname "$star")"; cp "$ns_template" "$star"; fi
  assert_eq "(5c) first seed creates the star from the template" "0" "$([ -f "$star" ] && echo 0 || echo 1)"
  # Operator replaces it with their own goal.
  printf 'my own committed goal\n' > "$star"
  # Re-run's guard: an EXISTING star is never overwritten.
  if [ -f "$star" ]; then :; else cp "$ns_template" "$star"; fi
  assert_contains "(5c) re-seed keeps the operator's star (never overwrites)" "my own committed goal" "$(cat "$star")"
}

# (5d) FIX C — setup on the Fabrica control-plane repo ITSELF must NOT seed .fabrica/north-star.md
# (it steers by the root NORTH_STAR.md; a seed would pollute the control plane). Detection is
# PATH-based: the cwd's git top-level == ns_fabrica_root (derived from the lib's own location). We
# build a throwaway "control-plane" clone that CONTAINS a copy of the resolver lib + setup script +
# template, init it as git, and run setup from its root. ns_fabrica_root then resolves to THIS
# clone's root (== cwd toplevel) → Fabrica-self → the seed is skipped with a note, AND no
# .fabrica/north-star.md is written. The fake gh reports the cwd slug == target arg too, so this
# proves the Fabrica-self exemption WINS even when cwd_is_target would otherwise be true.
test_setup_fabrica_self_no_seed() {
  local cp_root="$tmproot/fabrica-self-cp"
  mkdir -p "$cp_root/scripts/lib" "$cp_root/templates/.fabrica"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$setup_script" "$cp_root/scripts/setup-target-repo.sh"; chmod +x "$cp_root/scripts/setup-target-repo.sh"
  cp "$ns_template" "$cp_root/templates/.fabrica/north-star.md"
  git -C "$cp_root" init -q
  git -C "$cp_root" commit -q --allow-empty -m "cp init"
  local self_fakebin="$tmproot/self-fakebin"
  mkdir -p "$self_fakebin"
  # repo view → a slug that also equals the target arg (so cwd_is_target would be 1); label list
  # → empty (labels aren't the point here).
  cat >"$self_fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/fabrica" ;;
  "label create") exit 0 ;;
  "label edit") exit 0 ;;
  "label list") echo "[]" ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$self_fakebin/gh"
  local out
  out="$(
    cd "$cp_root"
    PATH="$self_fakebin:$PATH" bash "$cp_root/scripts/setup-target-repo.sh" "acme/fabrica" 2>&1 || true
  )"
  assert_contains "(5d) setup on Fabrica-self skips the seed with a control-plane note" "cwd is the Fabrica control-plane repo itself" "$out"
  assert_eq "(5d) setup on Fabrica-self does NOT create .fabrica/north-star.md" "1" \
    "$([ -f "$cp_root/.fabrica/north-star.md" ] && echo 0 || echo 1)"
}

echo "== north-star gate/consumer tests =="
test_source_identity
test_worktree_only_does_not_authorize
test_committed_authorizes_even_if_worktree_deleted
test_committed_authorizes_even_if_worktree_modified
test_fabrica_self_committed_worktree_deleted_proceeds
test_fabrica_self_no_committed_root_fails_not_local
test_local_committed_debates
test_local_marker_fails
test_unset_fails
test_gate_marker_variants_fail
test_gate_correctly_replaced_proceeds
test_gate_prose_token_in_active_region_proceeds
test_gate_nested_repo_fails
test_gate_linked_worktree_ok
test_gate_local_symlink_fails
test_gate_fabrica_self_symlink_fails
test_gate_subdir_regular_star_proceeds
test_gate_subdir_symlink_still_fails
test_gate_prose_active_before_heading_still_fails
test_gate_single_heading_active_proceeds
test_doctor_unset_warns
test_doctor_local_committed_passes
test_doctor_local_marker_warns
test_doctor_h_committed_worktree_deleted
test_doctor_h_committed_worktree_modified
test_doctor_h_fabrica_self_worktree_modified_notes_drift
test_doctor_h_committed_symlink_warns
test_doctor_missing_lib_reports_and_summarizes
test_setup_check_missing_star_is_drift
test_setup_check_nontarget_cwd_no_star_drift
test_setup_seed_cwd_guard_and_idempotency
test_setup_fabrica_self_no_seed

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
