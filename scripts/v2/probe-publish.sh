#!/usr/bin/env bash
set -euo pipefail

# probe-publish.sh — the plumbing probe's only write path.
#
# The probe asks one question: can the agent, under the app token, publish a
# branch and open a PR (and do those events wake other workflows)? The agent
# needs a real write to answer it — but it does not need freedom. So every
# write lives here, behind fixed rules:
#   - the branch name must be exactly plumbing-probe-<run_id>-<attempt>
#   - only probe.txt is staged, ever
#   - the push targets that branch and no other ref
# The agent's allowlist carries this script and nothing else, so a model that
# wanders off the prompt still cannot touch another branch, tag, or file.
#
#   probe-publish.sh <run_id> <attempt>

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <run_id> <attempt>" >&2
  exit 1
fi

run_id="$1"
attempt="$2"
case "$run_id" in ''|*[!0-9]*) echo "error: run_id must be digits" >&2; exit 1 ;; esac
case "$attempt" in ''|*[!0-9]*) echo "error: attempt must be digits" >&2; exit 1 ;; esac

branch="plumbing-probe-${run_id}-${attempt}"

printf 'plumbing probe run %s attempt %s\n' "$run_id" "$attempt" > probe.txt

git checkout -b "$branch"
git add probe.txt
git commit -m "plumbing probe ${run_id} attempt ${attempt}"
git push -u origin "refs/heads/${branch}:refs/heads/${branch}"
gh pr create \
  --head "$branch" \
  --title "plumbing probe ${run_id}-${attempt} - close without merging" \
  --body "Probe artifact: proves the agent can publish a branch and open a PR. Close without merging."

echo "probe-publish: published ${branch}"
