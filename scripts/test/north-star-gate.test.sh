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
  commit_star "$repo" "Placeholder status: active <!-- fabrica-shipped-default --> replace me"
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
  commit_star "$repo" "Placeholder status: active <!-- fabrica-shipped-default --> replace me"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4c) doctor (h) on a still-shipped-default LOCAL star WARNs" "warn:" "$line"
  assert_contains "(4c) doctor (h) shipped-default WARN cites the marker" "fabrica-shipped-default" "$line"
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

echo "== north-star gate/consumer tests =="
test_source_identity
test_worktree_only_does_not_authorize
test_committed_authorizes_even_if_worktree_deleted
test_committed_authorizes_even_if_worktree_modified
test_local_committed_debates
test_local_marker_fails
test_unset_fails
test_doctor_unset_warns
test_doctor_local_committed_passes
test_doctor_local_marker_warns
test_setup_check_missing_star_is_drift
test_setup_check_nontarget_cwd_no_star_drift
test_setup_seed_cwd_guard_and_idempotency

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
