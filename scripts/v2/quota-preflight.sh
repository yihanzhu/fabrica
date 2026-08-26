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
# Only workflows where a run ALWAYS means the agent actually executed are
# counted: the stage workflows (push-to-main triggered — only operator merges
# cause them) and the dispatch-gated probe. review-on-pr and fix-on-review are
# deliberately NOT counted: their triggers (any PR, any comment) create runs
# whose job is skipped — fork PRs, ordinary comments — so counting them would
# let cost-free noise, or deliberate comment spam, trip the brake and block
# real work (Codex cloud review of #131). Their genuine volume is bounded
# elsewhere: every real review/fix cycle starts from a counted stage run or an
# operator push, and the round labels cap the fix loop per PR.
#
#   FABRICA_RUN_BACKSTOP    runs allowed per window (default 20)
#   FABRICA_RUN_WINDOW_H    window in hours (default 5)
#   FABRICA_LANE_WORKFLOWS  comma-separated workflow files to count
#
# Needs gh with access to the current repo.

backstop="${FABRICA_RUN_BACKSTOP:-20}"
window_h="${FABRICA_RUN_WINDOW_H:-5}"
lane="${FABRICA_LANE_WORKFLOWS:-spec-on-intent.yml,implement-on-spec.yml,plumbing-test.yml}"

# Cutoff timestamp: GNU date (CI runners) first, BSD date (macOS) as fallback.
cutoff="$(date -u -d "${window_h} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -v "-${window_h}H" '+%Y-%m-%dT%H:%M:%SZ')"

# If gh can't list runs at all, fail loudly — a brake that silently reads
# zero forever is worse than a failed step.
if ! gh run list --limit 1 --json databaseId >/dev/null; then
  echo "quota-preflight: gh cannot list runs — refusing to guess." >&2
  exit 1
fi

errf="$(mktemp)"
trap 'rm -f "$errf"' EXIT

count=0
old_ifs="$IFS"
IFS=','
for wf in $lane; do
  IFS="$old_ifs"
  # A workflow that doesn't exist yet (pre-Stack-B) counts as zero. Any OTHER
  # failure — outage, rate limit — must fail loudly: converting errors to zero
  # would make the brake fail open during a cascade (Codex review of #131).
  if n="$(gh run list --workflow "$wf" --created ">=${cutoff}" --limit 100 \
        --json databaseId --jq 'length' 2>"$errf")"; then
    case "$n" in
      ''|*[!0-9]*)
        echo "quota-preflight: unexpected count for ${wf}: '${n}' — refusing to guess." >&2
        exit 1
        ;;
    esac
    count=$((count + n))
  else
    msg="$(cat "$errf")"
    case "$msg" in
      *"could not find any workflows"*|*"no such workflow"*|*"HTTP 404"*)
        : # not created yet — expected until Stack B lands
        ;;
      *)
        echo "quota-preflight: counting ${wf} failed: ${msg}" >&2
        echo "Refusing to guess — a brake that undercounts fails open." >&2
        exit 1
        ;;
    esac
  fi
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
