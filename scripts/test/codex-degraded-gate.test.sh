#!/usr/bin/env bash
set -euo pipefail

# codex-degraded-gate.test.sh — #117 hardening: FAIL LOUDLY on a degraded/non-substantive Codex
# run instead of posting a fake "clean" verdict.
#
# BACKGROUND (real incident, 2026-07-11): `codex-code-mode-host` failed to spawn (missing from a
# Homebrew codex install). `codex exec review` still "completed" — exit 0, ~8-14s, confidence
# ~0.05, generic "no actionable findings" — having done ZERO diff inspection. codex-review.sh
# posted that as a normal clean review; under the standing auto-merge rail, a fake "clean" would
# auto-merge unreviewed code into the control plane. See issue #117.
#
# PART 1 asserts the shared detector (scripts/lib/codex-degraded.sh) in isolation — no
# git/gh/codex needed, just plain text on disk.
#
# PART 2 runs the REAL scripts/codex-review.sh and scripts/manager-review.sh end to end, with
# `gh` and `codex` STUBBED on PATH and REAL git (throwaway local bare "remotes", the same
# technique scripts/test/north-star-gate.test.sh uses) — testing the actual wiring, not a
# reimplementation of it. Per issue #117's required tests:
#   (a) codex output containing a code-mode spawn-error line ⇒ script exits non-zero, does NOT
#       post a clean verdict, posts an explicit DEGRADED marker instead.
#   (b) codex non-zero exit ⇒ same.
#   (c) a normal clean codex run ⇒ still passes (guards against over-triggering).
# Each is checked for BOTH codex-review.sh (PR review) and manager-review.sh (issue debate), plus
# a signal-in-stderr-only variant (the pattern must be grepped from stderr too, not just stdout).
#
# Also asserts the belt-and-suspenders property called out in both scripts' #117 comments: the
# DEGRADED marker's header line and marker keys are DIFFERENT from the real clean-verdict ones, so
# scripts/merge-pr.sh's marker parser (which matches the EXACT line
# `^## Codex reviewer (cross-vendor, read-only)$` plus `Reviewed-head:`/`Reviewed-base:`) can never
# mistake a degraded run for a completed review, even mechanically (independent of whether a human
# or Faber reads the comment text carefully).
#
# OFFLINE and hermetic. Run: scripts/test/codex-degraded-gate.test.sh

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$test_dir/../.." && pwd -P)"
cd_lib="$repo_root/scripts/lib/codex-degraded.sh"
codex_review="$repo_root/scripts/codex-review.sh"
manager_review="$repo_root/scripts/manager-review.sh"
for f in "$cd_lib" "$codex_review" "$manager_review"; do
  if [ ! -f "$f" ]; then echo "FAIL: missing $f" >&2; exit 1; fi
done
# shellcheck source=scripts/lib/codex-degraded.sh
. "$cd_lib"

# Give git a per-process identity (the runner has no global user); scoped via env, not config.
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

tmproot="$(mktemp -d)"
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

passed=0
failed=0
assert_eq() {
  # assert_eq <label> <expected> <actual>
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
assert_not_contains() {
  # assert_not_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected NOT to contain: [$2]"; echo "      actual: [$3]" ;;
    *) passed=$((passed + 1)); echo "pass: $1" ;;
  esac
}
assert_no_line_match() {
  # assert_no_line_match <label> <extended-regex> <file> — the exact-line check merge-pr.sh does
  if grep -qE -- "$2" "$3" 2>/dev/null; then
    failed=$((failed + 1)); echo "FAIL: $1"; echo "      line matched, but must NOT: [$2]"
  else
    passed=$((passed + 1)); echo "pass: $1"
  fi
}

# =====================================================================================
# PART 1 — the shared detector in isolation (no git/gh/codex).
# =====================================================================================
out_a="$tmproot/out-a"; err_a="$tmproot/err-a"

