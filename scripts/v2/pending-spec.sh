#!/usr/bin/env bash
set -euo pipefail

# pending-spec.sh — which initiative still needs a spec?
#
# Looks at every work/<slug>/intent.md in the current checkout (run it on main).
# A slug needs a spec when spec.md is missing, or when the spec was drafted from
# an older intent (its intent-blob line no longer matches the intent's hash).
# Prints the first such slug as "slug=<name>" (ready for $GITHUB_OUTPUT), or
# prints nothing. Re-runs are safe: once a fresh spec is on main, the slug
# stops being reported.

for dir in work/*/; do
  [ -d "$dir" ] || continue
  slug="$(basename "$dir")"
  intent="work/${slug}/intent.md"
  spec="work/${slug}/spec.md"
  [ -f "$intent" ] || continue

  if [ ! -f "$spec" ]; then
    echo "slug=${slug}"
    exit 0
  fi

  want="$(git hash-object "$intent")"
  have="$(awk '/^intent-blob:/ {print $2; exit}' "$spec")"
  if [ "$have" != "$want" ]; then
    echo "slug=${slug}"
    exit 0
  fi
done
exit 0
