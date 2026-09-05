#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set-events.json"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-events-test.XXXXXX") || exit 1
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

# --- shipped seed set: canonical, listed, and the family it seeds is marked ---
[ -f "$seed_set" ] && [ ! -L "$seed_set" ] || fail 'events seed set missing'
"$jq_bin" -S -c . "$seed_set" > "$tmp/canonical.json" || fail 'seed set parse'
/usr/bin/cmp -s "$seed_set" "$tmp/canonical.json" || fail 'seed set not canonical'
for path in evals/v1/seed-set-events.json scripts/test/evals-events.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
"$jq_bin" -e '
  .body.seed_source == "orchestrator.state-scanner.v1" and .body.shared == {} and
  (.body.cases | length) == 12 and
  all(.body.cases[]; .family_id == "repeated-cancelled-missed-events")
' "$seed_set" > /dev/null || fail 'seed set header'
"$jq_bin" -e '
  .body.families[] | select(.family_id == "repeated-cancelled-missed-events") |
  .seed_status == "seeded" and
  .seed_source == {state:"present",value:"orchestrator.state-scanner.v1"}
' "$catalog" > /dev/null || fail 'catalog does not mark the events family seeded'
pass 'events seed set is canonical, listed, and its catalog family is seeded'

# --- the launcher pins the exact scanner it replays ------------------------------
for member in scan-state.sh state-scanner-driver.sh state-scanner-launcher.sh state-scanner.jq; do
  /usr/bin/grep -qF "'$member $(sha_file "$root/orchestrator/v1/$member")'" "$launcher" ||
    fail "launcher does not pin orchestrator/v1/$member"
done
pass 'launcher pins the shipped state scanner by digest'

# --- one deterministic pass through the real scanner -----------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" \
  --arg scanner_sha "$(sha_file "$root/orchestrator/v1/scan-state.sh")" '
  .kind == "eval_run_result" and .id == "evals.run.evals.seed.orchestrator-events.v1" and
  .body.seed_source == "orchestrator.state-scanner.v1" and
  .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:12,passed:12,failed:0,inconclusive:0} and
  all(.body.cases[]; .verdict == "passed" and .grader_kind == "deterministic" and
      .subject_ref.kind == "orchestrator_state_snapshot" and .subject_ref.schema_version == 1) and
  all(.body.trace[]; .grader_kind == "deterministic" and
      .tool_ref == {content_id:"orchestrator-state-scanner-bootstrap.v1",
                    media_type:"text/x-shellscript",sha256:$scanner_sha} and
      .adapter == {state:"absent"} and .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.orchestrator_closure | length) == 4
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all twelve event cases pass through the real state scanner'

"$jq_bin" -e '
  def classified($id): .body.cases[] | select(.case_id == $id) | .observation.value.classification.value;
  def refused($id): .body.cases[] | select(.case_id == $id) | .observation.value.error_token.value;
  classified("events.missed-deadline-stranded") ==
    {class:"stranded",action:"recover-stranded-attempt",reason_id:"scanner.attempt-deadline-reached"} and
  classified("events.cancelled-terminal") ==
    {class:"terminal",action:"none",reason_id:"scanner.stage-cancelled"} and
  classified("events.cancelled-on-moved-target-stays-terminal").class == "terminal" and
  classified("events.failed-retryable") ==
    {class:"retryable",action:"retry-stage",reason_id:"scanner.stage-failed"} and
  classified("events.failed-retry-limit-blocked") ==
    {class:"blocked",action:"operator-reconcile",reason_id:"scanner.retry-limit-reached"} and
  classified("events.moved-target-stale").reason_id == "scanner.target-revision-moved" and
  refused("events.revision-mismatch-rejected") == "E_STALE" and
  refused("events.duplicate-stage-rejected") == "E_RELATION" and
  refused("events.ambiguous-current-and-terminal-rejected") == "E_RELATION"
' "$first" > /dev/null || fail 'missed, cancelled, repeated, or refused events misclassified'
pass 'missed deadlines strand, cancellations stay terminal, retries stop at the limit, repeats are refused'

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
pass 'inactive data-only boundary holds for scanner replays'

# --- grading is honest ---------------------------------------------------------------
wrong="$tmp/wrong.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "events.missed-deadline-stranded"
    then .expectation.class = "pending" | .expectation.action = "wait-for-attempt" |
         .expectation.reason_id = "scanner.attempt-in-flight" else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.out" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:12,passed:11,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "events.missed-deadline-stranded") |
    .verdict == "failed" and .reason_id == "evals.classification-mismatch")
' "$tmp/wrong.out" > /dev/null || fail 'wrong classification expectation was not failed'
flipped="$tmp/flipped.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "events.duplicate-stage-rejected"
    then .expectation = {disposition:"observed",class:"pending",action:"dispatch-stage",
                         reason_id:"scanner.no-attempt"} else . end)
' "$seed_set" > "$flipped"
run_framework "$tmp/flipped.out" "$tmp/flipped.err" "$flipped" || fail 'flipped-disposition run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "events.duplicate-stage-rejected") |
  .verdict == "failed" and .reason_id == "evals.disposition-mismatch"
' "$tmp/flipped.out" > /dev/null || fail 'a refusal expected to classify was not failed'
pass 'a wrong classification or disposition is graded failed, never silently passed'

# --- fail closed on bad or moved input ---------------------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "events.pending-dispatch"
  then .snapshot.sha256 = ("f" * 64) else . end)' "$seed_set" > "$tmp/moved.json"
expect_error moved-snapshot-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.seed_source = "orchestrator.reconciliation-plan.v1"' "$seed_set" \
  > "$tmp/unseeded-source.json"
expect_error declared-but-unseeded-source E_SHAPE "$tmp/unseeded-source.json"
"$jq_bin" -S -c '.body.shared = {requests:{}}' "$seed_set" > "$tmp/shared.json"
expect_error scanner-set-with-shared E_SHAPE "$tmp/shared.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "events.pending-dispatch"
  then .expectation.class = "retired" else . end)' "$seed_set" > "$tmp/badclass.json"
expect_error unknown-class E_SHAPE "$tmp/badclass.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "events.pending-dispatch"
  then .expected_revision.commit_id = "abc" else . end)' "$seed_set" > "$tmp/badrev.json"
expect_error malformed-revision E_SHAPE "$tmp/badrev.json"
pass 'moved snapshots and mis-shaped scanner seed sets fail closed with one token'

# --- the launcher refuses an edited scanner ------------------------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts" "$copy/orchestrator/v1"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
for f in scan-state.sh state-scanner-launcher.sh state-scanner-driver.sh state-scanner.jq; do
  /bin/cp "$root/orchestrator/v1/$f" "$copy/orchestrator/v1/$f"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/orchestrator/v1/state-scanner.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited scanner was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited scanner was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited state scanner is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
