#!/usr/bin/env bash
set -euo pipefail

# Hermetic asserts for scripts/v2/quota-preflight.sh. gh is stubbed on PATH:
# the stub serves per-workflow run counts from $GH_STUB_RUNS
# ("file.yml=count,..."), and $GH_STUB_DOWN=1 makes every gh call fail.
# No network, no gh auth.

here="$(cd "$(dirname "$0")/../.." && pwd -P)"
qp="$here/scripts/v2/quota-preflight.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${GH_STUB_DOWN:-0}" = "1" ]; then
  echo "gh: down" >&2
  exit 1
fi
# Sanity call: `gh run list --limit 1 --json databaseId`
# Count call:  `gh run list --workflow <file> ... --jq length`
wf=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--workflow" ]; then wf="$a"; fi
  prev="$a"
done
if [ -z "$wf" ]; then
  echo "[]"
  exit 0
fi
# Look up "<wf>=<count>" in GH_STUB_RUNS. Unknown workflows fail with real
# gh's missing-workflow message; a value of ERR simulates a transient outage.
entry="$(printf '%s\n' "${GH_STUB_RUNS:-}" | tr ',' '\n' | grep "^${wf}=" || true)"
if [ -z "$entry" ]; then
  echo "could not find any workflows named ${wf}" >&2
  exit 1
fi
val="${entry#*=}"
if [ "$val" = "ERR" ]; then
  echo "HTTP 500: something went wrong" >&2
  exit 1
fi
echo "$val"
STUB
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Under the backstop: report the summed count, exit 0.
set +e
out="$(GH_STUB_RUNS="spec-on-intent.yml=3,review-on-pr.yml=2" "$qp")"
code=$?
set -e
[ "$code" -eq 0 ] || fail "under backstop must exit 0 (got $code)"
printf '%s\n' "$out" | grep -qx "runs=5" || fail "should sum per-workflow counts (got: $out)"

# Missing workflows (pre-Stack-B) count as zero, not as an error.
set +e
out="$(GH_STUB_RUNS="plumbing-test.yml=1" "$qp")"
code=$?
set -e
[ "$code" -eq 0 ] || fail "missing workflows must not fail the brake (got $code)"
printf '%s\n' "$out" | grep -qx "runs=1" || fail "missing workflows count as 0 (got: $out)"

# At the backstop: exit 1, loudly.
set +e
out="$(GH_STUB_RUNS="spec-on-intent.yml=20" "$qp" 2>"$tmp/err")"
code=$?
set -e
[ "$code" -eq 1 ] || fail "at backstop must exit 1 (got $code)"
grep -q "means a bug" "$tmp/err" || fail "over-backstop failure must be loud"

# Backstop override.
set +e
GH_STUB_RUNS="spec-on-intent.yml=4" FABRICA_RUN_BACKSTOP=4 "$qp" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || fail "FABRICA_RUN_BACKSTOP override must apply (got $code)"

# gh completely down: refuse to guess, exit 1.
set +e
GH_STUB_DOWN=1 "$qp" >/dev/null 2>"$tmp/err"
code=$?
set -e
[ "$code" -eq 1 ] || fail "gh down must exit 1 (got $code)"
grep -q "refusing to guess" "$tmp/err" || fail "gh-down failure must be loud"

echo "ok: quota-preflight behaves"

# A transient per-workflow failure (not a missing workflow) must fail loudly,
# never count as zero (Codex review of #131).
set +e
GH_STUB_RUNS="spec-on-intent.yml=2,review-on-pr.yml=ERR" "$qp" >/dev/null 2>"$tmp/err"
code=$?
set -e
[ "$code" -eq 1 ] || fail "transient count failure must exit 1 (got $code)"
grep -q "fails open" "$tmp/err" || fail "transient failure must be loud"

echo "ok: transient-failure case behaves"
