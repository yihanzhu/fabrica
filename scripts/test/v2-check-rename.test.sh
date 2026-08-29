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
#   (e) installer writes only /yshifu and leaves a custom retired command untouched.
#   (f) doctor requires /yshifu and reports a retired command instead of using it.
#
# Run: scripts/test/v2-check-rename.test.sh   (exits non-zero if any assert fails)

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
gate="$test_dir/../check-rename.sh"
installer="$test_dir/../install.sh"
doctor="$test_dir/../doctor.sh"
if [ ! -x "$gate" ]; then
  echo "FAIL: gate not found or not executable at $gate" >&2
  exit 1
fi
if [ ! -x "$installer" ] || [ ! -x "$doctor" ]; then
  echo "FAIL: installer or doctor not found/executable" >&2
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
assert_not_contains() {
  # assert_not_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*)
      failed=$((failed + 1))
      echo "FAIL: $1"
      echo "      unexpected: [$2]"
      ;;
    *)
      passed=$((passed + 1))
      echo "pass: $1"
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

# --- (e) installer creates only /yshifu and preserves unrelated retired file ----
test_installer_retires_bridge() {
  local fresh_home="$tmproot/install-fresh"
  local custom_home="$tmproot/install-custom"
  local link_home="$tmproot/install-link"
  local fresh_yshifu="no" fresh_faber="no" custom_after custom_backup="no"
  local custom_out link_out link_still="no"

  mkdir -p "$fresh_home" "$custom_home/.claude/commands"
  HOME="$fresh_home" "$installer" >/dev/null
  [ -f "$fresh_home/.claude/commands/yshifu.md" ] && fresh_yshifu="yes"
  [ -e "$fresh_home/.claude/commands/faber.md" ] && fresh_faber="yes"
  assert_eq "(e) fresh install creates /yshifu" "yes" "$fresh_yshifu"
  assert_eq "(e) fresh install does not create retired command" "no" "$fresh_faber"

  printf '%s\n' "custom command owned by the operator" > \
    "$custom_home/.claude/commands/faber.md"
  custom_out="$(HOME="$custom_home" "$installer" 2>&1)"
  custom_after="$(cat "$custom_home/.claude/commands/faber.md")"
  [ -e "$custom_home/.claude/commands/faber.md.bak" ] && custom_backup="yes"
  assert_eq "(e) install leaves a custom retired command untouched" \
    "custom command owned by the operator" "$custom_after"
  assert_eq "(e) install does not back up the custom retired command" \
    "no" "$custom_backup"
  assert_contains "(e) install warns about the retired command" \
    "WARNING: retired legacy /faber command remains" "$custom_out"

  mkdir -p "$link_home/.claude/commands"
  ln -s "$link_home/missing-target" "$link_home/.claude/commands/faber.md"
  link_out="$(HOME="$link_home" "$installer" 2>&1)"
  [ -L "$link_home/.claude/commands/faber.md" ] && link_still="yes"
  assert_eq "(e) install leaves a dangling retired symlink untouched" "yes" "$link_still"
  assert_contains "(e) install warns about a dangling retired symlink" \
    "WARNING: retired legacy /faber command remains" "$link_out"
}

# --- (f) doctor has no retired fallback and reports the residual -----------------
test_doctor_rejects_retired_bridge() {
  local doctor_text has_fallback="no" doctor_home="$tmproot/doctor-home"
  local doctor_link_home="$tmproot/doctor-link-home"
  local doctor_out doctor_rc=0 doctor_link_out doctor_link_rc=0
  doctor_text="$(cat "$doctor")"
  # Match the retired literal assignment, not a variable expansion.
  # shellcheck disable=SC2016
  case "$doctor_text" in
    *'yshifu_cmd="$faber_cmd"'*|*'legacy-named /faber bridge copy found'*)
      has_fallback="yes"
      ;;
  esac
  assert_eq "(f) doctor has no retired command fallback" "no" "$has_fallback"
  assert_contains "(f) doctor reports a retired command residual" \
    "retired legacy /faber command still exists" "$doctor_text"

  mkdir -p "$doctor_home/.claude/commands"
  printf '%s\n' "retired bridge" > "$doctor_home/.claude/commands/faber.md"
  doctor_out="$(HOME="$doctor_home" PATH="/usr/bin:/bin" /bin/bash "$doctor" 2>&1)" || \
    doctor_rc=$?
  assert_eq "(f) doctor exits nonzero while retired command remains" "1" "$doctor_rc"
  assert_contains "(f) doctor runtime reports the exact residual" \
    "retired legacy /faber command still exists" "$doctor_out"
  assert_not_contains "(f) doctor never calls the retired command valid" \
    "valid until it is retired" "$doctor_out"

  mkdir -p "$doctor_link_home/.claude/commands"
  ln -s "$doctor_link_home/missing-target" \
    "$doctor_link_home/.claude/commands/faber.md"
  doctor_link_out="$(HOME="$doctor_link_home" PATH="/usr/bin:/bin" \
    /bin/bash "$doctor" 2>&1)" || doctor_link_rc=$?
  assert_eq "(f) doctor exits nonzero for dangling retired symlink" \
    "1" "$doctor_link_rc"
  assert_contains "(f) doctor runtime reports dangling retired symlink" \
    "retired legacy /faber command still exists" "$doctor_link_out"
}

test_clean_repo_passes
test_stray_name_fails
test_case_insensitive_persona
test_untagged_env_key_fails
test_tagged_line_passes
test_work_dir_ignored
test_installer_retires_bridge
test_doctor_rejects_retired_bridge

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]

# A clean-content file with an old name in its PATH must still be flagged.
repo3="$(mktemp -d)"
( cd "$repo3" && git init -q . && git config user.email t@e.c && git config user.name t
  echo "clean content" > faber-notes.md && git add -A && git commit -qm f )
set +e
out="$(cd "$repo3" && bash "$gate" 2>&1)"; code=$?
set -e
[ "$code" -eq 1 ] || fail "old name in pathname must exit 1 (got $code)"
printf '%s\n' "$out" | grep -q "faber-notes.md" || fail "pathname hit must be listed"
rm -rf "$repo3"
echo "ok: pathname check behaves"

# probe-publish refuses anything but digit arguments — the branch name and the
# single staged file are fixed by the script, not by the agent's prompt.
pp="$test_dir/../v2/probe-publish.sh"
for bad in "main; rm -rf /" "../evil" ""; do
  set +e
  ( cd "$(mktemp -d)" && bash "$pp" "$bad" 1 ) >/dev/null 2>&1
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "probe-publish must refuse non-numeric run_id: '$bad'"
done
echo "ok: probe-publish argument guard behaves"

# Inside a run, the wrapper refuses ids that are not this run's.
set +e
( cd "$(mktemp -d)" && GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=1 bash "$pp" 222 1 ) >/dev/null 2>&1
code=$?
set -e
[ "$code" -ne 0 ] || fail "probe-publish must refuse a run_id that is not this run"
set +e
( cd "$(mktemp -d)" && GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=2 bash "$pp" 111 1 ) >/dev/null 2>&1
code=$?
set -e
[ "$code" -ne 0 ] || fail "probe-publish must refuse a stale attempt number"
echo "ok: probe-publish run-binding behaves"
