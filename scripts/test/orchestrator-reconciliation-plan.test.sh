#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
planner="$root/orchestrator/v1/reconciliation-plan.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-reconciliation-plan-test.XXXXXX")
download=''
cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then /bin/rm -f -- "$download"; fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
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
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
[ "$(sha_file "$jq_cache")" = "$jq_sha" ] || fail 'jq digest'
/bin/mkdir -m 700 "$tmp/bin"
/bin/cp "$jq_cache" "$tmp/bin/jq"
/bin/chmod 0555 "$tmp/bin/jq"
jq_bin="$tmp/bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\\{64\\}\)'$/\\1/p" \
  "$root/scripts/core-contract.sh")
[ -n "$generation" ] &&
  [ "$("$jq_bin" -r --arg generation "$generation" \
      '[.[] | select(.generation_id==$generation)] | length' \
      "$root/core/v2/generation-registry.json")" -eq 1 ] ||
  fail 'selected generation'
schema_dir="$root/core/v2/generations/$generation/modules"
[ -f "$schema_dir/schema.jq" ] && [ ! -L "$schema_dir/schema.jq" ] ||
  fail 'selected schema module'

bundle="$tmp/bundle.json"
"$jq_bin" -S -c -n '
  def sha($character): $character * 64;
  def doc_ref($kind;$id;$character):
    {schema_version:2,kind:$kind,id:$id,sha256:sha($character)};
  def stage_key($name):
    {initiative_id:("initiative."+$name),workflow_id:"workflow.example",
     stage_id:"stage.example",task_class_id:"task.example"};
  def attempt($name;$number;$deadline):
    {attempt_id:("attempt."+$name),attempt_number:$number,deadline_at:$deadline,
     request_ref:doc_ref("stage_request";("request."+$name);$name),state:"started"};
  def classification($name;$class;$action;$number;$limit;$active;$result;$deadline):
    {stage_key:stage_key($name),class:$class,
     provenance:{
       snapshot_ref:{schema_identity:"orchestrator.state-snapshot.v1",
         kind:"orchestrator_state_snapshot",id:"observation.example",sha256:sha("6")},
       evaluator_ref:{content_id:"orchestrator-state-scanner-evaluator.v1",
         media_type:"application/vnd.ystack.orchestrator-state-scanner-evaluator+json",
         sha256:sha("7")},
       item_ref:{schema_identity:"orchestrator.state-item.v1",sha256:sha($name)},
       request_ref:doc_ref("stage_request";("request."+$name);$name),
       resolved_profile_ref:doc_ref("resolved_profile";("profile."+$name);$name),
       latest_result_ref:(if $result then
         {state:"present",value:doc_ref("stage_result";("result."+$name);$name)}
         else {state:"absent"} end),
       active_attempt:(if $active then {state:"present",value:attempt($name;$number;$deadline)}
         else {state:"absent"} end)},
     recovery:{action:$action,attempt_number:$number,reason_id:("scanner."+$name),
       retry_limit:$limit,source_reason:{state:"absent"}}};
  {
    classes:{
      dispatch_a:classification("a";"pending";"dispatch-stage";0;3;false;false;"2026-09-01T00:02:00Z"),
      dispatch_b:classification("b";"pending";"dispatch-stage";0;3;false;false;"2026-09-01T00:02:00Z"),
      retry_a:classification("a";"retryable";"retry-stage";1;3;false;true;"2026-09-01T00:02:00Z"),
      recover_a:classification("a";"stranded";"recover-stranded-attempt";1;3;true;false;"2026-09-01T00:00:00Z"),
      wait_e:classification("e";"pending";"wait-for-attempt";1;3;true;false;"2026-09-01T00:02:00Z"),
      terminal_a:classification("a";"terminal";"none";1;3;false;true;"2026-09-01T00:02:00Z"),
      operator_b:classification("b";"blocked";"operator-reconcile";3;3;false;true;"2026-09-01T00:02:00Z"),
      refresh_c:classification("c";"stale";"refresh-stage-inputs";1;3;false;true;"2026-09-01T00:02:00Z"),
      block_d:classification("d";"blocked";"resolve-stage-blocker";1;3;false;true;"2026-09-01T00:02:00Z")},
    input:{
      observation:{schema_version:1,kind:"orchestrator_state_observation",
        id:"observation.example",body:{activation_state:"inactive",authority_effect:"none",
          mode:"observation-only",
          core_contract:{generation_id_sha256:sha("9"),semantic_identity:"core.contracts.v2",
            package_ref:{content_id:"core-contract-package.v2",
              media_type:"application/vnd.ystack.core-contract+json",sha256:sha("8")}},
          source_revision:{repository_id:"repo.example",hash_algorithm:"sha1",commit_id:sha("a")[0:40]},
          observed_at:"2026-09-01T00:01:00Z",
          snapshot_ref:{schema_identity:"orchestrator.state-snapshot.v1",
            kind:"orchestrator_state_snapshot",id:"observation.example",sha256:sha("6")},
          evaluator:{content:{schema_version:1,kind:"orchestrator_state_scanner_evaluator",
            id:"orchestrator.state-scanner.v1",body:{}},sha256:sha("7")},
          classifications:[classification("a";"pending";"dispatch-stage";0;3;false;false;
            "2026-09-01T00:02:00Z")]}},
      observation_ref:{schema_identity:"orchestrator.state-observation.v1",
        kind:"orchestrator_state_observation",id:"observation.example",sha256:sha("5")},
      delivery_ledger:{schema_version:1,kind:"orchestrator_delivery_ledger",id:"ledger.example",
        body:{recorded_at:"2026-09-01T00:01:30Z",entries:[],ledger_contract:{
          schema_identity:"orchestrator.delivery-ledger.v1",maximum_entry_count:128,
          declared_entry_count:0}}},
      delivery_ledger_ref:{schema_identity:"orchestrator.delivery-ledger.v1",
        kind:"orchestrator_delivery_ledger",id:"ledger.example",sha256:sha("4")},
      max_in_flight:2}}
