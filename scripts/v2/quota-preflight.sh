#!/usr/bin/env bash
set -euo pipefail

# quota-preflight.sh — runaway brake, not a work limiter.
#
# Every normal lane run starts from an operator merge, so real work is already
# paced by the operator (their decision, 2026-08-26). This only catches
# abnormal volume — a cascade bug burning the subscription window. Over the
# backstop it exits 1, loudly. It never blocks a normal queue.
#
# Counting is per workflow FILE with a server-side filter, so companion runs
# (ci, tripwire) can never crowd lane runs out of the sample. Workflows that
# don't exist yet count as zero — expected until Stack B lands.
#
#   FABRICA_RUN_BACKSTOP    runs allowed per window (default 20)
#   FABRICA_RUN_WINDOW_H    window in hours (default 5)
#   FABRICA_LANE_WORKFLOWS  comma-separated workflow files to count
#
# Needs gh with access to the current repo.

backstop="${FABRICA_RUN_BACKSTOP:-20}"
window_h="${FABRICA_RUN_WINDOW_H:-5}"
lane="${FABRICA_LANE_WORKFLOWS:-spec-on-intent.yml,implement-on-spec.yml,review-on-pr.yml,fix-on-review.yml,plumbing-test.yml}"

# Cutoff timestamp: GNU date (CI runners) first, BSD date (macOS) as fallback.
cutoff="$(date -u -d "${window_h} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -v "-${window_h}H" '+%Y-%m-%dT%H:%M:%SZ')"

# If gh can't list runs at all, fail loudly — a brake that silently reads
# zero forever is worse than a failed step.
if ! gh run list --limit 1 --json databaseId >/dev/null; then
  echo "quota-preflight: gh cannot list runs — refusing to guess." >&2
  exit 1
fi

count=0
old_ifs="$IFS"
IFS=','
for wf in $lane; do
  IFS="$old_ifs"
  # A missing workflow (pre-Stack-B) is fine; anything else was caught above.
  n="$(gh run list --workflow "$wf" --created ">=${cutoff}" --limit 100 \
        --json databaseId --jq 'length' 2>/dev/null || echo 0)"
  count=$((count + n))
done
IFS="$old_ifs"

echo "runs=${count}"
if [ "$count" -ge "$backstop" ]; then
  {
    echo "quota-preflight: ${count} lane runs in the last ${window_h}h (backstop: ${backstop})."
    echo "That volume means a bug, not work. Stop and investigate before the lane continues."
  } >&2
  exit 1
fi
exit 0
