#!/usr/bin/env bash
# codex-degraded.sh — shared DEGRADED-Codex-run detector (sourced, not executed; the
# `#!/usr/bin/env bash` line is only so shellcheck picks the right dialect).
#
# Real incident (2026-07-11, issue #117): `codex-code-mode-host` failed to spawn (the helper was
# missing from a Homebrew codex install). `codex exec review` still "completed" — exit 0, in
# ~8-14s, at confidence ~0.05, with a generic "no actionable findings" message — having done ZERO
# diff inspection. codex-review.sh posted that as a normal clean review; under the standing
# auto-merge rail, a fake "clean" would auto-merge unreviewed code into the control plane. A gate
# that fails silently-open is the worst possible failure mode.
#
# Both scripts/codex-review.sh (PR review) and scripts/manager-review.sh (issue debate) must
# answer the SAME question — "did this codex run actually happen, or did it fail to run a
# genuine review/debate?" — off the SAME signals, so they can't diverge on what counts as
# degraded. This lib factors that ONE decision into ONE place.
#
# DELIBERATELY NARROW SCOPE — the REQUIRED robust core only:
#   1. codex exiting non-zero.
#   2. a known code-mode/host spawn-failure string anywhere in codex's captured stdout (the `-o`
#      file) or stderr.
# No confidence/duration heuristics are layered on top. codex's `-o` capture is its clean FINAL
# message only — there is no reliably-exposed confidence/duration field to parse — so gating on
# one would risk false-triggering a genuinely fast, genuinely clean review of a small diff (the
# spec's explicit over-triggering concern). If that signal becomes reliably available later, add
# it as an ADDITIONAL check here (one place), not in either caller.

# cd_degraded_pattern — case-insensitive extended-regex alternation of known code-mode/host
# spawn-failure signals (#117). Deliberately over-inclusive on wording (e.g. both "code-mode
# host" and "code-mode-host") since the exact phrasing of a toolchain error is not a stable
# contract — a resilient match beats a brittle exact string.
cd_degraded_pattern='failed to spawn code-mode host|code-mode host|code-mode-host|repository inspection tool failed|execution environment failed to start|failed to start its command host'

# cd_output_is_degraded <file> [<file2> ...]
# Returns 0 (a signal was found) if ANY given file contains a case-insensitive match for
# cd_degraded_pattern; 1 otherwise. A missing or empty path is simply "no signal there" (not an
# error) — callers may pass a stderr-capture path that is legitimately empty.
cd_output_is_degraded() {
  local f
  for f in "$@"; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then
      continue
    fi
    if grep -qiE -- "$cd_degraded_pattern" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# cd_degraded_reason <codex_rc> <output_file> [<stderr_file>]
# The single decision both gates call. Prints a short human-readable reason and returns 0 if this
# codex run must be treated as DEGRADED (failed to run a genuine review/debate) rather than a
# pass; returns 1 (prints nothing) for a genuine run — exit 0 AND no known spawn-failure signal in
# either captured stream — including a genuinely fast, genuinely clean review, which MUST still
# PASS (do not over-trigger).
cd_degraded_reason() {
  local rc="$1" out="$2" err="${3:-}"
  if [ "$rc" -ne 0 ]; then
    printf 'codex exited non-zero (%s)' "$rc"
    return 0
  fi
  if cd_output_is_degraded "$out" "$err"; then
    printf 'codex output/stderr matched a known code-mode/host spawn-failure signal'
    return 0
  fi
  return 1
}
