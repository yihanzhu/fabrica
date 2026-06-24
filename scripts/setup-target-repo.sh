#!/usr/bin/env bash
set -euo pipefail

# setup-target-repo.sh — bootstrap a target repo's loop labels.
#
# Creates the labels the review loop uses as its state (each coder spawn is stateless).
# Idempotent: re-running on a repo that already has the labels updates them instead of
# failing. Branch protection, CI, the /faber command, and the Codex CLI reviewer are NOT
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

usage() {
  echo "usage: $0 [--check] <owner>/<repo>" >&2
  echo "  bootstraps the loop labels (ready, round-0..3, needs-human, merge-ready) on the target repo" >&2
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
  "ready|0e8a16|Record of your approval; Faber's cue to spawn the coder"
  "round-0|c5def5|Review-loop counter: initial PR"
  "round-1|7fb3e0|Review-loop counter: revision 1"
  "round-2|4a90d9|Review-loop counter: revision 2"
  "round-3|1f6fc0|Review-loop counter: revision 3 (cap)"
  "needs-human|d93f0b|Escalation: round cap hit, ambiguous spec, oversized PR, or failure"
  "merge-ready|5319e7|Codex review passed; awaiting your merge"
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

    # Find the live row by name, case-insensitively (GitHub label names are unique
    # case-insensitively — it disallows case-only duplicates). Matching exact-case-first
    # would still land the same single row; lowercasing both sides catches case-only
    # drift (e.g. live 'Ready' vs canonical 'ready') so we report it as differs, not
    # missing — 'missing' would be wrong since the label exists and a plain --check
    # rerun after reconcile must pass.
    row="$(printf '%s\n' "$live" | awk -F'\t' -v n="$name" \
      'tolower($1) == tolower(n) {print; exit}')"

    if [ -z "$row" ]; then
      echo "  missing: $name"
      drift=1
      continue
    fi

    live_name="$(printf '%s' "$row" | cut -f1)"
    live_color="$(printf '%s' "$row" | cut -f2)"
    live_desc="$(printf '%s' "$row" | cut -f3-)"

    diffs=()
    # We matched case-insensitively, so the live name may differ only in casing.
    # Flag that as a diff (the normal run renames it to canonical to reconcile).
    if [ "$live_name" != "$name" ]; then
      diffs+=("name-casing (live='${live_name}' want='${name}')")
    fi
    # Compare color case-insensitively; description exactly.
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

# Snapshot live label names once so we can detect case-only drift (e.g. live 'Ready'
# vs canonical 'ready'). GitHub disallows case-only duplicates, so when a canonical
# label exists only under different casing, `gh label create` fails with "already
# exists" yet `gh label edit "<canonical>"` would also fail (no exact-name match) — we
# must rename the live label to canonical first. One newline-separated list of names.
live_names="$(gh label list --repo "$repo" --limit 9999 --json name --jq '.[].name')"

for entry in "${labels[@]}"; do
  IFS='|' read -r name color desc <<<"$entry"
  # If a label exists under a different casing than canonical, rename it to canonical
  # first; the subsequent create/edit then reconciles color/description as usual. Only
  # rename when there's a case-insensitive match but NO exact-case match (an exact match
  # is handled idempotently by the create/edit path below).
  live_name="$(printf '%s\n' "$live_names" | awk -v n="$name" \
    'tolower($0) == tolower(n) {print; exit}')"
  if [ -n "$live_name" ] && [ "$live_name" != "$name" ]; then
    gh label edit "$live_name" --repo "$repo" --name "$name" >/dev/null
    echo "  renamed: $live_name -> $name"
  fi
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

Labels done. Manual follow-ups this script can't do (see templates/repo-setup.md):
  1. Branch protection on main — UI-only, and unavailable on free private repos.
  2. CI workflow — a PR check that runs tests + lint (the hard merge gate).
  3. Install the /faber command: run scripts/install.sh from your fabrica clone.
  4. Connect the Codex CLI (signed in) so Faber can run scripts/codex-review.sh on this repo.
EOF
