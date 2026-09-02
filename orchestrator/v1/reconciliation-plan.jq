import "schema" as schema;

def stage_order:
  [.initiative_id,.workflow_id,.stage_id,.task_class_id];

def stage_key_shape:
  schema::exact_fields(
    ["initiative_id","stage_id","task_class_id","workflow_id"];[]) and
  all(.[];schema::id_ok);

def plan_operation:
  . == "dispatch-stage" or . == "retry-stage" or
  . == "recover-stranded-attempt";

def delivery_key_order:
  ((.stage_key | stage_order) +
   [.request_sha256,.operation,.attempt_number]);

def delivery_key_shape:
  schema::exact_fields(
    ["attempt_number","operation","request_sha256","stage_key"];[]) and
  (.stage_key | stage_key_shape) and
  (.request_sha256 | schema::sha256_ok) and
  (.operation | plan_operation) and
  (.attempt_number | schema::int_ok) and
  .attempt_number >= 1 and .attempt_number <= 10;

def source_ref_shape($kind; $identity):
  schema::exact_fields(["id","kind","schema_identity","sha256"];[]) and
  .kind == $kind and .schema_identity == $identity and
  (.id | schema::id_ok) and (.sha256 | schema::sha256_ok);

def snapshot_ref_shape:
  source_ref_shape(
    "orchestrator_state_snapshot";"orchestrator.state-snapshot.v1");

def core_contract_shape:
  schema::exact_fields(
    ["generation_id_sha256","package_ref","semantic_identity"];[]) and
  .semantic_identity == "core.contracts.v2" and
  (.generation_id_sha256 | schema::sha256_ok) and
  (.package_ref | schema::content_ref_ok) and
  .package_ref.content_id == "core-contract-package.v2" and
  .package_ref.media_type == "application/vnd.ystack.core-contract+json";

def evaluator_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.sha256 | schema::sha256_ok) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and
   .kind == "orchestrator_state_scanner_evaluator" and
   (.id | schema::id_ok) and
   (.body | type == "object" and schema::parsed_limits_ok));

def attempt_shape:
  schema::exact_fields(
    ["attempt_id","attempt_number","deadline_at","request_ref","state"];[]) and
  (.attempt_id | schema::id_ok) and
  (.attempt_number | schema::int_ok) and
  .attempt_number >= 1 and .attempt_number <= 10 and
  (.deadline_at | schema::time_ok) and
  (.request_ref | schema::document_ref_kind_ok("stage_request")) and
  (.state == "dispatched" or .state == "started");

def present_shape(value_ok):
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def recovery_shape:
  schema::exact_fields(
    ["action","attempt_number","reason_id","retry_limit","source_reason"];[]) and
  (.action | type == "string") and
  (.reason_id | schema::id_ok) and
  (.source_reason | present_shape(schema::id_ok)) and
  (.attempt_number | schema::int_ok) and
  (.retry_limit | schema::int_ok) and
  .retry_limit >= 1 and .retry_limit <= 10 and
  .attempt_number <= .retry_limit;

def class_action_shape:
  (.class == "terminal" and .recovery.action == "none") or
  (.class == "stale" and .recovery.action == "refresh-stage-inputs") or
  (.class == "blocked" and
   (.recovery.action == "resolve-stage-blocker" or
    .recovery.action == "operator-reconcile")) or
  (.class == "retryable" and .recovery.action == "retry-stage") or
  (.class == "stranded" and
   .recovery.action == "recover-stranded-attempt") or
  (.class == "pending" and
   (.recovery.action == "wait-for-attempt" or
    .recovery.action == "dispatch-stage"));

