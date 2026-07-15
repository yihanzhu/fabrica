#!/usr/bin/env bash
# models-conf.sh — shared TARGET-COMMITTED models.conf PARSER (sourced, not executed).
#
# SECURITY FIX (adversarial review of #110, P1 finding on PR #115) — a target repo's committed
# `.fabrica/models.conf` (see templates/.fabrica/models.conf) is DATA a target chose to commit,
# never code the reviewer harness should execute. scripts/codex-review.sh and
# scripts/manager-review.sh used to `source`/`.` that file directly into the operator's
# non-sandboxed harness shell. Two problems with that:
#   1. A malicious target could put arbitrary shell in the file — `source` runs it with the
#      operator's own `gh`/`codex` credentials: exfiltrate them, weaponize the `rm -rf "$worktree"`
#      cleanup trap, redefine traps, mutate PATH, etc.
#   2. Even WITHOUT any shell injection, a target could simply commit `FABRICA_REVIEW_EFFORT=low`
#      to downgrade its OWN review gate — the only prior validation was "non-empty" (no
#      allowlist/floor) — defeating the "gates are always max capability, never class-routed
#      down" design this config exists to enforce.
#
# mc_parse_target_override (below) reads the override as DATA: a strict per-line parser, never
# `eval`, `source`, or any other shell evaluation of the target's content. Only a line matching
# EXACTLY `FABRICA_<allowedkey>=<value>` is recognized (value optionally wrapped in ONE matching
# layer of `"`/`'` quotes, and — after unquoting — restricted to the charset
# [A-Za-z0-9._-]). Every other line (comments, blank lines, malformed assignments, anything
# containing shell metacharacters / command substitution / a quote mismatch) is silently
# IGNORED, never executed — so even a bug in this parser cannot itself achieve code execution the
# way `source` unconditionally could (the charset check is defense in depth; the actual guarantee
# is "this content is never eval'd/sourced").
#
# GATE KEYS ARE NOT TARGET-OVERRIDABLE. A target's override may set only the PRODUCER/MODEL keys
# — FABRICA_CODER_MODEL, FABRICA_HANDS_MODEL, FABRICA_CODEX_MODEL. If the file contains
# FABRICA_REVIEW_EFFORT or FABRICA_DEBATE_EFFORT, that line is recognized by the parser but its
# value is NEVER applied: a target must never lower (or otherwise change) its own review /
# manager-debate gate. Instead a warning is printed to stderr AND
# `MC_TARGET_OVERRIDE_GATE_WARNING` is set to `1`, so the caller can fold a visible "target
# override attempted to set gate effort — ignored" line into the posted PR/issue comment header
# (never a silent ignore).
#
# Calling convention — INPUT REDIRECTION, never a pipe:
#   MC_TARGET_OVERRIDE_GATE_WARNING=0
#   mc_parse_target_override < "$file"          # reading a checked-out file, or
#   mc_parse_target_override <<<"$content"      # reading content already captured (e.g. via
#                                                # `git show <commit>:path`) in a shell variable
# A pipe's rightmost command runs in a SUBSHELL under bash 3.2 (no `lastpipe`), which would
# silently discard the FABRICA_* assignments this function makes — so callers must use
# redirection, not `cat file | mc_parse_target_override` / `printf '%s' "$x" | mc_parse_target_override`.

mc_parse_target_override() {
  local line
  local key
  local value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FABRICA_CODER_MODEL=*|FABRICA_HANDS_MODEL=*|FABRICA_CODEX_MODEL=*|FABRICA_REVIEW_EFFORT=*|FABRICA_DEBATE_EFFORT=*) ;;
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
      FABRICA_REVIEW_EFFORT|FABRICA_DEBATE_EFFORT)
        echo "warning: target override attempted to set gate effort (${key}) — ignored (a target" >&2
        echo "         repo may never lower or change its own review/manager-debate gate)" >&2
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        MC_TARGET_OVERRIDE_GATE_WARNING=1
        ;;
      FABRICA_CODER_MODEL)
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        FABRICA_CODER_MODEL="$value"
        ;;
      FABRICA_HANDS_MODEL)
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        FABRICA_HANDS_MODEL="$value"
        ;;
      FABRICA_CODEX_MODEL)
        # shellcheck disable=SC2034  # consumed by the caller's shell after this function returns
        FABRICA_CODEX_MODEL="$value"
        ;;
    esac
  done
}
