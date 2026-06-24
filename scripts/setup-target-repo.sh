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

# Preflight — fail honestly and early, BEFORE creating any label, so a misconfigured
# run surfaces an actionable pointer instead of an opaque mid-loop gh error and a
# half-bootstrapped repo (see QUICKSTART.md > Prerequisites).
if ! command -v gh >/dev/null 2>&1; then
  echo "error: missing required command: gh" >&2
  echo "       install the GitHub CLI and authenticate, then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated" >&2
  echo "       run 'gh auth login', then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites" >&2
  exit 1
fi

# Validate the arg is <owner>/<repo> shape: two non-empty segments, no slashes or
# whitespace within either, separated by a single '/'. Catches a bare repo name, a
# full URL, or a stray space before any side-effect.
if ! [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
  echo "error: expected <owner>/<repo>, got: $repo" >&2
  usage
  exit 1
fi

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
  # Try to create; capture stderr so we can tell the genuine "already exists" case
  # (idempotency: fall through to edit) from any OTHER failure (auth, wrong repo,
  # network, permission) — which must NOT be swallowed into edit. `set -e` would abort
  # the loop on a bare failed create, so guard with `if !` and inspect the captured err.
  if err="$(gh label create "$name" --repo "$repo" --color "$color" --description "$desc" 2>&1 >/dev/null)"; then
    echo "  created: $name"
  elif printf '%s' "$err" | grep -qi 'already exists'; then
    # Genuine already-exists — update in place to preserve documented idempotency.
    gh label edit "$name" --repo "$repo" --color "$color" --description "$desc" >/dev/null
    echo "  updated: $name"
  else
    # Any other failure: surface the real cause and stop, rather than masking it as an
    # edit and leaving a half-bootstrapped repo.
    echo "error: failed to create label '$name' on ${repo}:" >&2
    printf '%s\n' "$err" >&2
    exit 1
  fi
done

cat <<EOF

Labels done. Manual follow-ups this script can't do (see templates/repo-setup.md):
  1. Branch protection on main — UI-only, and unavailable on free private repos.
  2. CI workflow — a PR check that runs tests + lint (the hard merge gate).
  3. Install the /faber command: run scripts/install.sh from your fabrica clone.
  4. Connect the Codex CLI (signed in) so Faber can run scripts/codex-review.sh on this repo.
EOF
