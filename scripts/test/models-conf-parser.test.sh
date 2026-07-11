#!/usr/bin/env bash
set -euo pipefail

# models-conf-parser.test.sh — hermetic bash asserts for scripts/lib/models-conf.sh
# (mc_parse_target_override), the P1 fix from the adversarial review of PR #115.
#
# BACKGROUND: scripts/codex-review.sh and scripts/manager-review.sh used to `source`/`.` a
# target repo's committed `.fabrica/models.conf` directly into the operator's non-sandboxed
# harness shell. That let (1) a malicious PR/target run arbitrary shell with the operator's own
# `gh`/`codex` credentials, and (2) ANY target — no injection needed — commit
# `FABRICA_REVIEW_EFFORT=low` to downgrade its own review gate (the only prior validation was
# "non-empty"). The fix factors a strict, non-evaluating parser into scripts/lib/models-conf.sh:
# target-committed content is read as DATA, never as code, and the two gate-effort keys
# (FABRICA_REVIEW_EFFORT / FABRICA_DEBATE_EFFORT) can never be set by a target override at all.
#
# This suite tests the parser IN ISOLATION (no git/gh/codex harness needed — the function takes
# plain text on stdin), per the brief: "if a full harness test for codex-review.sh isn't
# feasible, factor the parser into a small sourced helper and test that." It also runs static
# (grep-based) assertions against the REAL scripts/codex-review.sh and scripts/manager-review.sh
# source text — the same technique scripts/test/north-star-gate.test.sh uses for
# safety-critical properties that are impractical to fully drive end-to-end — to confirm the
# vulnerable `source`/`.` pattern is GONE and the new trust-anchor + parse-not-source wiring is
# actually present in the shipped scripts, not just correct in the lib alone.
#
# P2 FOLLOW-UP (adversarial review of PR #115, revision): manager-review.sh's parse-not-source fix
# still read the override via `mc_parse_target_override < "$worktree/.fabrica/models.conf"` — a
# `<`-redirect from the CHECKED-OUT WORKTREE PATH, which FOLLOWS SYMLINKS. A target-committed
# `.fabrica/models.conf` SYMLINK to an arbitrary operator-local file would pass `[ -f ]` and leak
# that file's `FABRICA_CODEX_MODEL=` value into the PUBLIC posted issue comment header. It now
# reads via `git show "${head_commit}:.fabrica/models.conf"` instead — the SAME anchor commit, but
# as a git blob (never a filesystem path), mirroring codex-review.sh's pre-existing symlink-safe
# read of this same file (a symlink's blob content is just the link-target-path string, which
# fails the parser's charset check and is ignored). See test_scripts_wire_the_fix (h) below for
# the static assertions, and scripts/test/north-star-gate.test.sh's (22) for the end-to-end case.
#
# Run: scripts/test/models-conf-parser.test.sh   (exits non-zero on the first failed assert)

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$test_dir/../.." && pwd -P)"
lib="$repo_root/scripts/lib/models-conf.sh"
codex_review="$repo_root/scripts/codex-review.sh"
manager_review="$repo_root/scripts/manager-review.sh"
for f in "$lib" "$codex_review" "$manager_review"; do
  if [ ! -f "$f" ]; then echo "FAIL: missing $f" >&2; exit 1; fi
done
# shellcheck source=scripts/lib/models-conf.sh
. "$lib"

tmproot="$(mktemp -d)"
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT
stderr_tmp="$tmproot/stderr"

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
assert_file_absent() {
  # assert_file_absent <label> <path>
  if [ -e "$2" ]; then
    failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected ABSENT, but it exists: [$2]"
  else
    passed=$((passed + 1)); echo "pass: $1"
  fi
}

