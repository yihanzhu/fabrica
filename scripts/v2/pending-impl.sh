#!/usr/bin/env bash
set -euo pipefail

# pending-impl.sh — which approved specs still need an implementation?
#
# A slug needs implementation when work/<slug>/spec.md exists but plan.md is
# missing from main, or the plan was drafted from an older spec. A slug whose
# spec is stale (built from an older or deleted intent) is broken upstream:
# it is reported as "stale=<name>" and never built on.
#
# Prints ALL findings, one line per slug — never just the first, so a second
# initiative merged while the first is in flight is visible, not stranded
# (Codex review of #131). The caller takes the first "slug=" line and re-runs
# after finishing it to drain the rest. Prints nothing when everything is
# done and fresh.

for dir in work/*/; do
  [ -d "$dir" ] || continue
  slug="$(basename "$dir")"
  intent="work/${slug}/intent.md"
  spec="work/${slug}/spec.md"
  plan="work/${slug}/plan.md"
  [ -f "$spec" ] || continue

  # Chain freshness first: never build on a spec whose intent has moved —
  # or vanished. A spec without its intent is orphaned, not fresh.
  if [ ! -f "$intent" ]; then
    echo "stale=${slug}"
    continue
  fi
  want_intent="$(git hash-object "$intent")"
  have_intent="$(awk '/^intent-blob:/ {print $2; exit}' "$spec")"
  if [ "$have_intent" != "$want_intent" ]; then
    echo "stale=${slug}"
    continue
  fi

  if [ ! -f "$plan" ]; then
    echo "slug=${slug}"
    continue
  fi

  want_spec="$(git hash-object "$spec")"
  have_spec="$(awk '/^spec-blob:/ {print $2; exit}' "$plan")"
  if [ "$have_spec" != "$want_spec" ]; then
    echo "slug=${slug}"
  fi
done
exit 0
