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
# STRUCTURED DIAGNOSTICS ONLY (P1 fix, substantive review of PR #119). `codex exec -o` writes the
# final answer to the requested file AND prints that same, PR/issue-influenced answer to normal
# stdout. Normal stderr is also the human progress renderer and can echo prompt text, inspected
# source, tool output, and the final answer. Neither unstructured stream is therefore a trustworthy
# "diagnostic-only" boundary. Both callers force `--json`: stdout becomes JSONL, and this helper
# treats top-level `error` / `turn.failed` as hard failures, and considers spawn-failure text only
# in CLI-authored error/MCP-error fields. Agent messages, reasoning, command output, and every
# other PR/issue-influenced payload are excluded by event TYPE before phrase matching. Raw stderr
# is still checked because runtime/tracing failures can be emitted there outside the JSON event
# stream; under `--json`, normal progress is JSONL on stdout rather than the human renderer on
# stderr.
#
# The `-o` answer file (the review verdict / PROCEED-REFINE-DROP body that gets posted to the
# PR/issue) must NEVER be passed here. A genuinely clean review that merely QUOTES a trigger
# phrase in prose must pass. The JSONL stream is validated against the event/item types supported
# by this gate, must end in `turn.completed` after an agent message, and must contain at least one
# successful structured command_execution as positive proof the repository command host ran.
# Malformed, incomplete, or unknown-schema output fails closed: a newly-added tool item (for
# example a future `dynamic_tool_call`) cannot silently bypass this detector before its trusted
# status fields have been reviewed and explicitly added here.
#
# DELIBERATELY NARROW SCOPE — the REQUIRED robust core only:
#   1. codex exiting non-zero.
#   2. invalid/incomplete JSONL or a `turn.failed` event.
#   3. an unrecoverable top-level `error`, or a known code-mode/host spawn-failure string in a
#      CLI-authored error item / failed-MCP error / raw stderr — never in agent/command content.
# No confidence/duration heuristics are layered on top. codex's `-o` capture is its clean FINAL
# message only — there is no reliably-exposed confidence/duration field to parse — so gating on
# one would risk false-triggering a genuinely fast, genuinely clean review of a small diff (the
# spec's explicit over-triggering concern). If that signal becomes reliably available later, add
# it as an ADDITIONAL check here (one place), not in either caller.

# cd_degraded_pattern — case-insensitive extended-regex alternation of known code-mode/host
# spawn-failure signals (#117). Every code-mode-host alternative requires explicit FAILURE
# CONTEXT. A bare component mention ("code-mode host" / "code-mode-host") is ordinary review
# prose and is not evidence that the host failed; matching it caused PR #119's own substantive
# review to self-report DEGRADED. Keep the wording resilient inside the failure context (spawn /
# startup / handshake, spacing or hyphen variants), but never fall back to a component-name-only
# match.
cd_degraded_pattern='failed to (spawn|start) (the )?(codex-)?code-mode[- ]host|code-mode[- ]host([[:space:]:-]+)((spawn|startup|handshake)[[:space:]]+)?(failed|failure|crashed|missing|not found|no such file|could not start|unable to start)|repository inspection tool failed|execution environment failed to start|failed to start its command host'

# cd_output_is_degraded <file> [<file2> ...]
# Returns 0 (a signal was found) if ANY given RAW DIAGNOSTIC file contains a case-insensitive
# match for cd_degraded_pattern; 1 otherwise. This is used only for raw stderr and unit fixtures,
# never for JSONL stdout or the `-o` answer.
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

# cd_jsonl_is_valid_completed <jsonl_file>
# Returns 0 only for a non-empty, valid JSONL stream whose EVERY event/item type belongs to the
# Codex exec JSONL schema this gate understands, with a completed agent message and FINAL
# `turn.completed`. `jq -s` validates every line/object in one parse. Unknown event/item types
# fail closed instead of being silently ignored — especially important for future tool-call types
# carrying their own structured failure fields. Callers preflight jq.
cd_jsonl_is_valid_completed() {
  local f="$1"
  [ -n "$f" ] && [ -s "$f" ] || return 1
  jq -s -e '
    length > 0
    and all(.[];
      type == "object"
      and (.type | type == "string")
      and (
        .type as $event_type
        | ([
            "thread.started", "turn.started", "turn.completed", "turn.failed",
            "item.started", "item.updated", "item.completed", "error"
          ] | index($event_type)) != null
      )
      and (
        if (.type | startswith("item.")) then
          (.item | type == "object")
          and (.item.type | type == "string")
          and (
            .item.type as $item_type
            | ([
                "agent_message", "reasoning", "command_execution", "file_change",
                "mcp_tool_call", "collab_tool_call", "web_search", "todo_list", "error"
              ] | index($item_type)) != null
          )
        else true end
      )
    )
    and any(.[]; .type == "item.completed" and .item.type == "agent_message")
    and .[-1].type == "turn.completed"
  ' "$f" >/dev/null 2>&1
}