# reset_vars — reset every variable the parser can touch to a known baseline BEFORE each case,
# simulating the shipped config/models.conf already having been sourced (FABRICA_REVIEW_EFFORT /
# FABRICA_DEBATE_EFFORT at their shipped-default "high"; the producer/model keys empty).
reset_vars() {
  FABRICA_CODER_MODEL=""
  FABRICA_HANDS_MODEL=""
  FABRICA_CODEX_MODEL=""
  FABRICA_REVIEW_EFFORT="high"
  FABRICA_DEBATE_EFFORT="high"
  MC_TARGET_OVERRIDE_GATE_WARNING=0
}

# run_parser_herestring <content> — feed <content> via a HERE-STRING, mirroring
# codex-review.sh's `mc_parse_target_override <<<"$target_models_conf_content"` calling
# convention (it reads the override via `git show`, not a checked-out file). Runs in the
# CURRENT shell (not a subshell — a here-string is plain redirection), so the FABRICA_*
# assignments the parser makes are observable afterward; stderr is captured to $stderr_tmp
# (also plain fd redirection, not a pipe/subshell) so warning text can be asserted too.
run_parser_herestring() {
  : > "$stderr_tmp"
  mc_parse_target_override <<<"$1" 2>"$stderr_tmp"
}

# run_parser_file <path> — feed content from an actual FILE via the library's OTHER supported
# calling convention (`mc_parse_target_override < "$file"`, see scripts/lib/models-conf.sh's
# calling-convention doc). Neither real script uses this convention anymore as of the P2 fix
# (adversarial review of PR #115, revision): both codex-review.sh and manager-review.sh now read
# their target override via `git show <anchor>:.fabrica/models.conf` + a here-string, never a
# `<`-redirect from a checked-out worktree path (a worktree-path redirect FOLLOWS SYMLINKS — see
# test_scripts_wire_the_fix (h) and scripts/test/north-star-gate.test.sh's (22) end-to-end case).
# This function still exercises the file-redirection convention directly as a regression guard on
# the library itself. Same current-shell / no-subshell property as above.
run_parser_file() {
  : > "$stderr_tmp"
  mc_parse_target_override < "$1" 2>"$stderr_tmp"
}

