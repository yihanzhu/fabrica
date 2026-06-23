#!/usr/bin/env bash
set -euo pipefail

# setup-target-repo.sh — bootstrap a target repo's loop labels.
#
# Creates the labels the stateless review loop uses as its state. Idempotent:
# re-running on a repo that already has the labels updates them instead of failing.
# Branch protection, CI, and the Codex reviewer are NOT scriptable here — see the
# manual follow-ups printed at the end and templates/repo-setup.md.
#
# Modes: the team runs in ONE of two mutually-exclusive end-to-end modes (pick one;
# don't mix). IN-SESSION mode (default) needs no coder routines beyond `/faber` + the
# Codex CLI — Faber drives launch, review, and revisions in-session. AUTONOMOUS mode
# (optional) additionally needs the Claude GitHub App + the coder routines. These
# labels are the loop's shared state in BOTH modes. The daily-brief routine
# (routines/brief.md) is independent of the mode — recommended in both for resurfacing.

usage() {
  echo "usage: $0 <owner>/<repo>" >&2
  echo "  bootstraps the loop labels (ready, round-0..3, needs-human) on the target repo" >&2
}

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

repo="$1"

# Each entry: name|color|description (color is a 6-hex code, no leading '#').
labels=(
  "ready|0e8a16|The record of your approval (Faber applies it after you approve)"
  "round-0|c5def5|Review-loop counter: initial PR"
  "round-1|7fb3e0|Review-loop counter: revision 1"
  "round-2|4a90d9|Review-loop counter: revision 2"
  "round-3|1f6fc0|Review-loop counter: revision 3 (cap)"
  "needs-human|d93f0b|Escalation: round cap hit, ambiguous spec, oversized PR, or failure"
)

echo "Bootstrapping loop labels on ${repo}..."
for entry in "${labels[@]}"; do
  IFS='|' read -r name color desc <<<"$entry"
  if gh label create "$name" --repo "$repo" --color "$color" --description "$desc" 2>/dev/null; then
    echo "  created: $name"
  else
    gh label edit "$name" --repo "$repo" --color "$color" --description "$desc" >/dev/null
    echo "  updated: $name"
  fi
done

cat <<EOF

Labels done. Manual follow-ups this script can't do (see templates/repo-setup.md):
  1. Branch protection on main — UI-only, and unavailable on free private repos.
  2. CI workflow — a PR check that runs tests + lint (the hard merge gate).
  3. Codex reviewer (comments-only) — install/sign in to the Codex CLI for IN-SESSION
     mode (Faber runs scripts/codex-review.sh), OR connect the Codex GitHub integration
     for AUTONOMOUS mode. Pick the one that matches your mode.

Pick ONE end-to-end mode (don't mix):
  - IN-SESSION (default): no coder routines to wire. Faber drives launch, review, and
    revisions in-session via /faber + the Codex CLI. No Claude GitHub App, no coder
    routines.
  - AUTONOMOUS (optional): also install/connect the Claude GitHub App and wire the
    coder + coder-revision routines (and use the Codex GitHub integration as reviewer).
    Faber does not spawn in this mode.

Independent of the mode: the daily-brief routine (routines/brief.md) is recommended in
BOTH modes for resurfacing — add this repo to that scheduled scan.
EOF