printf 'Failed to spawn code-mode host: no such file or directory\n' >"$out_a"; : >"$err_a"
if reason="$(cd_degraded_reason 0 "$out_a" "$err_a")"; then
  assert_contains "(1a) signal in stdout capture -> degraded, reason mentions the signal" "signal" "$reason"
else
  failed=$((failed + 1)); echo "FAIL: (1a) expected degraded for a code-mode-host signal in stdout"
fi

: >"$out_a"; printf 'CODE-MODE-HOST crashed on startup\n' >"$err_a"
if cd_degraded_reason 0 "$out_a" "$err_a" >/dev/null; then
  passed=$((passed + 1)); echo "pass: (1b) case-insensitive signal found in STDERR (not just stdout) -> degraded"
else
  failed=$((failed + 1)); echo "FAIL: (1b) expected degraded for a case-insensitive signal in stderr"
fi

# Every documented signal string in the spec is individually detected (case-insensitively).
for sig in \
  'failed to spawn code-mode host' \
  'code-mode host' \
  'code-mode-host' \
  'repository inspection tool failed' \
  'execution environment failed to start' \
  'failed to start its command host'
do
  printf 'Some preamble. %s. Some trailer.\n' "$sig" >"$out_a"; : >"$err_a"
  if cd_degraded_reason 0 "$out_a" "$err_a" >/dev/null; then
    passed=$((passed + 1)); echo "pass: (1c) documented signal detected: '$sig'"
  else
    failed=$((failed + 1)); echo "FAIL: (1c) documented signal NOT detected: '$sig'"
  fi
done

printf 'No actionable findings.\n' >"$out_a"; : >"$err_a"
if reason="$(cd_degraded_reason 7 "$out_a" "$err_a")"; then
  assert_contains "(1d) non-zero codex exit alone (no signal in either stream) -> degraded, reason cites the code" "7" "$reason"
else
  failed=$((failed + 1)); echo "FAIL: (1d) expected degraded on a bare non-zero exit"
fi

# Genuine clean run (exit 0, no signal anywhere) must NOT be flagged -- the over-triggering guard.
printf 'No actionable findings. The diff looks correct and well-tested.\n' >"$out_a"; : >"$err_a"
if cd_degraded_reason 0 "$out_a" "$err_a" >/dev/null; then
  failed=$((failed + 1)); echo "FAIL: (1e) a genuine clean review (exit 0, no signal) was wrongly flagged degraded"
else
  passed=$((passed + 1)); echo "pass: (1e) genuine clean run (exit 0, no signal) is NOT degraded"
fi

# Missing/empty capture files never crash the check and are simply "no signal there".
if cd_degraded_reason 0 "$tmproot/does-not-exist" "" >/dev/null; then
  failed=$((failed + 1)); echo "FAIL: (1f) a missing/empty capture file was wrongly flagged degraded"
else
  passed=$((passed + 1)); echo "pass: (1f) missing/empty capture files (exit 0) are NOT degraded"
fi

# =====================================================================================
# PART 2 — end to end through the REAL scripts, gh + codex stubbed, git real.
# =====================================================================================

fakebin="$tmproot/fakebin"
mkdir -p "$fakebin"

# Fake gh: covers every gh call either script makes (see codex-review.sh / manager-review.sh
# source for the exhaustive list). FAKE_REPO_NAME picks the identity; FAKE_GH_POSTED is the path
# the posted PR/issue comment body is captured to (so tests can assert on exactly what was — or
# was not — posted).
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
cmd="${1:-}"; sub="${2:-}"
name="${FAKE_REPO_NAME:-testrepo}"
posted="${FAKE_GH_POSTED:-/dev/null}"
case "$cmd $sub" in
  "repo view")
    if printf '%s\n' "$@" | grep -q 'defaultBranchRef'; then
      echo "main"
      exit 0
    fi
    if printf '%s\n' "$@" | grep -q 'url'; then
      echo "https://github.com/someone/${name}"
      exit 0
    fi
    echo "someone/${name}"
    exit 0 ;;
  "pr view")
    echo "main"
    exit 0 ;;
  "pr comment")
    cat >"$posted"
    exit 0 ;;
  "issue view")
    if printf '%s\n' "$@" | grep -q 'title'; then
      echo "A proposal"
    elif printf '%s\n' "$@" | grep -q 'comments'; then
      echo "(no comments yet)"
    else
      echo "issue body text"
    fi
    exit 0 ;;
  "issue comment")
    prev=""; bf=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then bf="$a"; fi
      prev="$a"
    done
    if [ "$bf" = "-" ]; then
      cat >"$posted"
    else
      cat "$bf" >"$posted"
    fi
    exit 0 ;;
  *)
    exit 0 ;;
