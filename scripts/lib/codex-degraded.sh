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
# DIAGNOSTIC STREAMS ONLY (P2 fix, adversarial review of PR #119) — the two file arguments below
# MUST be codex's DIAGNOSTIC channels: its captured STDOUT TRANSCRIPT (codex's own process
# stdout — NOT the `-o` review-answer file) and its STDERR. Signals are matched ONLY against
# those two streams. The `-o` answer file (the review verdict / PROCEED-REFINE-DROP body that
# gets posted to the PR/issue) must NEVER be passed in here: it is untrusted, PR-influenced
# content, and a genuinely clean review that merely QUOTES a trigger phrase in prose (e.g.
# discussing this very hardening, or reviewing a diff that mentions "code-mode host") would
# otherwise self-flag DEGRADED — a false positive the root cause of an earlier version of this
# detector. The real spawn-failure signal from the 2026-07-11 incident is a diagnostic LOG line
# (e.g. `ERROR codex_core::tools::router: ... failed to spawn code-mode host`) — codex emits that
# on its stdout transcript / stderr, never inside its `-o` final-answer capture, so restricting
# detection to the diagnostic streams loses no real-incident coverage while closing the
# false-trigger hole.
#
# DELIBERATELY NARROW SCOPE — the REQUIRED robust core only:
#   1. codex exiting non-zero.
#   2. a known code-mode/host spawn-failure string anywhere in codex's captured stdout
#      TRANSCRIPT or stderr.
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
# error) — callers may pass a stderr-capture path that is legitimately empty. Callers MUST pass
# only diagnostic-stream files here (stdout transcript / stderr) — never the `-o` answer file.
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

# cd_degraded_reason <codex_rc> <stdout_transcript_file> [<stderr_file>]
# The single decision both gates call. Prints a short human-readable reason and returns 0 if this
# codex run must be treated as DEGRADED (failed to run a genuine review/debate) rather than a
# pass; returns 1 (prints nothing) for a genuine run — exit 0 AND no known spawn-failure signal in
# either DIAGNOSTIC stream — including a genuinely fast, genuinely clean review, which MUST still
# PASS (do not over-trigger).
#
# <stdout_transcript_file> and <stderr_file> MUST be codex's diagnostic channels (its own process
# stdout/stderr), captured by the caller BEFORE this is invoked — NEVER the `-o` review-answer
# file. Passing the `-o` file here would re-introduce the false-trigger bug this fix closes (a
# clean review whose answer body merely quotes a trigger phrase would wrongly degrade).
cd_degraded_reason() {
  local rc="$1" out="$2" err="${3:-}"
  if [ "$rc" -ne 0 ]; then
    printf 'codex exited non-zero (%s)' "$rc"
    return 0
  fi
  if cd_output_is_degraded "$out"; then
    printf 'a known code-mode/host spawn-failure signal was found in codex'\''s stdout transcript'
    return 0
  fi
  if cd_output_is_degraded "$err"; then
    printf 'a known code-mode/host spawn-failure signal was found in codex'\''s stderr'
    return 0
  fi
  return 1
}

# cd_sanitize_snippet <file> — print a BOUNDED, SANITIZED snippet of a diagnostic file (codex's
# captured stdout transcript or stderr), suitable for embedding in a posted DEGRADED comment.
#
# BOUNDED (P3 fix, #119) — a code-mode/host spawn-failure on stderr can carry unbounded
# operator-local filesystem paths / toolchain diagnostics; this caps the volume actually posted
# to the (potentially public/shared) PR or issue. Capped to the last cd_snippet_max_lines lines,
# further capped to cd_snippet_max_bytes total bytes (both overridable via env for tests).
#
# SANITIZED (P2 integrity fix, #119) — codex's diagnostic output is UNTRUSTED: it can be
# influenced by the PR under review (a prompt-injected diff, or an adversarial issue body for
# manager-review.sh), and a DEGRADED run's -o answer is untrustworthy precisely because codex may
# not have run a genuine review at all. scripts/merge-pr.sh's marker parser scans the WHOLE
# posted comment body, line-anchored (`^## Codex reviewer (cross-vendor, read-only)$` plus
# `^Reviewed-head: <40hex>$` / `^Reviewed-base: <40hex>$`), for ANY comment authored by the
# gh-authenticated operator — which the DEGRADED comment itself is, since the harness posts as
# the operator. Without sanitization, an injected line reproducing those exact markers in codex's
# diagnostic output would sail into the DEGRADED comment verbatim and could be read by
# merge-pr.sh as a genuine PASS, auto-merging unreviewed code. EVERY line here is therefore
# prefixed with "> " before embedding — which breaks the `^...$` line anchors those regexes
# require, so no line in the sanitized snippet can ever be mistaken for a real marker line,
# regardless of what content the untrusted stream carries. (This also neutralizes any not-yet-
# known marker-shaped line, not just the two documented ones.)
#
# A missing/empty file prints "(empty)".
cd_snippet_max_lines="${CD_SNIPPET_MAX_LINES:-40}"
cd_snippet_max_bytes="${CD_SNIPPET_MAX_BYTES:-4000}"
cd_sanitize_snippet() {
  local f="$1"
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -s "$f" ]; then
    echo "(empty)"
    return 0
  fi
  tail -n "$cd_snippet_max_lines" "$f" | head -c "$cd_snippet_max_bytes" | sed 's/^/> /'
}
