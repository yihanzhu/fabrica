#!/usr/bin/env bash
set -euo pipefail

# setup-target-repo.sh — bootstrap a target repo's loop labels.
#
# Creates the labels the review loop uses as its state (each coder spawn is stateless).
# Idempotent: re-running on a repo that already has the labels updates them instead of
# failing. Branch protection, CI, the /faber command, and the Codex CLI reviewer are NOT
# scriptable here — see the manual follow-ups printed at the end and
# templates/repo-setup.md.

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
  "ready|0e8a16|Record of your approval; Faber's cue to spawn the coder"
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
  3. Install the /faber command: run scripts/install.sh from your fabrica clone.
  4. Connect the Codex CLI (signed in) so Faber can run scripts/codex-review.sh on this repo.
EOF
