#!/bin/bash
# ystack constitution: no agent path to main.
# PreToolUse hook on Bash. Exit 2 blocks the action and returns the message
# to the agent; exit 0 permits (normal permission flow still applies).
# Deterministic layer under the ystack-main-gate ruleset — defense in depth,
# and the only enforcement in clones where no ruleset exists.
#
# The merge helper is blocked too. It was exempt while the manager could
# merge in-session; that permission is retired, so the exemption became a
# bypass — in a clone with no ruleset, or under an account that can merge,
# an agent could have merged through it. scripts/merge-pr.sh is now the
# operator's own tool, run by a human, never by an agent.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [ -z "$cmd" ]; then
  exit 0
fi

# Any push whose refspec targets main (origin main, HEAD:main, +sha:refs/heads/main).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  echo "Blocked by ystack guard: no direct pushes to main. Push a branch and open a PR." >&2
  exit 2
fi

# Every merge path — merging is the operator's, always.
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  echo "Blocked by ystack guard: agents never merge PRs. The operator merges at the gate." >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq 'merge-pr\.sh'; then
  echo "Blocked by ystack guard: merge-pr.sh is the operator's own tool. Apply merge-ready and hand the PR over." >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+api[[:space:]][^|;&]*pulls/[0-9]+/merge'; then
  echo "Blocked by ystack guard: agents never merge PRs via the API. A human merges at the gate." >&2
  exit 2
fi

exit 0
