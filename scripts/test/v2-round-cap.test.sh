#!/usr/bin/env bash
set -euo pipefail

# Hermetic asserts for scripts/v2/round-cap.sh. gh is stubbed on PATH: the
# stub serves labels from $GH_STUB_LABELS (comma-separated) and logs every
# `pr edit` to $GH_STUB_LOG. No network, no gh auth.

here="$(cd "$(dirname "$0")/../.." && pwd -P)"
rc="$here/scripts/v2/round-cap.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr view")
    # Portable across bash 3.2 (macOS) and 5 (CI): no arrays.
    if [ -n "${GH_STUB_LABELS:-}" ]; then
      printf '%s\n' "${GH_STUB_LABELS//,/$'\n'}"
    fi
    ;;
  "pr edit")
    shift 2
    echo "$*" >> "$GH_STUB_LOG"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 9
    ;;
esac
STUB
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH"
export GH_STUB_LOG="$tmp/edits.log"
: > "$GH_STUB_LOG"

fail() { echo "FAIL: $1" >&2; exit 1; }

# check: no labels means round 0, proceed.
out="$(GH_STUB_LABELS="" "$rc" check 1)"
printf '%s\n' "$out" | grep -qx "round=0" || fail "no labels = round 0 (got: $out)"
printf '%s\n' "$out" | grep -qx "proceed=true" || fail "round 0 should proceed"

# check: reads the highest round label, ignores others.
out="$(GH_STUB_LABELS="ready,round-2" "$rc" check 1)"
printf '%s\n' "$out" | grep -qx "round=2" || fail "should read round-2 (got: $out)"
printf '%s\n' "$out" | grep -qx "proceed=true" || fail "round 2 should proceed"

# check: at the cap, stop.
out="$(GH_STUB_LABELS="round-3" "$rc" check 1)"
printf '%s\n' "$out" | grep -qx "proceed=false" || fail "round 3 must stop"

# bump: 1 -> 2, adds the new label then removes the old one.
: > "$GH_STUB_LOG"
out="$(GH_STUB_LABELS="round-1" "$rc" bump 1)"
printf '%s\n' "$out" | grep -qx "round=2" || fail "bump 1->2 (got: $out)"
grep -q -- "--add-label round-2" "$GH_STUB_LOG" || fail "bump must add round-2"
grep -q -- "--remove-label round-1" "$GH_STUB_LOG" || fail "bump must remove round-1"

# bump at the cap: refuse, exit 3, change nothing.
: > "$GH_STUB_LOG"
set +e
out="$(GH_STUB_LABELS="round-3" "$rc" bump 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "bump at cap must exit 3 (got $code)"
printf '%s\n' "$out" | grep -qx "capped=true" || fail "bump at cap must say capped"
[ ! -s "$GH_STUB_LOG" ] || fail "bump at cap must not edit labels"

echo "ok: round-cap behaves"
