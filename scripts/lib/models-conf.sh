#!/usr/bin/env bash
# models-conf.sh — shared TARGET-COMMITTED models.conf PARSER (sourced, not executed).
#
# SECURITY FIX (adversarial review of #110, P1 finding on PR #115) — a target repo's committed
# models.conf override (`.ystack/models.conf`, or the legacy `.fabrica/models.conf`; see
# templates/.ystack/models.conf) is DATA a target chose to commit, never code the reviewer
# harness should execute. scripts/codex-review.sh and scripts/manager-review.sh used to
# `source`/`.` that file directly into the operator's non-sandboxed harness shell. Two problems
# with that:
#   1. A malicious target could put arbitrary shell in the file — `source` runs it with the
#      operator's own `gh`/`codex` credentials: exfiltrate them, weaponize the `rm -rf "$worktree"`
#      cleanup trap, redefine traps, mutate PATH, etc.
#   2. Even WITHOUT any shell injection, a target could simply commit a low review effort
#      to downgrade its OWN review gate — the only prior validation was "non-empty" (no
#      allowlist/floor) — defeating the "gates are always max capability, never class-routed
#      down" design this config exists to enforce.
#
# mc_parse_target_override (below) reads the override as DATA: a strict per-line parser, never
# `eval`, `source`, or any other shell evaluation of the target's content. Only a line matching
# EXACTLY `YSTACK_<allowedkey>=<value>` — or the legacy `FABRICA_<allowedkey>=<value>` — is
# recognized (value optionally wrapped in ONE matching layer of `"`/`'` quotes, and — after
# unquoting — restricted to the charset [A-Za-z0-9._-]). Every other line (comments, blank
# lines, malformed assignments, anything containing shell metacharacters / command substitution
# / a quote mismatch) is silently IGNORED, never executed — so even a bug in this parser cannot
# itself achieve code execution the way `source` unconditionally could (the charset check is
# defense in depth; the actual guarantee is "this content is never eval'd/sourced").
#
# TWO KEY FAMILIES, ONE OUTPUT. Targets that renamed already use `YSTACK_*` keys; targets still
# on the legacy name may use `FABRICA_*` keys. The parser accepts BOTH, and always writes the
# result into the canonical `YSTACK_*` variables the callers read. When BOTH families set the
# same setting in one file, the `YSTACK_*` line wins — no matter which line comes first.
#
# GATE KEYS ARE NOT TARGET-OVERRIDABLE. A target's override may set only the PRODUCER/MODEL keys
# — YSTACK_CODER_MODEL, YSTACK_HANDS_MODEL, YSTACK_CODEX_MODEL (or their legacy FABRICA_* spellings).
# If the file contains a review-effort or debate-effort key (either family), that line is
# recognized by the parser but its value is NEVER applied: a target must never lower (or
# otherwise change) its own review / manager-debate gate. Instead a warning is printed to stderr
# AND `MC_TARGET_OVERRIDE_GATE_WARNING` is set to `1`, so the caller can fold a visible "target
# override tried to set gate effort — ignored" line into the posted PR/issue comment header
# (never a silent ignore).
#
# Calling convention — INPUT REDIRECTION, never a pipe:
#   MC_TARGET_OVERRIDE_GATE_WARNING=0
#   mc_parse_target_override < "$file"          # reading a checked-out file, or
#   mc_parse_target_override <<<"$content"      # reading content already captured (e.g. via
#                                                # `git show <commit>:path`) in a shell variable
# A pipe's rightmost command runs in a SUBSHELL under bash 3.2 (no `lastpipe`), which would
# silently discard the YSTACK_* assignments this function makes — so callers must use
# redirection, not `cat file | mc_parse_target_override` / `printf '%s' "$x" | mc_parse_target_override`.

mc_parse_target_override() {
  local line
  local key
  local value
  # Per-setting flags: set to 1 once a YSTACK_* line has applied, so a later (or earlier)
  # legacy FABRICA_* line for the SAME setting can never override it — YSTACK_* wins when both appear.
  local mc_ystack_won_coder=0
  local mc_ystack_won_hands=0
  local mc_ystack_won_codex=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      YSTACK_CODER_MODEL=*|YSTACK_HANDS_MODEL=*|YSTACK_CODEX_MODEL=*|YSTACK_REVIEW_EFFORT=*|YSTACK_DEBATE_EFFORT=*) ;;
      FABRICA_CODER_MODEL=*|FABRICA_HANDS_MODEL=*|FABRICA_CODEX_MODEL=*|FABRICA_REVIEW_EFFORT=*|FABRICA_DEBATE_EFFORT=*) ;; # legacy fallback
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    # Strip ONE layer of matching quotes (both ends the SAME quote character). A mismatched or
    # single-sided quote is left as-is and will be caught (rejected) by the charset check below.
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    # Tight charset AFTER unquoting — reject (ignore the WHOLE line) if any character falls
    # outside it. This is a glob bracket-negation check ([!...]) in a `case`, not a regex — no
    # eval involved, and it also rejects backticks/$()/;/quotes left over from a malformed or
    # malicious value.
    case "$value" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    # These assignments are consumed by the CALLER after mc_parse_target_override returns (the
    # caller's own shell, per the input-redirection calling convention above — never a subshell),
    # not within this function/file itself, so shellcheck's unused-variable check does not see
    # the use site; each is annotated `disable=SC2034` with that reason. A directive must precede
    # a complete command (not a bare case pattern), so each disable sits on its own line directly
    # above the assignment, inside a multi-line case branch.
    case "$key" in
      YSTACK_REVIEW_EFFORT|YSTACK_DEBATE_EFFORT|FABRICA_REVIEW_EFFORT|FABRICA_DEBATE_EFFORT) # legacy fallback
        echo "warning: target override tried to set gate effort (${key}) — ignored (a target" >&2
        echo "         repo may never lower or change its own review/manager-debate gate)" >&2
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        MC_TARGET_OVERRIDE_GATE_WARNING=1
        ;;
      YSTACK_CODER_MODEL)
        mc_ystack_won_coder=1
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        YSTACK_CODER_MODEL="$value"
        ;;
      FABRICA_CODER_MODEL) # legacy fallback
        if [ "$mc_ystack_won_coder" -eq 0 ]; then
          # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
          YSTACK_CODER_MODEL="$value"
        fi
        ;;
      YSTACK_HANDS_MODEL)
        mc_ystack_won_hands=1
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        YSTACK_HANDS_MODEL="$value"
        ;;
      FABRICA_HANDS_MODEL) # legacy fallback
        if [ "$mc_ystack_won_hands" -eq 0 ]; then
          # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
          YSTACK_HANDS_MODEL="$value"
        fi
        ;;
      YSTACK_CODEX_MODEL)
        mc_ystack_won_codex=1
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        YSTACK_CODEX_MODEL="$value"
        ;;
      FABRICA_CODEX_MODEL) # legacy fallback
        if [ "$mc_ystack_won_codex" -eq 0 ]; then
          # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
          YSTACK_CODEX_MODEL="$value"
        fi
        ;;
    esac
  done
}
