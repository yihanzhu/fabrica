#!/usr/bin/env bash
set -euo pipefail

# quota-preflight.sh — runaway brake, not a work limiter.
#
# Every normal lane run starts from an operator merge, so real work is already
# paced by the operator (their decision, 2026-08-26). This only catches
# abnormal volume — a cascade bug burning the subscription window. Over the
# backstop it exits 1, loudly. It never blocks a normal queue.
#
#   FABRICA_RUN_BACKSTOP   runs allowed per window (default 20)
#   FABRICA_RUN_WINDOW_H   window in hours (default 5)
#
# Needs gh with access to the current repo.

backstop="${FABRICA_RUN_BACKSTOP:-20}"
window_h="${FABRICA_RUN_WINDOW_H:-5}"

# Cutoff timestamp: GNU date (CI runners) first, BSD date (macOS) as fallback.
cutoff="$(date -u -d "${window_h} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -v "-${window_h}H" '+%Y-%m-%dT%H:%M:%SZ')"

# Count recent runs of the lane's workflows (names declared in the v2 plan).
count="$(gh run list --created ">=${cutoff}" --limit 100 --json name --jq '
  [.[] | select(
    .name == "Spec on intent" or
    .name == "Implement on spec" or
    .name == "Review PR" or
    .name == "Fix on review" or
    .name == "Plumbing test"
  )] | length')"

echo "runs=${count}"
if [ "$count" -ge "$backstop" ]; then
  {
    echo "quota-preflight: ${count} agent runs in the last ${window_h}h (backstop: ${backstop})."
    echo "That volume means a bug, not work. Stop and investigate before the lane continues."
  } >&2
  exit 1
fi
exit 0
