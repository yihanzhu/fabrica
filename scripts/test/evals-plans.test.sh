#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set-plans.json"
planner="$root/orchestrator/v1/reconciliation-plan.jq"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-plans-test.XXXXXX") || exit 1
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

# --- shipped seed set: canonical, listed, and the family names its source -------
[ -f "$seed_set" ] && [ ! -L "$seed_set" ] || fail 'plans seed set missing'
"$jq_bin" -S -c . "$seed_set" > "$tmp/canonical.json" || fail 'seed set parse'
/usr/bin/cmp -s "$seed_set" "$tmp/canonical.json" || fail 'seed set not canonical'
for path in evals/v1/seed-set-plans.json scripts/test/evals-plans.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
"$jq_bin" -e '
  .body.seed_source == "orchestrator.reconciliation-plan.v1" and .body.shared == {} and
  (.body.cases | length) == 13 and
  all(.body.cases[]; .family_id == "repeated-cancelled-missed-events")
' "$seed_set" > /dev/null || fail 'seed set header'
"$jq_bin" -e '
  .body.families[] | select(.family_id == "repeated-cancelled-missed-events") |
  .seed_status == "seeded" and
  .seed_sources == ["orchestrator.reconciliation-plan.v1","orchestrator.state-scanner.v1"]
' "$catalog" > /dev/null || fail 'catalog does not name both event seed sources'
pass 'plans seed set is canonical, listed, and its catalog family names the planner source'

/usr/bin/grep -qF "'reconciliation-plan.jq $(sha_file "$planner")'" "$launcher" ||
  fail 'launcher does not pin the reconciliation planner'
pass 'launcher pins the shipped reconciliation planner by digest'

# --- one deterministic pass through the real planner ----------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" --arg planner_sha "$(sha_file "$planner")" '
  .kind == "eval_run_result" and .id == "evals.run.evals.seed.orchestrator-plans.v1" and
  .body.seed_source == "orchestrator.reconciliation-plan.v1" and
  .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:13,passed:13,failed:0,inconclusive:0} and
  all(.body.cases[]; .verdict == "passed" and .grader_kind == "deterministic" and
      .subject_ref.content_id == "orchestrator-reconciliation-input.v1") and
  all(.body.trace[]; .grader_kind == "deterministic" and
      .tool_ref == {content_id:"orchestrator-reconciliation-planner.v1",
                    media_type:"text/x-jq",sha256:$planner_sha} and
      .adapter == {state:"absent"} and .latency == {state:"absent"} and .cost == {state:"absent"}) and
  ([.body.evaluator.content.body.orchestrator_closure[].path] |
   index("orchestrator/v1/reconciliation-plan.jq")) != null
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all thirteen plan cases pass through the real reconciliation planner'

"$jq_bin" -e '
  def planned($id): .body.cases[] | select(.case_id == $id) | .observation.value.plan.value;
  def refused($id): .body.cases[] | select(.case_id == $id) | .observation.value.error_token.value;
  def key($name): {initiative_id:("initiative." + $name),workflow_id:"workflow.example",
                   stage_id:"stage.example",task_class_id:"task.example"};
  (planned("plan.pending-redelivery-same-key") |
    .deliveries == [{attempt_number:1,delivery_mode:"redelivery",operation:"dispatch-stage",
                     request_sha256:("a" * 64),stage_key:key("a")}]) and
  (planned("plan.acknowledged-suppressed") |
    .deliveries == [] and .suppressed ==
      [{attempt_number:1,operation:"dispatch-stage",reason_id:"planner.delivery-acknowledged",
        request_sha256:("a" * 64),stage_key:key("a")}]) and
  (planned("plan.failed-stage-retry") | .deliveries[0].attempt_number == 2) and
  (planned("plan.stranded-recovery") | .deliveries[0].operation == "recover-stranded-attempt") and
  (planned("plan.backpressure-full-deferred") |
    .deliveries == [] and .deferred[0].stage_key == key("a") and
    .deferred[0].reason_id == "planner.backpressure-slots-exhausted") and
  (planned("plan.redelivery-priority") |
    .deliveries[0].stage_key == key("b") and .deliveries[0].delivery_mode == "redelivery" and
    .deferred[0].stage_key == key("a")) and
  (planned("plan.operator-only-messages") |
    [.operator_messages[] | .stage_key.initiative_id] ==
      ["initiative.a","initiative.b","initiative.c","initiative.d","initiative.e"] and
    [.operator_messages[] | .action] ==
      ["none","operator-reconcile","refresh-stage-inputs","resolve-stage-blocker","wait-for-attempt"]) and
  refused("plan.retry-limit-refused") == "E_RECONCILIATION_INPUT" and
  refused("plan.duplicate-classifications-refused") == "E_RECONCILIATION_INPUT" and
  refused("plan.duplicate-ledger-refused") == "E_RECONCILIATION_INPUT"