# cd_jsonl_has_degraded_event <jsonl_file>
# Returns 0 for an unrecoverable top-level `error` / `turn.failed`, or when a known host-failure
# signal appears in a CLI-authored nonfatal error item or failed MCP error. Crucially, it never
# serializes agent messages, reasoning, command strings/output, MCP arguments/results, or other
# PR/issue-influenced payloads before phrase matching.
cd_jsonl_has_degraded_event() {
  local f="$1" failed_events
  [ -n "$f" ] && [ -f "$f" ] || return 1
  if jq -e -s 'any(.[]; .type == "error" or .type == "turn.failed")' "$f" >/dev/null 2>&1; then
    return 0
  fi
  failed_events="$(
    jq -r '
      if .type == "item.completed" and .item.type == "error" then
        .item.message // empty
      elif .type == "item.completed"
           and .item.type == "mcp_tool_call"
           and .item.status == "failed" then
        .item.error.message // empty
      else empty end
    ' "$f" 2>/dev/null
  )" || return 1
  printf '%s\n' "$failed_events" | grep -qiE -- "$cd_degraded_pattern" 2>/dev/null
}

# cd_jsonl_has_successful_command <jsonl_file>
# Positive proof that Codex's repository-inspection command host actually started and completed
# at least one command. The 2026-07-11 incident produced only a low-confidence agent answer plus
# turn.completed after the command host failed to spawn; no command_execution item existed. A
# final answer + completed turn are therefore insufficient evidence on their own. We trust only
# CLI-authored structured status/exit fields here — never the model-chosen command string or its
# output. Individual commands may legitimately fail while Codex recovers, so the requirement is
# at least ONE success, not zero failures.
cd_jsonl_has_successful_command() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  jq -e -s '
    any(.[];
      .type == "item.completed"
      and .item.type == "command_execution"
      and .item.status == "completed"
      and .item.exit_code == 0
    )
  ' "$f" >/dev/null 2>&1
}

# cd_degraded_reason <codex_rc> <stdout_jsonl_file> [<stderr_file>]
# The single decision both gates call. Prints a short human-readable reason and returns 0 if this
# codex run must be treated as DEGRADED (failed to run a genuine review/debate) rather than a
# pass; returns 1 (prints nothing) for a genuine run — exit 0, valid completed JSONL, and no known
# spawn-failure signal in a structured diagnostic event or raw stderr — including a genuinely
# fast, genuinely clean review, which MUST still PASS (do not over-trigger).
#
# <stdout_jsonl_file> MUST be stdout from a `codex exec --json` run. <stderr_file> must be raw
# stderr from that SAME `--json` run. NEVER pass the `-o` review-answer file.
cd_degraded_reason() {
  local rc="$1" out="$2" err="${3:-}"
  if [ "$rc" -ne 0 ]; then
    printf 'codex exited non-zero (%s)' "$rc"
    return 0
  fi
  if ! cd_jsonl_is_valid_completed "$out"; then
    printf 'codex produced invalid/incomplete/unsupported JSONL (no trustworthy completed review record)'
    return 0
  fi
  if cd_jsonl_has_degraded_event "$out"; then
    printf 'a fatal/failed event or known code-mode/host spawn-failure signal was found in codex'\''s structured events'
    return 0
  fi
  if cd_output_is_degraded "$err"; then
    printf 'a known code-mode/host spawn-failure signal was found in codex'\''s stderr'
    return 0
  fi
  if ! cd_jsonl_has_successful_command "$out"; then
    printf 'codex produced no successful command_execution evidence (repository inspection was not proven)'
    return 0
  fi
  return 1
}

# cd_sanitize_snippet <file> — print a BOUNDED, SANITIZED snippet of raw stderr, suitable for
# embedding in a posted DEGRADED comment. Callers deliberately NEVER pass the JSONL stream:
# even on a degraded run it contains agent messages, command strings/output, MCP arguments/results,
# and other repository/operator-local data that must not be published in a PR/issue comment.
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
