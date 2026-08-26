#!/usr/bin/env bash
set -euo pipefail

# Hermetic asserts for scripts/v2/pending-spec.sh + pending-impl.sh.
# Builds a throwaway git repo; no network, no gh.

here="$(cd "$(dirname "$0")/../.." && pwd -P)"
pending_spec="$here/scripts/v2/pending-spec.sh"
pending_impl="$here/scripts/v2/pending-impl.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q .
git config user.email "t@example.com"
git config user.name "t"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- pending-spec ---

mkdir -p work/alpha
echo "# Intent: alpha" > work/alpha/intent.md
git add -A
git commit -qm "intent"

out="$("$pending_spec")"
[ "$out" = "slug=alpha" ] || fail "missing spec should report alpha (got: '$out')"

blob="$(git hash-object work/alpha/intent.md)"
printf -- '---\nintent-blob: %s\n---\nspec body\n' "$blob" > work/alpha/spec.md
out="$("$pending_spec")"
[ -z "$out" ] || fail "fresh spec should report nothing (got: '$out')"

echo "edited" >> work/alpha/intent.md
out="$("$pending_spec")"
[ "$out" = "slug=alpha" ] || fail "edited intent should report alpha again (got: '$out')"

# --- pending-impl ---

# Refresh the spec so the chain is intact again.
blob="$(git hash-object work/alpha/intent.md)"
printf -- '---\nintent-blob: %s\n---\nspec body\n' "$blob" > work/alpha/spec.md

out="$("$pending_impl")"
[ "$out" = "slug=alpha" ] || fail "missing plan should report alpha (got: '$out')"

sblob="$(git hash-object work/alpha/spec.md)"
printf -- '---\nspec-blob: %s\n---\nplan body\n' "$sblob" > work/alpha/plan.md
out="$("$pending_impl")"
[ -z "$out" ] || fail "fresh plan should report nothing (got: '$out')"

echo "edited again" >> work/alpha/intent.md
out="$("$pending_impl")"
[ "$out" = "stale=alpha" ] || fail "stale spec should report stale, not build (got: '$out')"

# A directory without an intent (like a stray folder) must be ignored.
mkdir -p work/empty
out="$("$pending_spec")"
[ "$out" = "slug=alpha" ] || fail "dir without intent must be ignored (got: '$out')"

echo "ok: pending-spec / pending-impl behave"

# A spec whose intent was deleted is orphaned — stale, never fresh.
rm work/alpha/intent.md
out="$("$pending_impl")"
[ "$out" = "stale=alpha" ] || fail "deleted intent must read stale (got: '$out')"

echo "ok: orphaned-spec case behaves"

# Two initiatives pending at once must BOTH be listed — a second intent merged
# while the first is in flight must never be stranded (Codex review of #131).
mkdir -p work/beta work/gamma
echo "# Intent: alpha" > work/alpha/intent.md
blob="$(git hash-object work/alpha/intent.md)"
printf -- '---\nintent-blob: %s\n---\nspec body\n' "$blob" > work/alpha/spec.md
sblob="$(git hash-object work/alpha/spec.md)"
printf -- '---\nspec-blob: %s\n---\nplan body\n' "$sblob" > work/alpha/plan.md
echo "# Intent: beta" > work/beta/intent.md
echo "# Intent: gamma" > work/gamma/intent.md

out="$("$pending_spec")"
[ "$out" = "slug=beta
slug=gamma" ] || fail "both pending specs must be listed (got: '$out')"

# pending-impl: one buildable, one stale — both visible.
bblob="$(git hash-object work/beta/intent.md)"
printf -- '---\nintent-blob: %s\n---\nspec body\n' "$bblob" > work/beta/spec.md
printf -- '---\nintent-blob: 0000000000000000000000000000000000000000\n---\nspec\n' > work/gamma/spec.md
out="$("$pending_impl")"
[ "$out" = "slug=beta
stale=gamma" ] || fail "impl must list buildable and stale together (got: '$out')"

echo "ok: multi-slug draining behaves"