esac
GH
chmod +x "$fakebin/gh"

# Fake codex. FAKE_CODEX_MODE selects the scenario under test:
#   clean-review   - codex-review.sh's genuine-pass shape (exit 0, no signal)
#   clean-verdict  - manager-review.sh's genuine-pass shape (exit 0, PROCEED, no signal)
#   signal         - a code-mode/host spawn-failure line in the -o CAPTURE (exit 0)
#   signal-stderr  - the SAME signal, but only in STDERR, with a clean-looking -o capture (exit 0)
#   nonzero        - codex itself exits non-zero
# Must handle BOTH invocation shapes without crossing wires: codex-review.sh's `review ... -o
# <tmp>` (no stdin), and manager-review.sh's `exec ... -o <tmp> -` (prompt piped over stdin,
# trailing `-`) -- stdin MUST be drained in the latter case so the upstream printf doesn't SIGPIPE.
cat >"$fakebin/codex" <<'CODEX'
#!/usr/bin/env bash
mode="${FAKE_CODEX_MODE:-clean-review}"
out=""; prev=""; last=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
  last="$a"
done
if [ "$last" = "-" ]; then
  cat >/dev/null 2>&1 || true
fi
case "$mode" in
  clean-review)
    [ -n "$out" ] && printf 'No actionable findings. The diff looks correct.\n' >"$out"
    exit 0 ;;
  clean-verdict)
    [ -n "$out" ] && printf 'VERDICT: PROCEED\nREASONING: stub genuine debate.\nGAP FABER MISSED: none.\n' >"$out"
    exit 0 ;;
  signal)
    [ -n "$out" ] && printf 'Failed to spawn code-mode host: No such file or directory\n' >"$out"
    exit 0 ;;
  signal-stderr)
    [ -n "$out" ] && printf 'No actionable findings.\n' >"$out"
    echo "repository inspection tool failed to start" >&2
    exit 0 ;;
  nonzero)
    echo "codex: fatal: simulated network error" >&2
    exit 3 ;;
  *)
    exit 0 ;;
esac
CODEX
chmod +x "$fakebin/codex"

# --- throwaway local bare "remotes" (mirrors scripts/test/north-star-gate.test.sh) -----------
remotes_root="$tmproot/remotes"
mkdir -p "$remotes_root"

setup_remote() {
  # setup_remote <repo> <name> — a bare repo backing <name>'s "origin", reached via an insteadOf
  # rewrite so the actual transport is local/offline while the CONFIGURED url is a real-looking
  # GitHub identity (what ghr_select_remote/ghr_gh_repo_id match on).
  local repo="$1" name="$2"
  local bare="$remotes_root/${name}.git"
  git init -q --bare "$bare"
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
  git -C "$repo" remote add origin "https://github.com/someone/${name}.git"
  git -C "$repo" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
}
push_default() {
  local repo="$1"
  git -C "$repo" push -q -f origin HEAD:refs/heads/main
}
push_pr_head() {
  # push_pr_head <repo> <pr#> — publish the repo's CURRENT HEAD as refs/pull/<pr#>/head on the
  # bare remote, the ref codex-review.sh fetches as the PR head.
  local repo="$1" pr="$2"
  git -C "$repo" push -q -f origin HEAD:"refs/pull/${pr}/head"
}