' > "$bundle"
base="$tmp/base.json"
"$jq_bin" -S -c '.input' "$bundle" > "$base"

run_plan() {
  local input=$1 output=$2 error=$3 task_status=0
  "$jq_bin" -L "$schema_dir" -S -c -f "$planner" "$input" > "$output" 2> "$error" ||
    task_status=$?
  RUN_STATUS=$task_status
}
expect_plan() {
  local name=$1 input=$2 expression=$3 output error
  output="$tmp/$name.out"
  error="$tmp/$name.err"
  run_plan "$input" "$output" "$error"
  if [ "$RUN_STATUS" -ne 0 ] || [ -s "$error" ] ||
     ! "$jq_bin" -e "$expression" "$output" >/dev/null; then fail "$name"; fi
  pass "$name"
  LAST_OUTPUT=$output
}
expect_error() {
  local name=$1 input=$2 output error
  output="$tmp/$name.out"
  error="$tmp/$name.err"
  run_plan "$input" "$output" "$error"
  if [ "$RUN_STATUS" -eq 0 ] || [ -s "$output" ] ||
     ! /usr/bin/grep -Fq E_RECONCILIATION_INPUT "$error"; then fail "$name"; fi
  pass "$name"
}
mutate() {
  local name=$1 filter=$2 destination
  destination="$tmp/$name.json"
  "$jq_bin" -S -c --slurpfile fixture "$bundle" "$filter" "$base" > "$destination"
  /usr/bin/printf '%s\n' "$destination"
}
ledger_from_plan() {
  local name=$1 state=$2 plan=$3 destination
  destination="$tmp/$name.json"
  "$jq_bin" -S -c --arg state "$state" --slurpfile plan "$plan" '
    .delivery_ledger.body.entries=[{delivery_key:$plan[0].body.deliveries[0].delivery_key,
      state:$state,delivery_count:1,last_delivery_at:"2026-09-01T00:01:10Z"}] |
    .delivery_ledger.body.ledger_contract.declared_entry_count=1
  ' "$base" > "$destination"
  /usr/bin/printf '%s\n' "$destination"
}

expect_plan first-delivery "$base" '
  .body.concurrency == {active_pending:0,available_slots:2,max_in_flight:2} and
  (.body.deliveries | length) == 1 and .body.deliveries[0].delivery_mode == "first-delivery" and
  .body.deliveries[0].delivery_key.attempt_number == 1 and
  .body.deliveries[0].delivery_key.operation == "dispatch-stage" and
  (.body.deferred + .body.suppressed + .body.operator_messages | length) == 0'
