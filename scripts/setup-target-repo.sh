#!/usr/bin/env bash
set -euo pipefail

# setup-target-repo.sh — bootstrap a target repo's loop labels.
#
# Creates the labels the review loop uses as its state (each coder spawn is stateless).
# Idempotent: re-running on a repo that already has the labels updates them instead of
# failing. Branch protection, CI, the /yshifu command, and the Codex CLI reviewer are NOT
# scriptable here — see the manual follow-ups printed at the end and
# templates/repo-setup.md.
#
# This script is the CANONICAL source of truth for the loop labels. A normal run
# force-edits each existing label to the definitions below (name/color/description), so
# re-running RECONCILES any drift live labels have picked up — it normalizes the repo
# back to what this file says. Use --check (below) for a read-only way to detect that
# drift without mutating anything.
#
# Usage:
#   setup-target-repo.sh <owner>/<repo>           create/update labels (force-edit; reconciles drift)
#   setup-target-repo.sh --check <owner>/<repo>   read-only: report drift, mutate nothing
#
# --check reports, per label, one of: matches / differs (which of name/color/description)
# / missing. It exits 0 only if every label is present and matches, non-zero otherwise.
#
# Note: canonical label names are lowercase; a manually-created case-variant (e.g. 'Ready')
# is not auto-reconciled — delete it and recreate it lowercase by hand.

usage() {
  echo "usage: $0 [--check] <owner>/<repo>" >&2
  echo "  bootstraps the loop labels (debating, ready, round-0..3, needs-human, merge-ready, stale) on the target repo" >&2
  echo "  --check  read-only drift report: per label print matches/differs/missing; mutate nothing;" >&2
  echo "           exit non-zero if anything is missing or differs, zero if all match" >&2
}

# Arg parsing — accept both `--check <owner>/<repo>` and the plain `<owner>/<repo>`
# form; reject anything else with usage. Keep --check optional and position it first.
check_mode=0
if [ "$#" -ge 1 ] && [ "${1:-}" = "--check" ]; then
  check_mode=1
  shift
fi

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

repo="$1"

# Resolve THIS ystack clone's repo root from the script's own location, following
# symlinks, so the CLAUDE.md template reminder below can print an ABSOLUTE path. This
# script is run by absolute path FROM the target repo (per QUICKSTART/install.sh), so a
# relative "templates/target-CLAUDE.md" would misresolve against the target repo where
# the template doesn't exist. Same derivation idiom as install.sh / doctor.sh.
script_path="$0"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
repo_root="$(cd "$(dirname "$script_path")/.." && pwd -P)"
target_claude_template="$repo_root/templates/target-CLAUDE.md"

# Preflight — fail honestly and early, BEFORE creating any label, so a misconfigured
# run surfaces an actionable pointer instead of an opaque mid-loop gh error and a
# half-bootstrapped repo (see QUICKSTART.md > Prerequisites).
if ! command -v gh >/dev/null 2>&1; then
  echo "error: missing required command: gh" >&2
  echo "       install the GitHub CLI and authenticate, then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites" >&2
  exit 1
fi

