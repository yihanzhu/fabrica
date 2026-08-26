#!/usr/bin/env bash
set -euo pipefail

# pending-impl.sh — which approved spec still needs an implementation?
#
# A slug needs implementation when work/<slug>/spec.md exists but plan.md is
# missing from main, or the plan was drafted from an older spec. A slug whose
# spec is itself stale (built from an older intent) is broken upstream: report
# "stale=<name>" and do not build on it — the spec stage will redo it first.
# Prints at most one line, or nothing when everything is done and fresh.

for dir in work/*/; do
  [ -d "$dir" ] || continue
  slug="$(basename "$dir")"
  intent="work/${slug}/intent.md"
  spec="work/${slug}/spec.md"
  plan="work/${slug}/plan.md"
  [ -f "$spec" ] || continue

  # Chain freshness first: never build on a spec whose intent has moved.
  if [ -f "$intent" ]; then
    want_intent="$(git hash-object "$intent")"
    have_intent="$(awk '/^intent-blob:/ {print $2; exit}' "$spec")"
    if [ "$have_intent" != "$want_intent" ]; then
      echo "stale=${slug}"
      exit 0
    fi
  fi

  if [ ! -f "$plan" ]; then
    echo "slug=${slug}"
    exit 0
  fi

  want_spec="$(git hash-object "$spec")"
  have_spec="$(awk '/^spec-blob:/ {print $2; exit}' "$plan")"
  if [ "$have_spec" != "$want_spec" ]; then
    echo "slug=${slug}"
    exit 0
  fi
done
exit 0