first_output=$LAST_OUTPUT

pending=$(ledger_from_plan pending-redelivery pending "$first_output")
expect_plan pending-redelivery "$pending" '
  .body.concurrency == {active_pending:1,available_slots:1,max_in_flight:2} and
  .body.deliveries[0].delivery_mode == "redelivery"'
"$jq_bin" -e --slurpfile first "$first_output" \
  '.body.deliveries[0].delivery_key == $first[0].body.deliveries[0].delivery_key' \
  "$LAST_OUTPUT" >/dev/null || fail 'pending key changed'

failed=$(ledger_from_plan failed-redelivery failed "$first_output")
expect_plan failed-redelivery "$failed" '.body.deliveries[0].delivery_mode == "redelivery"'

acknowledged=$(ledger_from_plan acknowledged acknowledged "$first_output")
expect_plan acknowledged-suppression "$acknowledged" '
  (.body.deliveries | length) == 0 and (.body.suppressed | length) == 1 and
  .body.suppressed[0].reason_id == "planner.delivery-acknowledged"'

retry=$(mutate retry '.observation.body.classifications=[$fixture[0].classes.retry_a]')
expect_plan failed-stage-retry "$retry" '
  .body.deliveries[0].operation == "retry-stage" and
  .body.deliveries[0].delivery_key.attempt_number == 2'