# Validate the arg is <owner>/<repo> shape: two non-empty segments, no slashes or
# whitespace within either, separated by a single '/'. Catches a bare repo name, a
# full URL, or a stray space before any side-effect (and before the repo-access probe
# below, which needs a well-formed repo to query).
if ! [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
  echo "error: expected <owner>/<repo>, got: $repo" >&2
  usage
  exit 1
fi

# Scope the auth/access check to the target repo, not all of gh's configured state.
# A bare `gh auth status` checks EVERY configured account/host, so an unrelated stale
# login or enterprise host would abort this run even when the user has valid access to
# the repo we're about to modify. `gh repo view` verifies authentication AND access to
# exactly the repo that `gh label create --repo "$repo"` will touch. --check reads the
# same repo (it lists labels), so the probe applies to both modes.
if ! gh repo view "$repo" >/dev/null 2>&1; then
  echo "error: cannot access ${repo} via gh — not authenticated, or no access to that repo" >&2
  echo "       run 'gh auth login' (and confirm you can see ${repo}), then re-run" >&2
  echo "       see QUICKSTART.md > Prerequisites" >&2
  exit 1
fi

# Each entry: name|color|description (color is a 6-hex code, no leading '#').
labels=(
  "debating|fbca04|Issue under manager-debate; not yet approved"
  "ready|0e8a16|Cleared to run (user approval OR consensus); yshifu's cue to spawn the coder"
  "round-0|c5def5|Review-loop counter: initial PR"
  "round-1|7fb3e0|Review-loop counter: revision 1"
  "round-2|4a90d9|Review-loop counter: revision 2"
  "round-3|1f6fc0|Review-loop counter: revision 3 (cap)"
  "needs-human|d93f0b|Escalation: round cap hit, ambiguous spec, oversized PR, or failure"
  "merge-ready|5319e7|This head passed review; waiting on YOUR merge (no agent merges; void once new commits land)"
  "stale|e4a11b|v2 chain: artifact built from an outdated upstream (frontmatter hash mismatch); do not act on it"
)

if [ "$check_mode" -eq 1 ]; then
  # Read-only drift report. Pull the live labels once (name/color/description) and
  # compare each script-defined label against the live state. Mutate nothing.
  echo "Checking loop labels on ${repo} (read-only)..."

  # Snapshot live labels as TSV: name<TAB>color<TAB>description. GitHub stores colors
  # without the leading '#'; normalize both sides to lowercase for a case-insensitive
  # hex compare. Use a high --limit so gh paginates the full label set; otherwise a
  # canonical label past the page limit is falsely reported missing on large repos.
  live="$(gh label list --repo "$repo" --limit 9999 \
    --json name,color,description \
    --jq '.[] | [.name, (.color // ""), (.description // "")] | @tsv')"

  drift=0
  for entry in "${labels[@]}"; do
    IFS='|' read -r name color desc <<<"$entry"

    # Find the live row whose name matches exactly (field 1 == name). Feed $live via a
    # here-string (no producer process) and read to EOF — no early `exit`. A unique label
    # name matches at most once, so reading the rest is harmless, and there's no upstream
    # printf to receive SIGPIPE and abort the run under `set -o pipefail`.
    row="$(awk -F'\t' -v n="$name" '$1 == n {print}' <<<"$live")"

    if [ -z "$row" ]; then
      echo "  missing: $name"
      drift=1
      continue
    fi

    live_color="$(printf '%s' "$row" | cut -f2)"
    live_desc="$(printf '%s' "$row" | cut -f3-)"

    diffs=()
    # Name already matches (that's how we found the row), so only color/description
    # can differ. Compare color case-insensitively; description exactly.
    if [ "$(printf '%s' "$live_color" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$color" | tr '[:upper:]' '[:lower:]')" ]; then
      diffs+=("color (live='${live_color}' want='${color}')")
    fi
    if [ "$live_desc" != "$desc" ]; then
      diffs+=("description (live='${live_desc}' want='${desc}')")
    fi

    if [ "${#diffs[@]}" -eq 0 ]; then
      echo "  matches: $name"
    else
      # Join the differing fields with '; ' for a single readable line. Build the join
      # explicitly: IFS uses only its first char, so it can't produce a two-char
      # separator on its own.
      joined="${diffs[0]}"
      for d in "${diffs[@]:1}"; do
        joined="${joined}; ${d}"
      done
      printf '  differs: %s — %s\n' "$name" "$joined"
      drift=1
    fi
  done

  if [ "$drift" -ne 0 ]; then
    echo ""
    echo "drift detected — run '$0 ${repo}' to reconcile (force-edits live labels to this script's definitions)" >&2
    exit 1
  fi
  echo ""
  echo "all labels present and matching"
  exit 0
fi

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
    # Genuine already-exists — force-edit in place. This NORMALIZES the live label to
    # the definition above (color + description), so re-running reconciles any drift.
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

Labels done. Note: running this by hand is OPTIONAL — yshifu creates/reconciles these labels
itself on its first-loop-action bootstrap when you run /yshifu in the target repo, so
adoption is 'cd repo -> /yshifu -> go'. This manual run is a pre-flight / drift-reconcile.

Manual follow-ups this script can't do (see templates/repo-setup.md):
  1. Branch protection on main — UI-only, and unavailable on free private repos.
  2. CI workflow — a PR check that runs tests + lint (the hard merge gate). This is the ONE
     real precondition; yshifu's readiness self-check (doctor.sh, run on first use) flags a
     missing PR-CI as an advisory warning. You no longer have to wire it yourself: if the repo
     has no PR CI, yshifu can BOOTSTRAP it — it scaffolds a pull_request workflow from your
     auto-discovered toolchain as the first 'add PR CI' issue. That CI-bootstrap PR is
     HUMAN-MERGE-ONLY: yshifu classifies it as such and does NOT run merge-pr.sh on it at all — a
     same-repo bootstrap PR that adds the workflow can run it on its own PR and self-report green,
     so the human, not the tooling, is the gate — YOU approve and merge it by hand. Or wire it
     yourself. Either way CI-on-PRs stays the hard gate.
  3. (Optional) A target CLAUDE.md is NOT required — the coder auto-discovers the
     install/lint/build/test commands from the repo's CI workflows and standard manifests.
     A filled-in CLAUDE.md "Stack & commands" is an OPTIONAL override — add one only to
     pin or disambiguate a non-standard toolchain auto-discovery wouldn't get right.
     Template (under your ystack clone): ${target_claude_template}.
  4. Install the /yshifu command: run scripts/install.sh from your ystack clone.
  5. Connect the Codex CLI (signed in) so yshifu can run scripts/codex-review.sh on this repo.
  6. Set THIS target's north star — create it yourself: copy templates/.ystack/north-star.md
     (from your ystack clone) into this repo as .ystack/north-star.md, replace the placeholder
     with your own direction, remove the '<!-- ystack-shipped-default -->' marker, then commit it
     (this script does NOT seed the star — it only creates the loop labels above). Then approve it
     with yshifu once you run /yshifu (this unlocks proactive autonomous mode). Approve it to yshifu
     in-session, not by editing the file — the shipped approval note is the prior owner's history,
     not a token that approves the goal for you. Until it's set + committed + approved, yshifu acts
     only on issues you direct (your one-liner -> yshifu drafts the spec -> you approve that drafted
     spec -> ready). (ystack-self is its own target: running against the control-plane repo uses
     its root NORTH_STAR.md instead.)
EOF
