#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
driver="$root/evals/v1/evals-driver.sh"
program="$root/evals/v1/evals.jq"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set.json"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-test.XXXXXX") || exit 1
download=''
cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then /bin/rm -f -- "$download"; fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { /usr/bin/printf 'not ok - %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download" ||
    fail 'jq download'
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
/bin/mkdir -m 700 "$tmp/bin"
/bin/cp "$jq_cache" "$tmp/bin/jq"
/bin/chmod 0555 "$tmp/bin/jq"
jq_bin="$tmp/bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

# --- shipped files: present, regular, canonical, mode -----------------------
for shipped in "$framework" "$launcher" "$driver" "$program" "$catalog" "$seed_set"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing shipped file $shipped"
done
for json in "$catalog" "$seed_set"; do
  "$jq_bin" -S -c . "$json" > "$tmp/canonical.json" || fail 'shipped json parse'
  /usr/bin/cmp -s "$json" "$tmp/canonical.json" || fail "shipped json not canonical: $json"
done
pass 'shipped documents are canonical single-root json'

for path in evals/v1/run-evals.sh evals/v1/evals-launcher.sh evals/v1/evals-driver.sh \
  evals/v1/evals.jq evals/v1/eval-catalog.json evals/v1/seed-set.json \
  scripts/test/evals-framework.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
pass 'restore manifest lists every framework path'

program_sha=$(sha_file "$program")
catalog_sha=$(sha_file "$catalog")
driver_sha=$(sha_file "$driver")
/usr/bin/grep -qF "program_sha=$program_sha" "$launcher" || fail 'launcher pins program digest'
/usr/bin/grep -qF "catalog_sha=$catalog_sha" "$launcher" || fail 'launcher pins catalog digest'
/usr/bin/grep -qF "driver_sha=$driver_sha" "$launcher" || fail 'launcher pins driver digest'
/usr/bin/grep -qF "verify_hash $program_sha" "$driver" || fail 'driver pins program digest'
/usr/bin/grep -qF "verify_hash $catalog_sha" "$driver" || fail 'driver pins catalog digest'
pass 'launcher and driver pin the exact shipped program, catalog, and driver'

# --- catalog contract --------------------------------------------------------
"$jq_bin" -e '
  .kind == "eval_catalog" and .body.activation_state == "inactive" and
  .body.fail_mode == "closed" and (.body.families | length) == 9 and
  ([.body.families[] | select(.seed_status == "seeded")] | length) == 2 and
  ([.body.families[] | select(.seed_status == "declared")] | length) == 7 and
  all(.body.families[]; .seed_status == "seeded" and .seed_source.state == "present" or
      .seed_status == "declared" and .seed_source.state == "absent") and
  all(.body.families[] | select((.grader_kinds | index("deterministic")) == null);
      .trial_policy.kind == "multi")
' "$catalog" > /dev/null || fail 'catalog shape'
pass 'catalog names all nine roadmap families, two seeded, stochastic ones multi-trial'

# --- the run on the committed seed set ---------------------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" --arg catalog_sha "$catalog_sha" '
  .schema_version == 1 and .kind == "eval_run_result" and
  .body.activation_state == "inactive" and .body.authority_effect == "none" and
  .body.mode == "deterministic-offline" and
  .body.catalog_ref.sha256 == $catalog_sha and .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:8,passed:8,failed:0,inconclusive:0} and
  (.body.cases | length) == 8 and all(.body.cases[]; .verdict == "passed") and
  (.body.trace | length) == 8 and
  all(.body.trace[]; .adapter == {state:"absent"} and .gate == {state:"absent"} and
      .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.core_closure | length) == 9 and
  ([.body.cases[] | select(.expectation.disposition == "rejected")] | length) == 4 and
  ([.body.cases[] | select(.expectation.disposition == "accepted")] | length) == 4
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all eight seed cases pass through the real core with the expected disposition'