retry_limit=$(mutate retry-limit '
  .observation.body.classifications=[$fixture[0].classes.retry_a] |
  .observation.body.classifications[0].recovery.attempt_number=3')
expect_error retry-limit "$retry_limit"

stranded=$(mutate stranded '.observation.body.classifications=[$fixture[0].classes.recover_a]')
expect_plan stranded-recovery "$stranded" '
  .body.deliveries[0].operation == "recover-stranded-attempt" and
  .body.deliveries[0].delivery_key.attempt_number == 1 and
  .body.deliveries[0].provenance.active_attempt.value.attempt_number == 1'

operator_only=$(mutate operator-only '
  .observation.body.classifications=[$fixture[0].classes.terminal_a,
    $fixture[0].classes.operator_b,$fixture[0].classes.refresh_c,
    $fixture[0].classes.block_d,$fixture[0].classes.wait_e]')
expect_plan operator-only "$operator_only" '
  (.body.deliveries + .body.deferred | length) == 0 and
  [.body.operator_messages[].recovery.action] ==
    ["none","operator-reconcile","refresh-stage-inputs","resolve-stage-blocker","wait-for-attempt"]'

full=$(mutate full-backpressure '
  .max_in_flight=1 |
  .delivery_ledger.body.entries=[{delivery_key:{stage_key:{initiative_id:"initiative.z",
    workflow_id:"workflow.example",stage_id:"stage.example",task_class_id:"task.example"},
    request_sha256:("f"*64),operation:"dispatch-stage",attempt_number:1},state:"pending",
    delivery_count:1,last_delivery_at:"2026-09-01T00:01:10Z"}] |
  .delivery_ledger.body.ledger_contract.declared_entry_count=1')
expect_plan full-backpressure "$full" '
  .body.concurrency.available_slots == 0 and (.body.deliveries | length) == 0 and
  .body.deferred[0].reason_id == "planner.backpressure-slots-exhausted"'

partial=$(mutate partial-backpressure '
  .max_in_flight=1 |
  .observation.body.classifications=[$fixture[0].classes.dispatch_a,$fixture[0].classes.dispatch_b]')
expect_plan partial-backpressure "$partial" '
  [.body.deliveries[0].stage_key.initiative_id,.body.deferred[0].stage_key.initiative_id] ==
    ["initiative.a","initiative.b"]'

redelivery_priority="$tmp/redelivery-priority.json"
"$jq_bin" -S -c --slurpfile fixture "$bundle" --slurpfile first "$first_output" '
  .max_in_flight=1 |
  .observation.body.classifications=[$fixture[0].classes.dispatch_a,$fixture[0].classes.dispatch_b] |
  .delivery_ledger.body.entries=[{delivery_key:($first[0].body.deliveries[0].delivery_key |
    .stage_key.initiative_id="initiative.b" | .request_sha256=("b"*64)),state:"failed",
    delivery_count:2,last_delivery_at:"2026-09-01T00:01:10Z"}] |
  .delivery_ledger.body.ledger_contract.declared_entry_count=1
' "$base" > "$redelivery_priority"
expect_plan redelivery-priority "$redelivery_priority" '
  .body.deliveries[0].stage_key.initiative_id == "initiative.b" and
  .body.deliveries[0].delivery_mode == "redelivery" and
  .body.deferred[0].stage_key.initiative_id == "initiative.a"'

duplicate_classes=$(mutate duplicate-classes '
  .observation.body.classifications=[$fixture[0].classes.dispatch_a,
    $fixture[0].classes.dispatch_a]')
expect_error duplicate-classifications "$duplicate_classes"
unsorted_classes=$(mutate unsorted-classes '
  .observation.body.classifications=[$fixture[0].classes.dispatch_b,
    $fixture[0].classes.dispatch_a]')
expect_error unsorted-classifications "$unsorted_classes"

duplicate_ledger="$tmp/duplicate-ledger.json"
"$jq_bin" -S -c '.delivery_ledger.body.entries += .delivery_ledger.body.entries |
  .delivery_ledger.body.ledger_contract.declared_entry_count=2' "$pending" > "$duplicate_ledger"
expect_error duplicate-ledger "$duplicate_ledger"
unsorted_ledger="$tmp/unsorted-ledger.json"
"$jq_bin" -S -c '.delivery_ledger.body.entries=[.delivery_ledger.body.entries[0],
  (.delivery_ledger.body.entries[0] | .delivery_key.stage_key.initiative_id="initiative.b" |
   .delivery_key.request_sha256=("b"*64))] | .delivery_ledger.body.entries|=reverse |
  .delivery_ledger.body.ledger_contract.declared_entry_count=2' "$pending" > "$unsorted_ledger"
expect_error unsorted-ledger "$unsorted_ledger"

malformed=$(mutate malformed '.observation.body.extra=true')
expect_error malformed "$malformed"
stale_ref=$(mutate stale-ref '.observation_ref.id="observation.stale"')
expect_error stale-ref "$stale_ref"
oversize_classes=$(mutate oversize-classes '
  .observation.body.classifications=[range(0;65) as $index |
    $fixture[0].classes.dispatch_a |
    .stage_key.initiative_id=("initiative."+($index|tostring))] |
  .observation.body.classifications|=sort_by(.stage_key.initiative_id)')
expect_error oversize-classifications "$oversize_classes"
oversize_ledger=$(mutate oversize-ledger '
  .delivery_ledger.body.entries=[range(0;129) as $index | {delivery_key:{
    stage_key:{initiative_id:("initiative."+($index|tostring)),workflow_id:"workflow.example",
      stage_id:"stage.example",task_class_id:"task.example"},request_sha256:("f"*64),
      operation:"dispatch-stage",attempt_number:1},state:"failed",delivery_count:1,
      last_delivery_at:"2026-09-01T00:01:10Z"}] |
  .delivery_ledger.body.entries|=sort_by(.delivery_key.stage_key.initiative_id) |
  .delivery_ledger.body.ledger_contract.declared_entry_count=129')
expect_error oversize-ledger "$oversize_ledger"

repeat="$tmp/repeat.out"
run_plan "$base" "$repeat" "$tmp/repeat.err"
if [ "$RUN_STATUS" -ne 0 ] ||
   ! /usr/bin/cmp -s "$first_output" "$repeat"; then fail 'repeat output'; fi
canonical="$tmp/canonical.out"
"$jq_bin" -S -c . "$first_output" > "$canonical"
/usr/bin/cmp -s "$first_output" "$canonical" || fail 'canonical output'
pass canonical-repeat-output

"$jq_bin" -e '
  .body.activation_state == "inactive" and .body.authority_effect == "none" and
  .body.mode == "planning-only" and
  ([.. | objects | keys[] | select(. == "authority" or . == "effect" or
    . == "permissions" or . == "capabilities" or . == "credential" or
    . == "network" or . == "execute" or . == "schedule")] | length) == 0
' "$first_output" >/dev/null || fail 'authority or effect field'
pass inactive-data-only-boundary

/usr/bin/printf 'PASS: %s reconciliation plan checks\n' "$passes"
