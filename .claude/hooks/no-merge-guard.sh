#!/bin/bash
# Fabrica constitution: no agent path to main.
# PreToolUse hook on Bash. Exit 2 blocks the action and returns the message
# to the agent; exit 0 permits (normal permission flow still applies).
# Deterministic layer under the fabrica-main-gate ruleset — defense in depth,
# and the only enforcement in clones where no ruleset exists.
#
# Deliberately NOT blocked: scripts/merge-pr.sh — the v1 in-session merge
# harness keeps its own safety checks (SHA pinning, required-checks gate,
# REVIEW_REQUIRED refusal). Raw merge commands are blocked; the harness or a
# human is the only merge path.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [ -z "$cmd" ]; then
  exit 0
fi

# Any push whose refspec targets main (origin main, HEAD:main, +sha:refs/heads/main).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  echo "Blocked by fabrica guard: no direct pushes to main. Push a branch and open a PR." >&2
  exit 2
fi

# Raw merge commands — merging is the human gate (or scripts/merge-pr.sh).
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  echo "Blocked by fabrica guard: agents never merge PRs. A human merges at the gate (or use scripts/merge-pr.sh in-session)." >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+api[[:space:]][^|;&]*pulls/[0-9]+/merge'; then
  echo "Blocked by fabrica guard: agents never merge PRs via the API. A human merges at the gate." >&2
  exit 2
fi

exit 0