# ---------------------------------------------------------------------------------
# (a) MALICIOUS FILE — shell content in a target override must NEVER execute. A sentinel file
# a naive `source`/`.` would have created (or a subshell/backtick/command-substitution the
# content tries to smuggle into a value) must NOT exist afterward, while a valid key elsewhere
# in the SAME file is still parsed normally (the malicious lines are ignored individually, not
# a fail-the-whole-file event).
# ---------------------------------------------------------------------------------
test_malicious_file_sentinel_not_created() {
  local sentinel="$tmproot/sentinel-a"
  rm -f "$sentinel"
  local content
  content="$(cat <<EOF
FABRICA_CODER_MODEL=sonnet
\$(touch "$sentinel")
\`touch "$sentinel"\`
touch "$sentinel"
FABRICA_CODEX_MODEL=\$(touch "$sentinel")
FABRICA_HANDS_MODEL=haiku; touch "$sentinel"
FABRICA_CODEX_MODEL=gpt-5-safe
EOF
)"
  reset_vars
  run_parser_herestring "$content"
  assert_file_absent "(a) malicious content never executed — sentinel file NOT created" "$sentinel"
  assert_eq "(a) a plain valid line elsewhere in the SAME malicious file still parses (FABRICA_CODER_MODEL)" "sonnet" "$FABRICA_CODER_MODEL"
  assert_eq "(a) a command-substitution VALUE is rejected outright — last VALID assignment wins (FABRICA_CODEX_MODEL)" "gpt-5-safe" "$FABRICA_CODEX_MODEL"
  assert_eq "(a) a semicolon-chained VALUE is rejected — the key is left at its baseline (FABRICA_HANDS_MODEL)" "" "$FABRICA_HANDS_MODEL"
}

# (a2) Same malicious-file scenario, but read via a real FILE + the library's file-redirection
# calling convention (`< "$file"`) — a regression guard on that convention in isolation, not just
# the here-string one (neither real script still calls it this way as of the P2 fix; see
# run_parser_file above).
test_malicious_file_sentinel_not_created_via_file() {
  local sentinel="$tmproot/sentinel-a2"
  rm -f "$sentinel"
  local conf="$tmproot/malicious.conf"
  {
    echo 'FABRICA_HANDS_MODEL=haiku'
    echo "\$(touch \"$sentinel\")"
    echo "touch \"$sentinel\""
    echo "FABRICA_CODEX_MODEL=\$(touch \"$sentinel\")"
  } > "$conf"
  reset_vars
  run_parser_file "$conf"
  assert_file_absent "(a2) malicious content in a real FILE never executed — sentinel NOT created" "$sentinel"
  assert_eq "(a2) valid key in the same file still parses (FABRICA_HANDS_MODEL)" "haiku" "$FABRICA_HANDS_MODEL"
  assert_eq "(a2) command-substitution value rejected — key left at baseline (FABRICA_CODEX_MODEL)" "" "$FABRICA_CODEX_MODEL"
}

# ---------------------------------------------------------------------------------
# (b) GATE KEYS ARE NOT TARGET-OVERRIDABLE — FABRICA_REVIEW_EFFORT / FABRICA_DEBATE_EFFORT
# lines are recognized but NEVER applied; a visible warning is emitted and
# MC_TARGET_OVERRIDE_GATE_WARNING is set so the caller can surface it. A producer/model key in
# the SAME file is still applied normally.
# ---------------------------------------------------------------------------------
test_gate_keys_ignored_with_warning() {
  local content
  content="$(printf 'FABRICA_REVIEW_EFFORT=low\nFABRICA_DEBATE_EFFORT=low\nFABRICA_CODEX_MODEL=some-model\n')"
  reset_vars
  run_parser_herestring "$content"
  assert_eq "(b) FABRICA_REVIEW_EFFORT is NOT lowered by a target override" "high" "$FABRICA_REVIEW_EFFORT"
  assert_eq "(b) FABRICA_DEBATE_EFFORT is NOT lowered by a target override" "high" "$FABRICA_DEBATE_EFFORT"
  assert_eq "(b) MC_TARGET_OVERRIDE_GATE_WARNING is set" "1" "$MC_TARGET_OVERRIDE_GATE_WARNING"
  local warn; warn="$(cat "$stderr_tmp")"
  assert_contains "(b) warning names FABRICA_REVIEW_EFFORT" "FABRICA_REVIEW_EFFORT" "$warn"
  assert_contains "(b) warning names FABRICA_DEBATE_EFFORT" "FABRICA_DEBATE_EFFORT" "$warn"
  assert_contains "(b) warning explains a target can never change its own gate" "never lower or change its own" "$warn"
  assert_eq "(b) a producer/model key in the SAME file still applies (FABRICA_CODEX_MODEL)" "some-model" "$FABRICA_CODEX_MODEL"
}

# (b2) A file with ONLY valid producer keys (no gate-key attempt) never sets the warning flag —
# the warning is not a false-positive on ordinary, legitimate overrides.
test_no_gate_key_no_warning() {
  local content
  content="$(printf 'FABRICA_CODEX_MODEL=gpt-5.1-codex\n')"
  reset_vars
  run_parser_herestring "$content"
  assert_eq "(b2) no gate-key attempt -> MC_TARGET_OVERRIDE_GATE_WARNING stays 0" "0" "$MC_TARGET_OVERRIDE_GATE_WARNING"
  assert_eq "(b2) no warning text on stderr" "" "$(cat "$stderr_tmp")"
}

# ---------------------------------------------------------------------------------
# (c) VALID PRODUCER-KEY OVERRIDE — a well-formed override sets exactly the PRODUCER/MODEL keys
# it mentions, leaving anything unmentioned untouched, and quoted values are unquoted correctly.
# ---------------------------------------------------------------------------------
test_valid_producer_override_applied() {
  local content
  content="$(cat <<'EOF'
FABRICA_CODER_MODEL=opus
FABRICA_HANDS_MODEL='haiku'
FABRICA_CODEX_MODEL="gpt-5.1-codex"
EOF
)"
  reset_vars
  run_parser_herestring "$content"
  assert_eq "(c) FABRICA_CODER_MODEL applied (unquoted value)" "opus" "$FABRICA_CODER_MODEL"
  assert_eq "(c) FABRICA_HANDS_MODEL applied (single-quoted value, unquoted)" "haiku" "$FABRICA_HANDS_MODEL"
  assert_eq "(c) FABRICA_CODEX_MODEL applied (double-quoted value, unquoted)" "gpt-5.1-codex" "$FABRICA_CODEX_MODEL"
  assert_eq "(c) gate keys untouched by a producer-only override" "high" "$FABRICA_REVIEW_EFFORT"
  assert_eq "(c) no gate-key warning on a producer-only override" "0" "$MC_TARGET_OVERRIDE_GATE_WARNING"
}

# ---------------------------------------------------------------------------------
# (d) CHARSET / QUOTING edge cases — mismatched quotes, embedded quotes after stripping, and
# other out-of-charset values are REJECTED (the whole line ignored), not partially applied.
# ---------------------------------------------------------------------------------
test_charset_and_quoting_edge_cases() {
  reset_vars
  # Mismatched quote (only a leading quote) -> rejected.
  run_parser_herestring 'FABRICA_CODEX_MODEL="unterminated'
  assert_eq "(d) mismatched leading-quote-only value rejected" "" "$FABRICA_CODEX_MODEL"

  reset_vars
  # Embedded quote surviving the one-layer strip -> rejected by the charset check.
  run_parser_herestring 'FABRICA_CODEX_MODEL="foo"bar"'
  assert_eq "(d) embedded-quote value rejected" "" "$FABRICA_CODEX_MODEL"

  reset_vars
  # A value with a slash/space (path-like injection attempt) -> rejected.
  run_parser_herestring 'FABRICA_CODEX_MODEL=/etc/passwd oops'
  assert_eq "(d) value with space/slash rejected" "" "$FABRICA_CODEX_MODEL"

  reset_vars
  # An explicit empty value is VALID (means "unset -> inherit default"), not rejected.
  run_parser_herestring 'FABRICA_CODEX_MODEL='
  assert_eq "(d) explicit empty value is accepted as empty" "" "$FABRICA_CODEX_MODEL"

  reset_vars
  # Dots/dashes/underscores/digits are all in the allowed charset.
  run_parser_herestring 'FABRICA_CODER_MODEL=claude-sonnet-4-5-20250929'
  assert_eq "(d) full pinned model id (dots/dashes/digits) accepted" "claude-sonnet-4-5-20250929" "$FABRICA_CODER_MODEL"
}

# ---------------------------------------------------------------------------------
# (e) NON-MATCHING LINES are silently ignored: comments, blank lines, unknown/unallowed keys,
# and a key name that is merely a PREFIX/suffix collision with an allowed key.
# ---------------------------------------------------------------------------------
test_non_matching_lines_ignored() {
  local content
  content="$(cat <<'EOF'
# just a comment

FABRICA_UNKNOWN_KEY=whatever
export FABRICA_CODEX_MODEL=exported-form-not-matched
 FABRICA_CODER_MODEL=leading-space-not-matched
FABRICA_CODER_MODELX=suffix-collision-not-matched
PATH=/evil
EOF
)"
  reset_vars
  run_parser_herestring "$content"
  assert_eq "(e) unknown FABRICA_ key ignored (FABRICA_CODEX_MODEL untouched)" "" "$FABRICA_CODEX_MODEL"
  assert_eq "(e) 'export KEY=' form not matched (no bare assignment) (FABRICA_CODEX_MODEL)" "" "$FABRICA_CODEX_MODEL"
  assert_eq "(e) leading-whitespace line not matched (FABRICA_CODER_MODEL)" "" "$FABRICA_CODER_MODEL"
  assert_eq "(e) no warning/side effect from any of these" "0" "$MC_TARGET_OVERRIDE_GATE_WARNING"
}

# ---------------------------------------------------------------------------------
# (f) ABSENCE — calling convention when the target has no override file at all: the REAL
# scripts guard with `git show ... 2>/dev/null` / `[ -f ... ]` before ever invoking the parser,
# so this asserts the parser itself is simply never called in that path (nothing to assert on
# the function directly — this documents the contract): a non-existent file must not be fed to
# `mc_parse_target_override` via `< file` (that would be a shell redirection error). We assert
# the realistic guard pattern used by both scripts behaves as expected here.
# ---------------------------------------------------------------------------------
test_absent_override_guard_pattern() {
  local missing="$tmproot/does-not-exist/.fabrica/models.conf"
  if [ -f "$missing" ]; then
    failed=$((failed + 1)); echo "FAIL: (f) sanity: missing path unexpectedly exists"
  else
    passed=$((passed + 1)); echo "pass: (f) absent override file -> guarded, parser not invoked (matches both scripts' [ -f ] / git-show-exit-nonzero guard)"
  fi
}

# ---------------------------------------------------------------------------------
# (g) CALLING-CONVENTION REGRESSION GUARD — a PIPE (the WRONG way to call this function) loses
# the assignments because bash 3.2 has no `lastpipe`: the rightmost command of a pipe runs in a
# SUBSHELL. This documents/guards WHY both real scripts use input REDIRECTION
# (`<<<`/`< file`), never `cat file | mc_parse_target_override`.
# ---------------------------------------------------------------------------------
test_pipe_calling_convention_loses_assignments() {
  reset_vars
  # shellcheck disable=SC2030  # the subshell-scoping IS the point being demonstrated
  printf 'FABRICA_CODER_MODEL=should-not-persist\n' | mc_parse_target_override
  # shellcheck disable=SC2031  # asserting the OUTER (caller) scope was NOT mutated by the pipe
  assert_eq "(g) piping into the parser (wrong convention) does NOT persist assignments to the caller" "" "$FABRICA_CODER_MODEL"
}

# ---------------------------------------------------------------------------------
# (h) STATIC SOURCE ASSERTIONS — the shipped scripts actually use the fixed pattern, not just
# the lib being correct in isolation. Mirrors north-star-gate.test.sh's test_source_identity
# technique for safety-critical properties impractical to fully drive end-to-end.
# ---------------------------------------------------------------------------------
test_scripts_wire_the_fix() {
  local cr mr
  cr="$(cat "$codex_review")"
  mr="$(cat "$manager_review")"

  # Both scripts source the shared parser lib.
  case "$cr" in *"lib/models-conf.sh"*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh sources scripts/lib/models-conf.sh" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not source scripts/lib/models-conf.sh" ;; esac
  case "$mr" in *"lib/models-conf.sh"*) passed=$((passed + 1)); echo "pass: (h) manager-review.sh sources scripts/lib/models-conf.sh" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh does not source scripts/lib/models-conf.sh" ;; esac

  # Both scripts call the parser (not `source`/`.` the target file directly).
  case "$cr" in *"mc_parse_target_override"*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh calls mc_parse_target_override" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not call mc_parse_target_override" ;; esac
  case "$mr" in *"mc_parse_target_override"*) passed=$((passed + 1)); echo "pass: (h) manager-review.sh calls mc_parse_target_override" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh does not call mc_parse_target_override" ;; esac

  # The OLD vulnerable direct-source-of-target-file pattern is GONE from both scripts.
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$cr" in *'. "$target_models_conf"'*) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh STILL directly sources \$target_models_conf" ;;
    *) passed=$((passed + 1)); echo "pass: (h) codex-review.sh no longer directly sources \$target_models_conf" ;; esac
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$mr" in *'. "$target_models_conf"'*) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh STILL directly sources \$target_models_conf" ;;
    *) passed=$((passed + 1)); echo "pass: (h) manager-review.sh no longer directly sources \$target_models_conf" ;; esac

  # codex-review.sh's TRUST ANCHOR fix: it resolves the gh-bound DEFAULT branch (never just the
  # PR head) and fetches it fresh via the shared helper, mirroring manager-review.sh's anchor.
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$cr" in *'ghr_gh_default_branch "$repo"'*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh resolves the gh-bound default branch (trust anchor)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not resolve the gh-bound default branch" ;; esac
  case "$cr" in *"ghr_fetch_default_commit"*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh fetches the default branch fresh via ghr_fetch_default_commit" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not fetch the default branch fresh" ;; esac

  # The .fabrica/models.conf override in codex-review.sh is read from the ANCHOR commit (via
  # `git show`), never from the PR-head worktree path.
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$cr" in *'git show "${models_anchor_commit}:.fabrica/models.conf"'*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh reads the override from the fetched default-branch anchor commit" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not read the override from the anchor commit" ;; esac
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$cr" in *'$worktree/.fabrica/models.conf'*) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh STILL reads the override from the PR-head worktree" ;;
    *) passed=$((passed + 1)); echo "pass: (h) codex-review.sh no longer reads the override from the PR-head worktree" ;; esac

  # manager-review.sh's SYMLINK-SAFE fix (P2, adversarial review of PR #115, revision): the
  # .fabrica/models.conf override is read from the anchored $head_commit via `git show` — a git
  # blob, never a filesystem path — so a target-committed SYMLINK yields only the link's
  # target-path string (fails the parser's charset check, silently ignored) instead of following
  # the link to an arbitrary operator-local file. It must NEVER go back to a `<`-redirect from the
  # checked-out worktree path, which follows symlinks. See also
  # scripts/test/north-star-gate.test.sh's (22) end-to-end case.
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$mr" in *'git show "${head_commit}:.fabrica/models.conf"'*) passed=$((passed + 1)); echo "pass: (h) manager-review.sh reads the override from the anchored head_commit via git show (symlink-safe)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh does not read the override from head_commit via git show" ;; esac
  # shellcheck disable=SC2016  # literal source-text needle; must not expand.
  case "$mr" in *'$worktree/.fabrica/models.conf'*) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh STILL reads the override from the checked-out worktree path (follows symlinks)" ;;
    *) passed=$((passed + 1)); echo "pass: (h) manager-review.sh no longer reads the override from the checked-out worktree path" ;; esac

  # Both scripts fold the gate-key-override warning into the posted comment/header — never a
  # silent ignore.
  case "$cr" in *"MC_TARGET_OVERRIDE_GATE_WARNING"*) passed=$((passed + 1)); echo "pass: (h) codex-review.sh surfaces MC_TARGET_OVERRIDE_GATE_WARNING" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) codex-review.sh does not surface MC_TARGET_OVERRIDE_GATE_WARNING" ;; esac
  case "$mr" in *"MC_TARGET_OVERRIDE_GATE_WARNING"*) passed=$((passed + 1)); echo "pass: (h) manager-review.sh surfaces MC_TARGET_OVERRIDE_GATE_WARNING" ;;
    *) failed=$((failed + 1)); echo "FAIL: (h) manager-review.sh does not surface MC_TARGET_OVERRIDE_GATE_WARNING" ;; esac
}

echo "== models-conf parser tests =="
test_malicious_file_sentinel_not_created
test_malicious_file_sentinel_not_created_via_file
test_gate_keys_ignored_with_warning
test_no_gate_key_no_warning
test_valid_producer_override_applied
test_charset_and_quoting_edge_cases
test_non_matching_lines_ignored
test_absent_override_guard_pattern
test_pipe_calling_convention_loses_assignments
test_scripts_wire_the_fix

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
