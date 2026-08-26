#!/usr/bin/env bash
set -euo pipefail

# v2-check-rename.test.sh — bash asserts for the rename gate (scripts/check-rename.sh).
#
# Hermetic: every case builds a throwaway git repo in a temp dir and runs the
# gate from inside it. No network, no gh.
#
# Cases:
#   (a) a clean repo passes (exit 0).
#   (b) a stray old product name fails (exit 1) and the output carries file:line.
#   (b2) matching is case-insensitive — a mixed-case old persona name also fails.
#   (b3) an untagged old env key fails — the tag, not the key family, is what exempts.
#   (c) a line tagged with a same-line "legacy" comment passes (exit 0).
#   (d) old names under work/ are ignored (exit 0).
#
# Run: scripts/test/v2-check-rename.test.sh   (exits non-zero if any assert fails)

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
gate="$test_dir/../check-rename.sh"
if [ ! -x "$gate" ]; then
  echo "FAIL: gate not found or not executable at $gate" >&2
  exit 1
fi

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
assert_contains() {
  # assert_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*)
      passed=$((passed + 1))
      echo "pass: $1"
      ;;
    *)
      failed=$((failed + 1))
      echo "FAIL: $1"
      echo "      needle:   [$2]"
      echo "      haystack: [$3]"
      ;;
  esac
}

# make_repo <name> — init a git repo with one clean tracked file; echo its path.
make_repo() {
  local path="$tmproot/$1"
  mkdir -p "$path"
  git -C "$path" init -q
  echo "a clean note about ystack and yshifu" > "$path/notes.md"
  git -C "$path" add notes.md
  git -C "$path" commit -q -m "init"
  echo "$path"
}

# track <repo> <relpath> — stage and commit one file so git ls-files sees it.
track() {
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# run_gate <repo> — run the gate from inside <repo>; fills $out and $rc.
out=""
rc=0
run_gate() {
  rc=0
  out="$(cd "$1" && "$gate" 2>&1)" || rc=$?
}

# --- (a) a clean repo passes -------------------------------------------------------
test_clean_repo_passes() {
  local repo; repo="$(make_repo "clean")"
  run_gate "$repo"
  assert_eq "(a) clean repo exits 0" "0" "$rc"
  assert_contains "(a) clean repo reports clean" "check-rename: clean" "$out"
}

# --- (b) a stray old product name fails with file:line -----------------------------
test_stray_name_fails() {
  local repo; repo="$(make_repo "stray")"
  mkdir -p "$repo/src"
  printf 'first line is fine\necho welcome to fabrica\n' > "$repo/src/app.sh"
  track "$repo" "src/app.sh"
  run_gate "$repo"
  assert_eq "(b) stray old name exits 1" "1" "$rc"
  assert_contains "(b) hit is listed as file:line" "src/app.sh:2:" "$out"
  assert_contains "(b) hit line text is shown" "welcome to fabrica" "$out"
}

# --- (b2) matching is case-insensitive (old persona name, mixed case) --------------
test_case_insensitive_persona() {
  local repo; repo="$(make_repo "persona")"
  echo "ask FaBeR to review this" > "$repo/doc.md"
  track "$repo" "doc.md"
  run_gate "$repo"
  assert_eq "(b2) mixed-case old persona name exits 1" "1" "$rc"
  assert_contains "(b2) hit is listed as file:line" "doc.md:1:" "$out"
}

# --- (b3) an untagged old env key fails — only the tag exempts ----------------------
test_untagged_env_key_fails() {
  local repo; repo="$(make_repo "untagged")"
  echo 'FABRICA_CODER_MODEL=sonnet' > "$repo/conf.sh"
  track "$repo" "conf.sh"
  run_gate "$repo"
  assert_eq "(b3) untagged old env key exits 1" "1" "$rc"
  assert_contains "(b3) hit is listed as file:line" "conf.sh:1:" "$out"
}

# --- (c) a "legacy"-tagged line passes -------------------------------------
test_tagged_line_passes() {
  local repo; repo="$(make_repo "tagged")"
  # Quoted heredoc: the fixture text is written literally, nothing expands here.
  cat > "$repo/lib.sh" <<'FIXTURE'
star="$root/.fabrica/north-star.md"  # legacy: old per-target dir
val="${FABRICA_CODER_MODEL:-}"  # legacy: old env key alias
FIXTURE
  track "$repo" "lib.sh"
  run_gate "$repo"
  assert_eq "(c) tagged back-compat lines exit 0" "0" "$rc"
  assert_contains "(c) tagged repo reports clean" "check-rename: clean" "$out"
}

# --- (d) old names under work/ are ignored ------------------------------------------
test_work_dir_ignored() {
  local repo; repo="$(make_repo "history")"
  mkdir -p "$repo/work/old-initiative"
  printf 'fabrica did this\nfaber approved it\n' > "$repo/work/old-initiative/intent.md"
  track "$repo" "work/old-initiative/intent.md"
  run_gate "$repo"
  assert_eq "(d) old names under work/ exit 0" "0" "$rc"
  assert_contains "(d) work/-only repo reports clean" "check-rename: clean" "$out"
}

test_clean_repo_passes
test_stray_name_fails
test_case_insensitive_persona
test_untagged_env_key_fails
test_tagged_line_passes
test_work_dir_ignored

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