"$jq_bin" -e '
  ([.body.cases[] | select(.family_id == "stale-moved-artifacts")] | length) == 4 and
  ([.body.cases[] | select(.family_id == "empty-fake-timed-out-degraded-reviews")] | length) == 4 and
  (.body.cases[] | select(.case_id == "stale.moved-request-ref-rejected") |
    .observation.value.error_token.value == "E_REF") and
  (.body.cases[] | select(.case_id == "review.fake-inconclusive-pass-rejected") |
    .observation.value.error_token.value == "E_RELATION") and
  (.body.cases[] | select(.case_id == "review.missing-independent-review-rejected") |
    .observation.value.error_token.value == "E_RELATION")
' "$first" > /dev/null || fail 'family coverage or rejection tokens'
pass 'moved artifacts reject with E_REF; fake and degraded reviews reject with E_RELATION'

second="$tmp/second.json"
run_framework "$second" "$tmp/second.err" "$seed_set" || fail 'second run failed'
/usr/bin/cmp -s "$first" "$second" || fail 'repeat run differs'
[ "$("$jq_bin" -S -c . "$first")" = "$(<"$first")" ] || fail 'output not canonical'
pass 'repeat run is byte-identical and canonical'

"$jq_bin" -e '
  ([.. | objects | keys[] | select(. == "authority" or . == "permissions" or
    . == "capabilities" or . == "credential" or . == "network" or . == "execute" or
    . == "schedule" or . == "merge" or . == "publish")] | length) == 0
' "$first" > /dev/null || fail 'authority or effect field present'
pass 'inactive data-only boundary: no authority, permission, or effect fields'

# --- grading is honest: a wrong expectation fails, an undecidable family stays inconclusive
wrong="$tmp/wrong-expectation.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "stale.status-accepted"
    then .expectation.status = "completed" else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.json" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:8,passed:7,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "stale.status-accepted") |
    .verdict == "failed" and .reason_id == "evals.status-mismatch")
' "$tmp/wrong.json" > /dev/null || fail 'wrong expectation was not failed'
pass 'a wrong expectation is graded failed, never silently passed'

stochastic="$tmp/stochastic.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "stale.completed-baseline"
    then .family_id = "reviewer-severity-false-positive-negative" else . end)
' "$seed_set" > "$stochastic"
run_framework "$tmp/stochastic.out" "$tmp/stochastic.err" "$stochastic" || fail 'stochastic run errored'
"$jq_bin" -e '
  .body.summary == {total:8,passed:7,failed:0,inconclusive:1} and
  (.body.cases[] | select(.case_id == "stale.completed-baseline") |
    .verdict == "inconclusive" and .grader_kind == "none" and
    .reason_id == "evals.no-deterministic-grader")
' "$tmp/stochastic.out" > /dev/null || fail 'model-only family was decided deterministically'
pass 'a family without a deterministic grader stays inconclusive'

# --- fail closed on bad or moved input ----------------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
/usr/bin/printf '{"kind":"eval_seed_set"' > "$tmp/truncated.json"
expect_error truncated-input E_PARSE "$tmp/truncated.json"
"$jq_bin" -S -c '.body.cases[0].result.sha256 = ("f" * 64)' "$seed_set" > "$tmp/moved.json"
expect_error moved-result-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.cases[0].request_role = "operator"' "$seed_set" > "$tmp/badrole.json"
expect_error unknown-request-role E_SHAPE "$tmp/badrole.json"
"$jq_bin" -S -c 'del(.body.cases[0].expectation)' "$seed_set" > "$tmp/noexp.json"
expect_error missing-expectation E_SHAPE "$tmp/noexp.json"
pass 'malformed, moved, and mis-shaped seed sets fail closed with one token'

if "$framework" run "$seed_set" "not-a-time" >"$tmp/badtime.out" 2>"$tmp/badtime.err"; then
  fail 'observed_at is not validated'
fi
[ "$(<"$tmp/badtime.err")" = E_USAGE ] || fail 'observed_at is not validated'
pass 'observed_at must be an exact UTC timestamp'

# --- the launcher refuses a stale (edited) program -----------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json seed-set.json; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/evals/v1/evals.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited program was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited program was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited program is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
