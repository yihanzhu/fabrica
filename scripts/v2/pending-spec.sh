#!/usr/bin/env bash
set -euo pipefail

# pending-spec.sh — which initiatives still need a spec?
#
# Looks at every work/<slug>/intent.md in the current checkout (run it on main).
# A slug needs a spec when spec.md is missing, or when the spec was drafted from
# an older intent (its intent-blob line no longer matches the intent's hash).
#
# Prints ALL pending slugs, one "slug=<name>" line each — never just the first,
# so a second initiative merged while the first is in flight is visible, not
# stranded (Codex review of #131). The caller takes the first line and re-runs
# after finishing it to drain the rest. Prints nothing when all specs are fresh.

for dir in work/*/; do
  [ -d "$dir" ] || continue
  slug="$(basename "$dir")"
  intent="work/${slug}/intent.md"
  spec="work/${slug}/spec.md"
  [ -f "$intent" ] || continue

  if [ ! -f "$spec" ]; then
    echo "slug=${slug}"
    continue
  fi

  want="$(git hash-object "$intent")"
  have="$(awk '/^intent-blob:/ {print $2; exit}' "$spec")"
  if [ "$have" != "$want" ]; then
    echo "slug=${slug}"
  fi
done
exit 0