# make_target <name> — a throwaway git repo on default branch `main`, one commit, backed by a
# matching gh-bound remote; echoes its path.
make_target() {
  local name="$1"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  echo "hello" >"$path/README.md"
  git -C "$path" add README.md
  git -C "$path" commit -q -m "init"
  setup_remote "$path" "$name"
  push_default "$path"
  echo "$path"
}

posted_file="$tmproot/posted-comment"

run_codex_review() {
  # run_codex_review <repo_dir> <pr#> <codex_mode> ; echoes "<rc>|<combined-output>". The posted
  # comment body (if any) lands in $posted_file (truncated first, so a no-post case reads empty).
  local repo_dir="$1" pr="$2" mode="$3" rc out
  : >"$posted_file"
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR=1 FAKE_REPO_NAME="$(basename "$repo_dir")" \
      FAKE_CODEX_MODE="$mode" FAKE_GH_POSTED="$posted_file" \
      bash "$codex_review" "$pr" 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

run_manager_review() {
  # run_manager_review <repo_dir> <issue#> <codex_mode> ; same "<rc>|<combined-output>" shape.
  local repo_dir="$1" issue="$2" mode="$3" rc out
  : >"$posted_file"
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR=1 FAKE_REPO_NAME="$(basename "$repo_dir")" \
      FAKE_CODEX_MODE="$mode" FAKE_GH_POSTED="$posted_file" \
      bash "$manager_review" "$issue" 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# The EXACT line codex-review.sh's real clean comment carries, and scripts/merge-pr.sh's marker
# parser matches (see merge-pr.sh's jq `test("(?m)^## Codex reviewer \\(cross-vendor, read-only\\)$")`).
cr_clean_header_re='^## Codex reviewer \(cross-vendor, read-only\)$'
mr_clean_header_re='^## Codex manager-reviewer \(cross-vendor, read-only\)$'

# -------------------------------------------------------------------------------------
# codex-review.sh (PR review)
# -------------------------------------------------------------------------------------
cr_target="$(make_target "cr-target")"
# A distinct commit as the "PR head" so head != base, mirroring a real PR (content is irrelevant
# since codex is stubbed and never really diffs).
echo "change" >>"$cr_target/README.md"
git -C "$cr_target" add README.md
git -C "$cr_target" commit -q -m "pr change"
push_pr_head "$cr_target" 7
# Move the local branch back to main's tip so `git worktree add --detach "$worktree" "$pr_head"`
# in the script exercises a fetched ref, not a locally-resident branch tip (matches a real PR).
git -C "$cr_target" reset -q --hard HEAD~1

# (2a) codex output contains a code-mode spawn-error line -> non-zero exit, no clean verdict,
# explicit DEGRADED marker posted instead. Required test (a).
res="$(run_codex_review "$cr_target" 7 "signal")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(2a) codex-review.sh: code-mode spawn-error signal in -o output -> non-zero exit" "1" "$rc"
assert_contains "(2a) DEGRADED marker was posted" "DEGRADED" "$posted"
assert_not_contains "(2a) the clean-verdict header text was NOT posted" "## Codex reviewer (cross-vendor, read-only)" "$posted"
assert_no_line_match "(2a) the EXACT header merge-pr.sh matches is absent (mechanically not a review)" "$cr_clean_header_re" "$posted_file"
assert_no_line_match "(2a) no Reviewed-head marker (merge-pr.sh's SHA-pin key) was stamped" '^Reviewed-head: ' "$posted_file"
assert_contains "(2a) the operator's terminal output surfaces the DEGRADED failure too" "DEGRADED" "$out"

# (2b) codex exits non-zero -> same. Required test (b).
res="$(run_codex_review "$cr_target" 7 "nonzero")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(2b) codex-review.sh: codex non-zero exit -> non-zero exit" "1" "$rc"
assert_contains "(2b) DEGRADED marker was posted on a bare non-zero codex exit" "DEGRADED" "$posted"
assert_no_line_match "(2b) the EXACT clean header is absent" "$cr_clean_header_re" "$posted_file"
assert_contains "(2b) stderr (simulated network error) was surfaced to the operator" "simulated network error" "$out"

# (2c) the signal appears ONLY in stderr, with a clean-looking -o capture -> still caught (the
# spec requires grepping BOTH streams, not just the -o file).
res="$(run_codex_review "$cr_target" 7 "signal-stderr")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(2c) codex-review.sh: spawn-error signal in STDERR only -> non-zero exit" "1" "$rc"
assert_contains "(2c) DEGRADED marker was posted for a stderr-only signal" "DEGRADED" "$posted"

# (2d) a normal clean codex run must still PASS -- the over-triggering guard. Required test (c).
res="$(run_codex_review "$cr_target" 7 "clean-review")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(2d) codex-review.sh: genuine clean review -> exits 0" "0" "$rc"
assert_not_contains "(2d) a genuine clean review is NOT flagged DEGRADED" "DEGRADED" "$posted"
assert_contains "(2d) the real clean-verdict header WAS posted" "## Codex reviewer (cross-vendor, read-only)" "$posted"
assert_contains "(2d) the Reviewed-head marker WAS stamped on a genuine pass" "Reviewed-head:" "$posted"
assert_contains "(2d) Codex's genuine finding text made it through verbatim" "No actionable findings" "$posted"

# -------------------------------------------------------------------------------------
# manager-review.sh (issue debate) — needs a committed, ACTIVE north star before it will ever
# invoke codex (that gate is unrelated to #117; see scripts/test/north-star-gate.test.sh). Uses
# the same minimal valid star shape that suite uses: a single heading with `status: active`.
# -------------------------------------------------------------------------------------
mr_target="$(make_target "mr-target")"
mkdir -p "$mr_target/.fabrica"
printf '### our test north star · status: **active**\n' >"$mr_target/.fabrica/north-star.md"
git -C "$mr_target" add .fabrica/north-star.md
git -C "$mr_target" commit -q -m "set north star"
push_default "$mr_target"

# (3a) codex output contains a code-mode spawn-error line -> non-zero exit, no PROCEED/REFINE/
# DROP verdict, explicit DEGRADED marker posted instead. Required test (a).
res="$(run_manager_review "$mr_target" 1 "signal")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(3a) manager-review.sh: code-mode spawn-error signal -> non-zero exit" "1" "$rc"
assert_contains "(3a) DEGRADED marker was posted to the issue" "DEGRADED" "$posted"
assert_contains "(3a) VERDICT is explicitly DEGRADED, never a real verdict" "VERDICT: DEGRADED" "$posted"
assert_not_contains "(3a) never posts VERDICT: PROCEED on a degraded run" "VERDICT: PROCEED" "$posted"
assert_no_line_match "(3a) the EXACT clean manager-reviewer header is absent" "$mr_clean_header_re" "$posted_file"

# (3b) codex exits non-zero -> same. Required test (b).
res="$(run_manager_review "$mr_target" 1 "nonzero")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(3b) manager-review.sh: codex non-zero exit -> non-zero exit" "1" "$rc"
assert_contains "(3b) DEGRADED marker was posted on a bare non-zero codex exit" "DEGRADED" "$posted"
assert_not_contains "(3b) never posts VERDICT: PROCEED on a degraded run" "VERDICT: PROCEED" "$posted"

# (3c) a normal clean debate (PROCEED) must still PASS -- the over-triggering guard. Required
# test (c).
res="$(run_manager_review "$mr_target" 1 "clean-verdict")"; rc="${res%%|*}"; out="${res#*|}"
posted="$(cat "$posted_file" 2>/dev/null || true)"
assert_eq "(3c) manager-review.sh: genuine debate -> exits 0" "0" "$rc"
assert_not_contains "(3c) a genuine PROCEED debate is NOT flagged DEGRADED" "DEGRADED" "$posted"
assert_contains "(3c) the real clean manager-reviewer header WAS posted" "## Codex manager-reviewer (cross-vendor, read-only)" "$posted"
assert_contains "(3c) Codex's genuine PROCEED verdict made it through verbatim" "VERDICT: PROCEED" "$posted"

echo
echo "passed: $passed, failed: $failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
