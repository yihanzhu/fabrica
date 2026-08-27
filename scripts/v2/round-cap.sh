#!/usr/bin/env bash
set -euo pipefail

# round-cap.sh — the review-loop brake.
#
# The fix loop is bounded by round-N labels on the PR (v1's counter, reused).
# No round label counts as round 0. The cap is 3. YSTACK_ROUND_CAP overrides
# it; the legacy FABRICA_ROUND_CAP still works, and YSTACK_ROUND_CAP wins when
# both are set.
#
#   round-cap.sh check <pr>   print "round=<n>" and "proceed=true|false"
#   round-cap.sh bump  <pr>   move the label up one round BEFORE the fix acts;
#                             at the cap: print "capped=true", exit 3, change
#                             nothing
#
# Needs gh with access to the current repo.

usage() { echo "usage: $0 check|bump <pr-number>" >&2; }

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi
mode="$1"
pr="$2"
cap="${YSTACK_ROUND_CAP:-${FABRICA_ROUND_CAP:-3}}" # legacy fallback

labels="$(gh pr view "$pr" --json labels --jq '.labels[].name')"

round=0
while IFS= read -r label; do
  case "$label" in
    round-*)
      n="${label#round-}"
      case "$n" in ''|*[!0-9]*) continue ;; esac
      n=$((10#$n)) # base-10: a zero-padded label like round-08 must not read as octal
      if [ "$n" -gt "$round" ]; then round="$n"; fi
      ;;
  esac
done <<< "$labels"

case "$mode" in
  check)
    echo "round=${round}"
    if [ "$round" -lt "$cap" ]; then
      echo "proceed=true"
    else
      echo "proceed=false"
    fi
    ;;
  bump)
    next=$((round + 1))
    if [ "$next" -gt "$cap" ]; then
      echo "capped=true"
      exit 3
    fi
    # Add the new label first, then drop the old one. If we crash in between,
    # the higher round wins — a crash can overcount, never undercount.
    # Concurrent bumps could undercount, but lane jobs are serialized by the
    # claude-quota concurrency group; this script assumes that holds.
    gh pr edit "$pr" --add-label "round-${next}" >/dev/null
    gh pr edit "$pr" --remove-label "round-${round}" >/dev/null 2>&1 || true
    echo "round=${next}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