def provenance_shape($observation):
  schema::exact_fields(
    ["active_attempt","evaluator_ref","item_ref","latest_result_ref",
     "request_ref","resolved_profile_ref","snapshot_ref"];[]) and
  .snapshot_ref == $observation.body.snapshot_ref and
  (.evaluator_ref | schema::content_ref_ok) and
  .evaluator_ref.content_id == "orchestrator-state-scanner-evaluator.v1" and
  .evaluator_ref.media_type ==
    "application/vnd.ystack.orchestrator-state-scanner-evaluator+json" and
  .evaluator_ref.sha256 == $observation.body.evaluator.sha256 and
  (.item_ref |
   schema::exact_fields(["schema_identity","sha256"];[]) and
   .schema_identity == "orchestrator.state-item.v1" and
   (.sha256 | schema::sha256_ok)) and
  (.request_ref | schema::document_ref_kind_ok("stage_request")) and
  (.resolved_profile_ref |
   schema::document_ref_kind_ok("resolved_profile")) and
  (.latest_result_ref |
   present_shape(schema::document_ref_kind_ok("stage_result"))) and
  (.active_attempt | present_shape(attempt_shape));

def classification_relation($observation):
  . as $classification |
  ($classification | class_action_shape) and
  (if .provenance.active_attempt.state == "present" then
     .provenance.active_attempt.value.request_ref == .provenance.request_ref and
     .provenance.active_attempt.value.attempt_number ==
       .recovery.attempt_number
   else true end) and
  (if .recovery.action == "dispatch-stage" then
     .recovery.attempt_number == 0 and
     .provenance.active_attempt.state == "absent" and
     .provenance.latest_result_ref.state == "absent"
   elif .recovery.action == "retry-stage" then
     .recovery.attempt_number >= 1 and
     .recovery.attempt_number < .recovery.retry_limit and
     .provenance.active_attempt.state == "absent" and
     .provenance.latest_result_ref.state == "present"
   elif .recovery.action == "recover-stranded-attempt" then
     .recovery.attempt_number >= 1 and
     .provenance.active_attempt.state == "present" and
     .provenance.active_attempt.value.deadline_at <=
       $observation.body.observed_at
   elif .recovery.action == "wait-for-attempt" then
     .provenance.active_attempt.state == "present" and
     .provenance.active_attempt.value.deadline_at >
       $observation.body.observed_at
   elif .recovery.action == "operator-reconcile" then
     .recovery.attempt_number == .recovery.retry_limit and
     .provenance.latest_result_ref.state == "present"
   else true end);

def classification_shape($observation):
  schema::exact_fields(["class","provenance","recovery","stage_key"];[]) and
  (.stage_key | stage_key_shape) and
  (.provenance | provenance_shape($observation)) and
  (.recovery | recovery_shape) and
  classification_relation($observation);

def observation_shape:
  . as $observation |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "orchestrator_state_observation" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","classifications","core_contract",
      "evaluator","mode","observed_at","snapshot_ref","source_revision"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "observation-only" and
   (.core_contract | core_contract_shape) and
   (.source_revision | schema::git_revision_ref_ok) and
   (.observed_at | schema::time_ok) and
   (.snapshot_ref | snapshot_ref_shape) and
   .snapshot_ref.id == $observation.id and
   (.evaluator | evaluator_shape) and
   (.classifications | type == "array" and length <= 64 and
    all(.[];classification_shape($observation))) and
   ((.classifications | map(.stage_key | stage_order)) as $keys |
    $keys == ($keys | sort) and
    ($keys | length) == ($keys | unique | length)));

def ledger_entry_shape($recorded_at):
  schema::exact_fields(
    ["delivery_count","delivery_key","last_delivery_at","state"];[]) and
  (.delivery_key | delivery_key_shape) and
  (.state == "pending" or .state == "acknowledged" or .state == "failed") and
  (.delivery_count | schema::int_ok) and
  .delivery_count >= 1 and .delivery_count <= 1000 and
  (.last_delivery_at | schema::time_ok) and .last_delivery_at <= $recorded_at;

def ledger_shape:
  . as $ledger |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "orchestrator_delivery_ledger" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(["entries","ledger_contract","recorded_at"];[]) and
   (.recorded_at | schema::time_ok) and
   (.ledger_contract |
    schema::exact_fields(
      ["declared_entry_count","maximum_entry_count","schema_identity"];[]) and
    .schema_identity == "orchestrator.delivery-ledger.v1" and
    .maximum_entry_count == 128 and
    (.declared_entry_count | schema::int_ok) and
    .declared_entry_count == ($ledger.body.entries | length)) and
   (.entries | type == "array" and length <= 128 and
    all(.[];ledger_entry_shape($ledger.body.recorded_at))) and
   ((.entries | map(.delivery_key | delivery_key_order)) as $keys |
    $keys == ($keys | sort) and
    ($keys | length) == ($keys | unique | length)));