' "$first" > /dev/null || fail 'redelivery, suppression, retry, or backpressure misplanned'
pass 'repeats redeliver once, acknowledgements suppress, retries stop at the limit, overflow defers, each by exact stage'

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
pass 'inactive data-only boundary holds for planner replays'

# --- grading is honest --------------------------------------------------------------
wrong="$tmp/wrong.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "plan.pending-redelivery-same-key"
    then .expectation.deliveries[0].delivery_mode = "first-delivery" else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.out" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:13,passed:12,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "plan.pending-redelivery-same-key") |
    .verdict == "failed" and .reason_id == "evals.plan-mismatch")
' "$tmp/wrong.out" > /dev/null || fail 'a repeat expected as a fresh delivery was not failed'
flipped="$tmp/flipped.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "plan.retry-limit-refused"
    then .expectation = {disposition:"planned",deliveries:[],deferred:[],
                         suppressed:[],operator_messages:[]} else . end)
' "$seed_set" > "$flipped"
run_framework "$tmp/flipped.out" "$tmp/flipped.err" "$flipped" || fail 'flipped-disposition run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "plan.retry-limit-refused") |
  .verdict == "failed" and .reason_id == "evals.disposition-mismatch"
' "$tmp/flipped.out" > /dev/null || fail 'a refusal expected to plan was not failed'
swapped="$tmp/swapped.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "plan.backpressure-partial-deferred"
    then .expectation.deliveries[0].stage_key.initiative_id = "initiative.b" |
         .expectation.deliveries[0].request_sha256 = ("b" * 64) |
         .expectation.deferred[0].stage_key.initiative_id = "initiative.a" |
         .expectation.deferred[0].request_sha256 = ("a" * 64) else . end)
' "$seed_set" > "$swapped"
run_framework "$tmp/swapped.out" "$tmp/swapped.err" "$swapped" || fail 'swapped-stage run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "plan.backpressure-partial-deferred") |
  .verdict == "failed" and .reason_id == "evals.plan-mismatch"
' "$tmp/swapped.out" > /dev/null || fail 'deferring the other stage with the same counts was accepted'
pass 'a wrong plan, a wrong disposition, or the wrong stage deferred is graded failed'

# --- fail closed on bad, moved, or misfiled input ----------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "plan.first-delivery"
  then .input.sha256 = ("f" * 64) else . end)' "$seed_set" > "$tmp/moved.json"
expect_error moved-input-digest E_RELATION "$tmp/moved.json"
# A planner seed set may not claim a family the catalog seeds from other sources.
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "plan.first-delivery"
  then .family_id = "stale-moved-artifacts" else . end)' "$seed_set" > "$tmp/misfiled.json"
expect_error family-without-planner-source E_SHAPE "$tmp/misfiled.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "plan.first-delivery"
  then .expectation.deliveries[0].operation = "merge" else . end)' "$seed_set" > "$tmp/badop.json"
expect_error unknown-plan-operation E_SHAPE "$tmp/badop.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "plan.first-delivery"
  then .input.content.extra = true else . end)' "$seed_set" > "$tmp/extra.json"
expect_error mis-shaped-planner-input E_SHAPE "$tmp/extra.json"
pass 'moved, misfiled, and mis-shaped planner seed sets fail closed with one token'

# --- the launcher refuses an edited planner -----------------------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts" "$copy/orchestrator/v1"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
for f in scan-state.sh state-scanner-launcher.sh state-scanner-driver.sh state-scanner.jq \
  reconciliation-plan.jq; do
  /bin/cp "$root/orchestrator/v1/$f" "$copy/orchestrator/v1/$f"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/orchestrator/v1/reconciliation-plan.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited planner was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited planner was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited reconciliation planner is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