def input_shape:
  . as $input |
  schema::exact_fields(
    ["delivery_ledger","delivery_ledger_ref","max_in_flight","observation",
     "observation_ref"];[]) and
  (.observation | observation_shape) and
  (.delivery_ledger | ledger_shape) and
  (.observation_ref |
   source_ref_shape(
     "orchestrator_state_observation";"orchestrator.state-observation.v1")) and
  .observation_ref.id == .observation.id and
  (.delivery_ledger_ref |
   source_ref_shape(
     "orchestrator_delivery_ledger";"orchestrator.delivery-ledger.v1")) and
  .delivery_ledger_ref.id == .delivery_ledger.id and
  (.max_in_flight | schema::int_ok) and .max_in_flight <= 64;

def planned_attempt:
  if .recovery.action == "recover-stranded-attempt" then
    .recovery.attempt_number
  else .recovery.attempt_number + 1
  end;

def candidate($entries):
  . as $classification |
  ($classification | planned_attempt) as $attempt_number |
  {
    stage_key:$classification.stage_key,
    request_sha256:$classification.provenance.request_ref.sha256,
    operation:$classification.recovery.action,
    attempt_number:$attempt_number
  } as $delivery_key |
  ([$entries[] | select(.delivery_key == $delivery_key)][0] // null) as $prior |
  {
    delivery_key:$delivery_key,
    delivery_mode:(if $prior == null then "first-delivery" else "redelivery" end),
    operation:$classification.recovery.action,
    prior_state:($prior.state // "absent"),
    priority:(if $prior == null then 1 else 0 end),
    provenance:$classification.provenance,
    recovery:$classification.recovery,
    slot_cost:(if $prior != null and $prior.state == "pending" then 0 else 1 end),
    stage_key:$classification.stage_key
  };

def public_candidate:
  {
    delivery_key,delivery_mode,operation,provenance,recovery,stage_key
  };

def build_plan($input):
  $input.observation.body.classifications as $classifications |
  $input.delivery_ledger.body.entries as $entries |
  ([ $classifications[] |
     select(.recovery.action | plan_operation) |
     candidate($entries) ] |
   sort_by([.priority] + (.stage_key | stage_order))) as $candidates |
  ([ $entries[] | select(.state == "pending") ] | length) as $active_pending |
  ([$input.max_in_flight - $active_pending,0] | max) as $available_slots |
  (reduce ($candidates[] | select(.prior_state != "acknowledged")) as $candidate
     ({remaining:$available_slots,deliveries:[],deferred:[]};
      if $candidate.slot_cost == 0 or .remaining > 0 then
        .deliveries += [($candidate | public_candidate)] |
        if $candidate.slot_cost == 1 then .remaining -= 1 else . end
      else
        .deferred += [($candidate | public_candidate) +
                      {reason_id:"planner.backpressure-slots-exhausted"}]
      end)) as $allocation |
  {
    schema_version:1,
    kind:"orchestrator_reconciliation_plan",
    id:$input.observation.id,
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"planning-only",
      observation_ref:$input.observation_ref,
      delivery_ledger_ref:$input.delivery_ledger_ref,
      concurrency:{
        active_pending:$active_pending,
        available_slots:$available_slots,
        max_in_flight:$input.max_in_flight
      },
      deliveries:$allocation.deliveries,
      deferred:$allocation.deferred,
      suppressed:[
        $candidates[] |
        select(.prior_state == "acknowledged") |
        {delivery_key,reason_id:"planner.delivery-acknowledged",stage_key}
      ],
      operator_messages:[
        $classifications[] |
        select((.recovery.action | plan_operation) | not) |
        {class,recovery,stage_key}
      ]
    }
  };

. as $input |
if (($input | schema::parsed_limits_ok) and ($input | input_shape)) then
  build_plan($input)
else error("E_RECONCILIATION_INPUT")
end
